# Linux namespaces로 컨테이너가 "격리된 것처럼" 보이는 법 (PID·mount·user namespace 내부 동작)

> **Primary source:** Linux man-pages — namespaces(7), pid_namespaces(7), mount_namespaces(7), user_namespaces(7), clone(2), unshare(2), setns(2)
> **Secondary:** util-linux `unshare(1)` 매뉴얼
> **Date:** 2026-07-26
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/linux-namespaces-container-isolation

## 왜 봤나

- 컨테이너를 "가벼운 VM"처럼 뭉뚱그려 이해하고 있었는데, 실제로는 **커널 하나를 공유하면서 몇 가지 전역 자원의 "보이는 범위"만 프로세스별로 갈아끼우는** 것이다. 그 갈아끼우기를 담당하는 게 namespace다.
- `unshare --pid bash`를 실행했더니 `ps`에 여전히 호스트 프로세스가 다 보여서 "격리가 안 됐나?" 했던 오해를 바로잡고 싶었다.

## 핵심 한 문장

> namespace는 전역 커널 자원(프로세스 트리·마운트 목록·UID 공간 등)을 **감싼 래퍼**로, 같은 namespace에 속한 프로세스들끼리만 그 자원을 공유해서 보고, 다른 namespace에서는 같은 자원이 아예 다른 값으로 보이게 만든다.

## 내부 동작

man-page namespaces(7)에 따르면 종류는 mnt·pid·net·ipc·uts·user·cgroup(그리고 time)이며, 각 프로세스의 소속은 `/proc/<pid>/ns/*` 심볼릭 링크로 드러난다. 두 프로세스가 같은 namespace에 있으면 이 링크가 **같은 inode 번호**를 가리킨다 — 커널은 namespace를 파일처럼 inode로 식별한다.

만드는 방법은 세 가지다:
- `clone(2)`에 `CLONE_NEW*` 플래그를 줘서 **새 프로세스를 새 namespace에서** 시작.
- `unshare(2)`로 **호출한 프로세스 자신을** 새 namespace로 이동.
- `setns(2)`로 `/proc/<pid>/ns/<type>` fd를 열어 **기존 namespace에 합류**(컨테이너에 `docker exec`가 이 경로).

### PID namespace — 같은 프로세스가 여러 PID를 갖는다

pid_namespaces(7)의 핵심은 PID namespace가 **계층적**이라는 점이다. 새 PID namespace에서 처음 만들어진 프로세스가 그 안에서 **PID 1**이 된다. 그리고 한 프로세스는 **자신이 속한 namespace와 그 모든 조상 namespace마다 서로 다른 PID를 갖는다.** `getpid()`는 호출자가 속한 namespace 기준 PID를 돌려준다.

```
        호스트(root) PID namespace
        ┌───────────────────────────────┐
        │ PID 4021: runc/컨테이너 init   │
        │      └─ 자식 PID namespace ────┼──┐
        └───────────────────────────────┘  │
                                            v
                     컨테이너 PID namespace
                     ┌──────────────────────────┐
                     │ PID 1: 앱 프로세스        │  ← 호스트에선 4021
                     │ PID 7: 워커              │  ← 호스트에선 4103
                     └──────────────────────────┘
```

PID 1은 특별하다. pid_namespaces(7)가 명시하는 두 가지:
1. **신호 보호**: namespace **내부**에서 PID 1로 보낼 수 있는 신호는 PID 1이 **핸들러를 등록한 것뿐**이다(특권 프로세스도 마찬가지). 그래서 핸들러 없는 앱을 PID 1로 띄우면 내부에서 보낸 `SIGTERM`이 그냥 무시된다. 단, **조상 namespace**가 보내는 `SIGKILL`/`SIGSTOP`은 이 규칙을 우회한다.
2. **고아 프로세스 reaping**: 부모가 죽은 프로세스는 PID 1로 reparent되고, PID 1이 `wait()`로 좀비를 거둬야 한다.
3. PID 1이 종료되면 커널이 그 namespace의 **모든 프로세스에 `SIGKILL`**을 보내고 namespace를 해체한다.

또 하나 함정: `CLONE_NEWPID`는 **이미 존재하는** 호출 프로세스의 PID를 바꾸지 못한다(PID는 불변). 그래서 `unshare(2)`로 PID namespace만 만들면 호출자는 그대로 있고, **이후 `fork()`한 첫 자식**이 PID 1이 된다.

### Mount namespace — 마운트 목록의 복사본과 전파 규칙

mount_namespaces(7): `CLONE_NEWNS`로 만들면 그 순간의 **마운트 목록을 복사**한다. 이후 한쪽에서 마운트/언마운트해도 다른 namespace에 안 보인다 — 이게 컨테이너가 자기만의 루트 파일시스템을 갖는 토대다(런타임은 여기에 `pivot_root(2)`로 루트를 바꿔 끼운다).

