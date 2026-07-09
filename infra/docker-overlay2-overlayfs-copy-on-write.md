# Docker overlay2와 overlayfs: 이미지 레이어는 어떻게 공유되고 첫 쓰기는 왜 copy_up을 부르나

> **Primary source:** Linux Kernel Docs — Filesystems / Overlay Filesystem (docs.kernel.org/filesystems/overlayfs.html)
> **Secondary:** Docker Docs — Storage drivers / overlayfs (overlay2) driver
> **Date:** 2026-07-09
> **Status:** draft

## 왜 봤나

- 같은 이미지로 컨테이너 수십 개를 띄워도 디스크가 이미지 크기의 배수로 늘지 않는 이유, 그리고 "컨테이너 안에서 파일 하나 고쳤더니 큰 파일이 통째로 복사돼 느려진" 현상의 근원을 union mount 레벨에서 이해하고 싶었다.
- 막연히 "레이어는 diff를 쌓는 것" 정도로만 알고 있었는데, 삭제를 어떻게 표현하는지(whiteout)는 전혀 몰랐다.

## 핵심 한 문장

> overlay2는 읽기 전용 이미지 레이어들을 `lowerdir` 스택으로 겹치고 그 위에 쓰기 가능한 `upperdir`을 얹은 **union mount**이며, 하위 레이어 파일에 쓰기가 처음 발생할 때만 그 파일을 upper로 복사(copy_up)하는 **copy-on-write** 파일시스템이다.

## 내부 동작

### 레이어 세 종류

overlayfs 마운트는 세 디렉터리로 구성된다 (커널 문서 용어 그대로):

- **lowerdir** — 읽기 전용 하위 트리. 콜론으로 여러 개를 쌓는다: `lowerdir=L1:L2:L3`. 커널 문서상 "stacked beginning from the rightmost one and going left" — 즉 **가장 오른쪽이 최하위**, L1이 최상위 lower다.
- **upperdir** — 쓰기 가능한 최상위 트리. 컨테이너의 변경분이 여기 쌓인다.
- **workdir** — upperdir과 **같은 파일시스템**에 있어야 하는 빈 디렉터리. copy_up 시 atomic 연산을 위한 준비 공간이다.

### merged view 계산 (lookup 알고리즘)

overlay는 이름 조회 시 각 실제 레이어를 위→아래로 훑어 결과를 overlay dentry에 캐시한다. 병합 규칙:

- 같은 이름이 non-directory면 **upper가 lower를 완전히 가린다**.
- 같은 이름이 양쪽 다 directory면 **merged directory**가 만들어진다.
- 문서 핵심 문장: "only the lists of names from directories are merged. Other content such as metadata and extended attributes are reported for the upper directory only." → 디렉터리는 **이름 목록만** 합쳐지고 메타데이터/xattr은 upper 것만 노출된다.

```
merged view = 위에서 아래로 첫 매칭:
  upperdir ──┐  (여기 있으면 이걸로 결정, 단 whiteout이면 "없음")
  L1(lower) ─┤  없으면 다음
  L2(lower) ─┤
  L3(lower) ─┘  최하위
```

### copy_up: 첫 쓰기의 대가

lower에만 있는 파일을 **쓰기용으로 열거나 메타데이터를 바꾸거나 hard-link를 만들면** copy_up이 트리거된다. 절차: ① upper에 상위 디렉터리 확보 → ② 동일 메타데이터로 객체 생성 → ③ 데이터 복사 → ④ xattr 이전. Docker 문서: "the copy_up operation only occurs the **first time** a given file is written to." 이후 쓰기는 이미 upper에 올라온 사본을 대상으로 한다. 그래서 **큰 파일의 1바이트 수정도 전체 복사** 비용을 한 번 치른다(그게 overlay 계열의 대표적 쓰기 지연 원인).

atomicity는 workdir로 보장한다 — 데이터를 workdir에 복사·`fsync(2)` 후 `rename(2)`(또는 `link(2)`)로 upper에 밀어넣어 copy_up을 원자적으로 만든다. 중간에 크래시해도 반쪽짜리 파일이 merged view에 노출되지 않는다.

### 삭제·가림의 표현 (whiteout / opaque)

upper에는 lower 파일을 "지울" 방법이 없으므로 마커로 표현한다:

- **whiteout**: "a character device with 0/0 device number" 또는 `trusted.overlay.whiteout` xattr를 가진 0바이트 파일. 이 이름이 있으면 하위 레이어의 동명 파일은 무시되고 whiteout 자신도 merged view에서 숨는다 → 사용자에겐 "삭제된 것처럼" 보인다.
- **opaque directory**: 디렉터리에 `trusted.overlay.opaque="y"` → 하위 레이어의 동명 디렉터리 내용을 통째로 가린다. `rm -rf` 후 같은 이름 디렉터리를 새로 만들 때 쓰인다.
- **metacopy**: 활성화 시 chown/chmod 같은 메타데이터-only 연산은 데이터 없이 `trusted.overlayfs.metacopy` xattr만 붙여 올리고, 실제 데이터 copy_up은 write 때로 미룬다.

