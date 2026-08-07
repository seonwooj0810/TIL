# seccomp-BPF: 컨테이너 syscall 필터링이 리턴값 우선순위와 포인터 역참조 금지로 안전을 보장하는 법

> **Primary source:** Linux Kernel Documentation — userspace-api/seccomp_filter.rst
> **Secondary:** Linux Kernel Documentation — networking/filter.rst (classic BPF) / man7 seccomp(2)
> **Date:** 2026-08-07
> **Status:** draft

## 왜 봤나

컨테이너 격리는 namespace(무엇을 볼 수 있는가)와 cgroup(얼마나 쓸 수 있는가)만으로 완성되지 않는다. 이 repo에서 이미 다룬 [Linux namespaces](./linux-namespaces-container-isolation.md)와 [cgroup v2 메모리 컨트롤러](./cgroup-v2-memory-controller-oom.md)는 "보이는 자원"과 "쓸 수 있는 자원"을 통제하지만, 프로세스가 애초에 어떤 *커널 진입점*(syscall)을 호출할 수 있는지는 통제하지 않는다. `unshare`로 새 PID/mount namespace를 만들어도 `ptrace()`나 `mount()` 같은 syscall 호출 자체는 막지 못한다 — namespace는 "격리된 view 안에서의 동작"만 허용하기 때문에 커널 취약점과 결합하면 여전히 위험하다.

흔한 혼동은 "seccomp이 syscall 인자 값을 보니 `open("/etc/passwd", ...)` 같은 걸 막을 수 있겠다"는 기대다. 실제로는 BPF 필터가 포인터를 역참조할 수 없어 경로 문자열은 볼 수 없고, syscall 번호와 레지스터의 정수 인자만 본다. 이 제약이 왜 있는지, 필터가 여러 개 겹쳤을 때 판정이 어떻게 결정되는지가 이 노트의 핵심이다.

## 핵심 한 문장

> seccomp-BPF는 각 syscall 진입 시 커널이 classic BPF(cBPF) 프로그램을 실행해 `struct seccomp_data`(레지스터 값만, 포인터 역참조 없음)를 평가하게 하고, 여러 필터가 붙어 있으면 "가장 강한 조치(highest precedent)"가 최종 판정이 되는 append-only 스택이다.

## 내부 동작

### 1. 두 가지 모드: STRICT vs FILTER

`prctl(2)`로 seccomp을 켜는 두 모드가 있다.

- **SECCOMP_MODE_STRICT**: man7 seccomp(2)에 따르면 허용 syscall은 정확히 `read(2)`, `write(2)`, `_exit(2)`(`exit_group(2)` 제외), `sigreturn(2)` 뿐이다. 그 외를 호출하면 스레드가 하나뿐이면 프로세스 전체가, 여러 스레드면 해당 스레드가 `SIGKILL`로 즉시 종료된다. 필터가 아니라 하드코딩된 화이트리스트다.
- **SECCOMP_MODE_FILTER**: 커널 문서 표현으로 "이제 BPF 프로그램으로 새 필터를 지정하는 추가 인자를 받는다." 임의의 syscall 조합을 프로그래밍 가능한 규칙으로 허용/거부한다. Docker/containerd/Kubernetes 기본 seccomp 프로파일이 쓰는 모드다.

FILTER 모드를 켜려면 두 조건 중 하나가 필요하다: 호출 스레드가 자신의 user namespace에서 `CAP_SYS_ADMIN`을 갖고 있거나, 이미 `prctl(PR_SET_NO_NEW_PRIVS, 1)`로 "이 프로세스와 자손은 execve 후에도 새 권한을 얻을 수 없다"는 비트를 세워둔 상태여야 한다. 둘 다 없으면 `-EACCES`로 실패한다. 왜인가 — no_new_privs 없이 비루트가 임의로 필터를 걸면, 그 필터가 이후 실행하는 SUID 바이너리에도 상속되어 setuid 상승 이후의 검사 경로를 걸러 semantics를 깨는 공격 표면이 생기기 때문이다.

### 2. cBPF 가상 머신: seccomp이 "프로그램"을 실행하는 방법

seccomp-FILTER에 넘기는 프로그램은 classic BPF(cBPF, 소켓 필터에도 쓰이는 그 BPF)다. 커널 문서 `networking/filter.rst`가 정의하는 명령 구조체는:

```c
struct sock_filter {    /* Filter block */
        __u16   code;   /* Actual filter code */
        __u8    jt;     /* Jump true */
        __u8    jf;     /* Jump false */
        __u32   k;      /* Generic multiuse field */
};
```