단순 복사가 아니라 **전파 타입(propagation type)**이 있다:

| 타입 | 마운트 이벤트 전파 |
| --- | --- |
| `shared` | 양방향 — peer group 안에서 서로 전파 |
| `private` | 전파 없음 |
| `slave` | 부모→자식 단방향만 수신 |
| `unbindable` | bind mount 원천 금지 |

컨테이너 런타임은 보통 루트를 `slave`나 `private`로 만들어, 호스트에서 새로 붙인 디스크는 받되 컨테이너 내부 마운트는 호스트로 새어나가지 않게 한다.

### User namespace — 안에서는 root, 밖에서는 무권한

user_namespaces(7)가 가장 강력하다. namespace 안의 UID/GID를 바깥 UID/GID로 **매핑**한다. `/proc/<pid>/uid_map`에 `안쪽ID 바깥쪽ID 길이` 형식으로 쓴다(한 번만 쓰기 가능):

```
# 컨테이너 uid 0..65535 를 호스트 uid 100000..165535 로
0 100000 65536
```

그래서 컨테이너 안에서 `uid 0`(root)로 동작해도 호스트에서는 `uid 100000`인 무권한 사용자다 — rootless 컨테이너의 원리. man-page에 따르면 user namespace를 만든 프로세스는 **그 namespace가 소유한 자원에 한해** 전체 capability를 얻지만 **부모 namespace에서는 아무 권한도 없다.** 다른 namespace 종류들의 권한 검사도 결국 "그 namespace를 소유한 user namespace" 기준으로 이뤄진다. (보안 이슈로, gid_map을 쓰기 전 `setgroups`를 `deny`로 막아야 하는 제약도 있다.)

## 검증

이 repo엔 실행 환경이 없어 man-page 흐름과 `unshare(1)` 동작을 따라가며 확인했다.

```bash
# PID namespace: --fork 없이는 자식이 PID 1이 되지 못한다
$ sudo unshare --pid --mount-proc --fork bash
# 새 셸에서:
$ echo $$        # 1  ← 이 namespace 기준 PID
$ ps -e          # /proc를 새로 마운트했으므로 이 namespace의 프로세스만 보임

# 같은 namespace 여부는 inode로 판정
$ readlink /proc/1/ns/pid       # pid:[4026531836] 같은 inode
$ readlink /proc/$$/ns/pid      # 같으면 동일 namespace
```

`--mount-proc`가 왜 필요한가: PID namespace만 새로 만들면 `/proc`는 여전히 **호스트의** procfs라 `ps`가 전부 다 보인다. mount namespace에서 `/proc`를 다시 마운트해야 procfs가 현재 PID namespace를 반영한다. 즉 "PID 격리가 안 된다"가 아니라 "보여주는 창(procfs)이 아직 호스트 것"이었던 셈.

## 잘못 알고 있던 것

- **"namespace = 컨테이너"** — 아니다. namespace는 *가시성*만 나눈다. 자원 *양*의 제한은 cgroup 몫이고(→ [[cgroup-v2-memory-controller-oom]]), 여기에 capability drop·seccomp·pivot_root가 더해져야 컨테이너다. 축이 다르다.
- **"`unshare --pid bash`면 셸이 PID 1"** — 아니다. 기존 프로세스는 PID를 못 바꾼다. `--fork`로 만든 **자식**이 PID 1이 되고, 안 주면 셸은 새 namespace의 PID 1이 아니라 그냥 자식만 그 안에서 도는 어정쩡한 상태가 된다.
- **"컨테이너의 PID 1도 평범한 프로세스"** — 아니다. 신호 핸들러를 등록 안 하면 내부 `SIGTERM`이 무시되고, 좀비 reaping 책임도 진다. 셸을 PID 1로 두면 시그널이 앱에 전달 안 돼 graceful shutdown이 깨진다(→ [[pod-termination-endpoint-race]]의 "PID1이 셸이면 드레이닝 실패"와 같은 뿌리). 그래서 `tini` 같은 init을 PID 1로 둔다.

## 더 파고들 만한 것

- network namespace와 veth pair: 컨테이너 `eth0`이 호스트 bridge에 붙는 경로.
- `pivot_root(2)` vs `chroot(2)`: 런타임이 왜 chroot 대신 pivot_root를 쓰는가.

## 참고

- man-pages: namespaces(7), pid_namespaces(7), mount_namespaces(7), user_namespaces(7)
- clone(2) / unshare(2) / setns(2) 시스템 콜 매뉴얼