마커별 표현과 효과를 정리하면:

| 상황 | upper의 표현 | merged view 결과 |
| --- | --- | --- |
| lower 파일 삭제 | 0/0 char device 또는 `trusted.overlay.whiteout` xattr 0B 파일 | 해당 이름 "없음"(whiteout 자신도 숨김) |
| 디렉터리 통째 가림 | dir에 `trusted.overlay.opaque=y` | 하위 레이어 동명 dir 내용 전부 무시 |
| 메타만 변경 | `trusted.overlayfs.metacopy` xattr(데이터 없음) | 조회는 upper 메타, 데이터는 여전히 lower |
| 파일 내용 수정 | copy_up된 실 데이터 사본 | upper 사본으로 완전 대체 |

### Docker overlay2가 이걸 조립하는 방식

`/var/lib/docker/overlay2/<id>/` 아래:

- `diff/` — 그 레이어 고유 내용(= 실제 파일들).
- `link` — 짧은 식별자 문자열. `l/<SHORT>` 심볼릭 링크가 이 `diff`를 가리킨다. mount 명령 인자 길이 제한을 피하려고 **긴 레이어 ID 대신 짧은 링크**를 lowerdir에 나열한다.
- `lower` — 부모(하위) 레이어들을 `l/...:l/...` 형태로 참조.
- `merged/`, `work/` — overlayfs가 관리(각각 마운트포인트, workdir).

컨테이너 생성 시 이미지 레이어들이 `lowerdir`(read-only), 컨테이너 전용 새 디렉터리가 `upperdir`(writable)이 된다. overlay2는 **최대 128개 lower 레이어**를 지원한다.

### 메모리 공유 — 밀도의 핵심

Docker 문서: "Multiple containers accessing the same file share a single **page cache** entry for that file." 여러 컨테이너가 같은 lower 파일을 읽으면 하위 레이어의 **동일 inode**를 참조하므로 커널 페이지 캐시를 **한 벌만** 쓴다. 컨테이너가 그 파일을 쓰기 시작하는 순간(copy_up) upper에 새 inode가 생겨 공유가 깨지고 그 컨테이너만 별도 캐시를 갖는다. 결과적으로 디스크(레이어 공유)뿐 아니라 RAM까지 아껴, 같은 이미지 기반 컨테이너를 대량으로 띄우는 고밀도 배치에 유리하다.

## 검증

xattr/whiteout를 직접 따라가 확인하는 흐름(개념 재현):

```bash
# lower를 가린 whiteout은 0/0 캐릭터 디바이스로 표현됨
ls -l merged/       # deleted.txt 안 보임
ls -l <upper>/diff  # c--------- ... 0, 0 deleted.txt  ← whiteout
# 첫 쓰기 후 upper diff에 사본이 생김을 확인
echo x >> merged/app.conf
ls <upper>/diff/    # app.conf 새로 등장 = copy_up 발생
```

- 이미지 여러 겹의 lower 체인은 `cat /var/lib/docker/overlay2/<id>/lower`로 `l/AB..:l/CD..` 나열을 직접 볼 수 있고, 각 `l/` 링크가 하위 `diff/`를 가리키는 것으로 스택을 따라갈 수 있다.

## 잘못 알고 있던 것

- **"컨테이너에서 파일을 지우면 이미지 용량이 준다"** — 아니다. lower는 불변이라 삭제는 upper의 **whiteout 마커**로만 표현된다. 데이터는 그대로 남고 오히려 마커 파일이 늘 뿐이라, 이미지 레이어 안의 파일은 이후 레이어에서 지워도 이미지 크기를 못 줄인다(빌드 시 같은 레이어에서 지워야 함).
- **"수정하면 diff만 저장된다(블록 단위 CoW)"** — overlay의 copy-on-write 단위는 **파일 전체**다. 1GB 파일의 1바이트만 바꿔도 최초 1회 통째로 copy_up 된다. 블록 단위 CoW는 btrfs/ZFS 계열 이야기다.
- **"lowerdir 순서는 왼쪽이 밑"** — 반대다. 커널 문서상 오른쪽이 최하위, 왼쪽으로 갈수록 위에 쌓인다.

## 더 파고들 만한 것

- overlayfs의 `redirect_dir`/`index` 기능과 rename가 lower에서 어떻게 처리되는지.
- fsync 폭주·`copy_up` 지연이 DB 컨테이너에서 문제되는 이유와 volume(bind mount)로 우회하는 원리.

## 참고

- Linux Kernel Docs — Overlay Filesystem: https://docs.kernel.org/filesystems/overlayfs.html
- Docker Docs — overlayfs storage driver: https://docs.docker.com/engine/storage/drivers/overlayfs-driver/