실행 상태는 세 가지 저장소로 구성된 단순한 레지스터 머신이다:
- **A**: 32비트 누산기 (연산 결과와 비교 대상이 여기 쌓인다)
- **X**: 32비트 보조 레지스터
- **M[0..15]**: 32비트짜리 스크래치 메모리 16칸

명령은 클래스별로 나뉜다 — load(`ld`/`ldh`/`ldb`/`ldx`), store(`st`/`stx`), 분기(`jmp`/`ja`/`jeq`/`jgt`/`jset` 등), 산술(`add`/`sub`/`and`/`or`/`lsh`/`rsh` 등), 레지스터 교환(`tax`/`txa`), `ret`. 분기 명령의 `jt`/`jf`는 각각 "참"/"거짓"일 때 건너뛸 명령 오프셋이다 — 프로그램은 조건 분기가 있는 선형 명령 배열이고, PC는 매 스텝 증가하다가 조건 분기에서 `jt`/`jf` 오프셋만큼 앞으로만 점프한다(뒤로는 못 간다 — 루프가 없어 종료가 보장된다).

seccomp이 각 syscall 진입 시 이 VM에 넘기는 입력은 `struct seccomp_data`다. 커널 문서는 이 구조체가 "system call number, arguments, and other metadata"를 담는다고 명시한다. `ld`/`ldw` 계열 명령이 이 구조체의 오프셋에서 32비트 워드를 읽어 A에 적재하고, 이후 `jeq`로 특정 syscall 번호나 인자값과 비교해 분기하는 식으로 규칙을 조립한다.

### 3. "포인터를 역참조할 수 없다" — TOCTOU 방지가 곧 필터의 한계

seccomp_filter.rst의 표현을 그대로 옮기면: "BPF programs may not dereference pointers which constrains all filters to solely evaluating the system call arguments directly." 그리고 "`struct seccomp_data` contains the values of register arguments to the syscall, but does not contain pointers to memory." 즉 `open(path, flags)`을 필터가 볼 때 `path`는 유저 공간 메모리를 가리키는 포인터값(정수)일 뿐, 그 포인터가 가리키는 문자열 내용은 필터가 읽을 방법이 없다.

이건 성능 제약이 아니라 의도된 보안 설계다. 필터가 포인터를 따라가 인자 내용을 검사할 수 있었다면, "검사 시점의 메모리 내용"과 "syscall 실행 시점의 메모리 내용"이 다를 수 있는 TOCTOU(time-of-check-to-time-of-use) 창이 생긴다 — 멀티스레드 프로세스가 평가와 실행 사이의 짧은 틈에 다른 스레드로 메모리를 덮어써 "안전한 경로로 검사받고 위험한 경로로 실행"시키는 공격이 가능해진다. 그래서 seccomp은 그 능력 자체를 주지 않는다 — 레지스터의 정수(syscall 번호, 플래그, 길이 등)만 평가 가능하게 제한해 이 공격 클래스를 구조적으로 차단한다. 경로 기반 접근 제어는 seccomp이 아니라 LSM(AppArmor/SELinux)의 몫이라는 역할 분담이 여기서 나온다.

### 4. 필터가 여러 개일 때: 리턴값 우선순위와 append-only 스택

프로세스는 필터를 여러 번 붙일 수 있고(`fork`/`clone`으로 상속되기도 한다), man7 문서에 따르면 "If prctl(2) or seccomp() is allowed by the attached filter, further filters may be added" — 필터는 추가만 되지 제거되지 않는다. 실행 시점에는 붙어있는 모든 필터가 각각 하나의 리턴값을 내고, 커널은 그중 "가장 강한" 것을 채택한다.

seccomp_filter.rst가 명시하는 우선순위(높은 순):

```
SECCOMP_RET_KILL_PROCESS  →  프로세스 전체 즉시 종료
SECCOMP_RET_KILL_THREAD   →  해당 스레드만 즉시 종료
SECCOMP_RET_TRAP          →  SIGSYS 전달
SECCOMP_RET_ERRNO         →  syscall을 실행하지 않고 지정한 errno를 리턴값으로 위장
SECCOMP_RET_USER_NOTIF    →  유저공간 감시자(fd)에게 판단을 위임
SECCOMP_RET_TRACE         →  ptrace 기반 tracer에게 통지
SECCOMP_RET_LOG           →  syscall을 실제로 실행하되 감사로그를 남김
SECCOMP_RET_ALLOW         →  syscall을 그대로 실행
```

문서의 표현: "If multiple filters exist, the return value for the evaluation of a given system call will always use the highest precedent value." man7은 이 32비트 리턴값이 상위 16비트(액션, `SECCOMP_RET_ACTION_FULL` 마스크)와 하위 16비트(`SECCOMP_RET_DATA`, 예를 들어 `ERRNO`의 실제 errno 값)로 나뉜다고 설명한다. 우선순위 비교는 액션 비트만 보고, 액션이 같으면 가장 나중에 붙인 필터의 데이터 비트가 쓰인다.

이 "가장 강한 조치가 이긴다" 규칙이 컨테이너 보안 모델에서 왜 중요한가 — 런타임이 기본 프로파일로 넓은 syscall을 `ERRNO`로 막아두면, 이후 다른 계층이 더 관대한 필터를 붙여도 이미 `KILL`/`ERRNO`로 판정된 syscall은 절대 `ALLOW`로 완화되지 않는다. 필터 스택은 오직 더 엄격해지는 방향으로만 쌓인다 — append-only 설계와 우선순위 규칙이 함께 만드는 불변식이다.

## 검증

로컬에서 직접 재현할 수 있는 관측 포인트 두 가지:

1. **STRICT 모드의 화이트리스트 확인**: strace로 아무 프로그램이나 실행하며 syscall 목록을 보면, `read`/`write`/`exit`/`rt_sigreturn` 외의 것이 얼마나 자주 쓰이는지 확인할 수 있다.
   ```sh
   strace -c -f /bin/true 2>&1 | tail -20
   ```
   출력을 SECCOMP_MODE_STRICT 허용 목록(`read`, `write`, `_exit`, `sigreturn`)과 대조하면, 동적 링커의 `mmap`/`openat`부터 막혀 사실상 모든 실전 바이너리가 STRICT로는 못 돈다는 게 바로 드러난다 — FILTER 모드가 실질적으로 유일한 선택지라는 결론이 검증된다.

2. **컨테이너 런타임의 seccomp 프로파일 적용 여부 확인**: `/proc/<pid>/status`의 `Seccomp` 필드로 확인 가능하다.
   ```sh
   docker run -d --name secc-test alpine sleep 300
   grep Seccomp /proc/$(docker inspect -f '{{.State.Pid}}' secc-test)/status
   docker run -d --security-opt seccomp=unconfined --name secc-off alpine sleep 300
   grep Seccomp /proc/$(docker inspect -f '{{.State.Pid}}' secc-off)/status
   ```
   `Seccomp: 2`(FILTER 모드 적용)와 `Seccomp: 0`(비활성)의 차이로, 런타임이 기본적으로 FILTER 모드를 켜고 `unconfined` 옵션이 그걸 실제로 끈다는 것을 직접 확인할 수 있다.

## 잘못 알고 있던 것

- **오해: "seccomp 필터로 `open("/etc/shadow")`처럼 특정 경로를 막을 수 있다."**
  실제: 필터는 포인터를 역참조하지 못해 경로 문자열을 볼 수 없다. syscall 번호나 플래그 정수만 검사할 수 있을 뿐 "이 경로일 때만" 조건은 표현 불가능하다. 경로 기반 통제는 AppArmor/SELinux(LSM)의 몫이다. 버그가 아니라 TOCTOU 공격을 구조적으로 차단하기 위한 설계다.

- **오해: "필터를 여러 번 걸면 마지막에 건 게 이긴다(override)."**
  실제: override가 아니라 accumulate다 — 모든 필터가 평가되고 가장 엄격한(precedence가 높은) 판정이 최종값이 된다. 나중에 관대한 필터를 추가해도 이전 필터의 `KILL`/`ERRNO` 판정은 되돌릴 수 없다.

## 더 파고들 만한 것

- eBPF는 cBPF와 레지스터 수·명령셋이 다르고, 커널이 cBPF를 eBPF로 JIT 변환해 실행한다 — 그 변환 경로와 검증기(verifier)의 안전성 증명 방식.
- Kubernetes `SeccompProfile`을 containerd/runc가 어느 시점에 `prctl`로 적용하는지 (namespace/cgroup 설정과의 순서 관계).

## 참고

- man7.org seccomp(2)
- Docker docs — Seccomp security profiles for Docker
- Kubernetes docs — Restrict a Container's Syscalls with seccomp

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
