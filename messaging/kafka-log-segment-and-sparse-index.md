# Kafka 로그 세그먼트와 sparse index: offset으로 메시지를 O(log n)에 찾는 법

> **Primary source:** Apache Kafka Documentation — "Log" / "Persistence" (kafka.apache.org/documentation/#design), Kafka 소스 `core/.../OffsetIndex.scala`, `LogSegment.scala`
> **Secondary:** Kafka: The Definitive Guide 2nd ed. Ch.5 (Physical Storage), `kafka-dump-log.sh` 출력
> **Date:** 2026-06-30
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/kafka-log-segment-sparse-index

## 왜 봤나

- Kafka가 토픽 파티션 하나에 수억 건을 쌓아두고도 특정 offset부터 읽기를 "즉시" 시작하는 게 어떻게 가능한지 궁금했다. 파일을 처음부터 스캔하면 O(n)일 텐데.
- 막연히 "offset = 파일의 byte 위치"라고 생각했는데, 그러면 가변 길이 레코드와 맞지 않는다는 걸 깨닫고 내부 구조를 따라가 봤다.

## 핵심 한 문장

> Kafka 파티션은 append-only 세그먼트 파일들의 나열이고, 각 세그먼트는 **일정 byte마다 한 번씩만** offset→파일 위치를 기록한 **희소(sparse) 인덱스**를 mmap으로 들고 있어, offset 조회는 "인덱스 이진 탐색 + 짧은 선형 스캔"으로 끝난다.

## 내부 동작

### 1. 디렉터리 레이아웃 — 파티션은 세그먼트의 나열

파티션 디렉터리(`<topic>-<partition>/`) 안에는 세그먼트 3종 파일이 base offset 이름으로 묶여 산다:

```
my-topic-0/
  00000000000000000000.log        # 실제 레코드 (append-only)
  00000000000000000000.index       # offset  → 물리 위치 (sparse)
  00000000000000000000.timeindex    # timestamp → offset (sparse)
  00000000000000368122.log         # 다음 세그먼트, base offset=368122
  00000000000000368122.index
  ...
```

파일명 20자리 숫자 = 그 세그먼트의 **base offset**(첫 레코드의 절대 offset). 활성 세그먼트(active segment) 하나에만 append가 일어나고, `log.segment.bytes`(기본 1GB)를 넘거나 `log.roll.ms`(기본 7일)가 지나면 **롤(roll)** 해서 새 세그먼트를 연다. base offset을 파일명에 박아두기에, 어떤 offset이 어느 세그먼트에 있는지는 파일을 열지 않고 이름만 보고도 좁힐 수 있다 — 이게 뒤의 1단계 탐색을 가능하게 한다.

세그먼트는 두 상태로 나뉜다. **활성(active)** 세그먼트는 append 대상이라 인덱스 파일이 max 크기로 mmap·preallocate되어 있고, **닫힌(closed)** 세그먼트는 더 이상 쓰기가 없어 인덱스가 실제 크기로 truncate·읽기 전용이 된다. 롤은 곧 "활성 → 닫힘" 상태 전이이며, 이때 인덱스/타임인덱스도 함께 마감된다.

### 2. .index의 자료구조 — 8바이트 고정 엔트리

OffsetIndex 엔트리는 정확히 **8바이트** 고정:

```
[ relative offset : 4B (int) ][ physical position : 4B (int) ]
```

- `relative offset` = 절대 offset − base offset. 4바이트라서 세그먼트 하나는 최대 2^31개 레코드. base offset을 파일명으로 빼두기 때문에 4바이트로 충분하다.
- `physical position` = 그 레코드가 `.log` 안에서 시작하는 byte 오프셋. 4바이트라 세그먼트는 ~4GB가 상한(그래서 `log.segment.bytes` 기본이 1GB대).

핵심은 **모든 레코드마다 엔트리를 만들지 않는다**는 점이다. `log.index.interval.bytes`(기본 4096)만큼 `.log`에 쌓일 때마다 한 번씩만 엔트리를 추가한다 → 그래서 sparse. 100만 건이 쌓여도 인덱스 엔트리는 수천 개 수준이라 통째로 메모리에 올린다.

### 3. mmap — 인덱스는 메모리 매핑된 채로 산다

`.index`는 `MappedByteBuffer`로 메모리 매핑(mmap)된다. 세그먼트가 활성일 때 `log.index.size.max.bytes`(기본 10MB)로 **미리 할당**해 두고, 롤되며 닫힐 때 실제 크기로 truncate한다. 덕분에 인덱스 탐색은 디스크 I/O가 아니라 OS 페이지 캐시 위의 메모리 접근이다.

### 4. offset 조회 알고리즘 — 두 단계 이진 탐색

소비자가 offset `X`를 요청하면:

```
1) 세그먼트 선택:
   세그먼트 base offset들을 정렬해 둔 SkipList에서
   floor(X) — 즉 base ≤ X 인 가장 큰 세그먼트 — 를 고른다.   O(log S)

2) 세그먼트 내부:
   해당 .index에서 relativeOffset ≤ (X − base) 인
   가장 큰 엔트리를 이진 탐색 → 시작 physical position p.   O(log E)

3) 선형 스캔:
   .log 의 p 부터 레코드를 앞으로 읽으며
   offset == X 인 레코드를 만날 때까지 스캔.  (최대 ~4KB 분량)
```

sparse라서 인덱스가 가리키는 위치는 항상 X보다 "조금 앞"(또는 같음)이다 — 이진 탐색이 `relOff ≤ 목표`인 **하한**을 고르기 때문에, 스캔은 절대 X를 지나쳐 시작하지 않는다. 그 간극은 최대 `index.interval.bytes`(≈4KB)라 선형 스캔 비용이 상수로 묶인다. 전체는 사실상 O(log n) + 상수 스캔. 만약 인덱스가 비었거나 X가 첫 엔트리보다 앞이면 세그먼트 시작(position 0)부터 스캔한다.

```
.index (sparse)                 .log
relOff  pos                     pos
  0  ->   0      ─────────────►  0:  off=0   ...
 33  -> 4096     ─────────────►  4096: off=33 ...   ← X=37 요청 시
 70  -> 8210                       4096부터 스캔해 off=37 도달
```

### 5. .timeindex — 시간 기반 조회

`offsetsForTimes`(타임스탬프로 offset 찾기)를 위해 12바이트 엔트리 `[timestamp:8B][relative offset:4B]`를 같은 주기로 쌓는다. 이진 탐색으로 `timestamp ≥ T`인 첫 지점을 찾아 offset으로 환산한 뒤, 다시 OffsetIndex 경로로 들어간다.

### 6. 왜 빠른가 — sequential write + page cache + zero-copy

- **append-only 순차 쓰기**: 디스크 헤드 이동/랜덤 쓰기가 없어 HDD에서도 빠르다.
- **page cache 의존**: Kafka는 자체 캐시를 거의 두지 않고 OS 페이지 캐시에 읽기/쓰기를 맡긴다. 최근 데이터는 보통 캐시에 떠 있어 디스크를 안 친다.
- **zero-copy**: 소비자에게 보낼 때 `FileChannel.transferTo`(→ 리눅스 `sendfile`)로 페이지 캐시에서 소켓으로 바로 보낸다. user space로의 복사가 없다.

## 검증

`kafka-dump-log.sh`로 인덱스/로그를 직접 떠보면 sparse 구조가 보인다(공식 도구 출력 형태):

```
$ kafka-dump-log.sh --files 00000000000000000000.index --print-data-log
offset: 0     position: 0
offset: 33    position: 4096      # 33건마다가 아니라 ~4096B마다
offset: 70    position: 8210
...
```

`offset`이 0,1,2…로 촘촘하지 않고 4096바이트가 쌓일 때마다 한 칸씩 건너뛴다 — 즉 엔트리 수 ≪ 레코드 수임을 눈으로 확인할 수 있다. `.log`를 같은 도구로 떠보면 각 레코드 배치의 `position`이 인덱스의 position과 정확히 맞물린다.

엔트리가 8바이트 고정이라는 것도 산술로 확인된다: `.index` 파일 크기 / 8 = 엔트리 개수.

## 잘못 알고 있던 것

- **"offset이 곧 파일의 byte 위치"** — 아니다. offset은 **논리적 일련번호**고, byte 위치(physical position)는 별도로 인덱스가 매핑한다. 레코드는 가변 길이라 offset×고정크기 같은 계산이 성립하지 않는다.
- **"인덱스는 레코드마다 한 줄씩 있는 dense 인덱스"** — 아니다. `log.index.interval.bytes`(기본 4KB) 간격의 **sparse** 인덱스다. 그래서 작아서 메모리에 다 올라가고, 대신 마지막에 짧은 선형 스캔이 따라붙는다.
- **"소비할 때마다 디스크를 읽는다"** — 보통은 아니다. 최근 데이터는 OS 페이지 캐시에 있고, zero-copy(sendfile)로 캐시→소켓 직행이라 broker CPU/메모리 부담이 작다. 디스크를 치는 건 캐시에서 밀려난 오래된 offset을 읽을 때다.

## 더 파고들 만한 것

- **Log compaction**: cleaner가 키별 최신 값만 남기며 세그먼트를 재작성하는 동작과 `.log`/오프셋맵(dedupe) 구조.
- **Retention 삭제**: `log.retention.*`에 따라 세그먼트 단위로 통째 삭제할 때 활성 세그먼트가 보호되는 규칙.

## 참고

- Apache Kafka Documentation — Design / Persistence, Log 섹션
- Kafka 소스: `OffsetIndex`, `TimeIndex`, `LogSegment`, `LogSegments`(세그먼트 SkipList)
- Kafka: The Definitive Guide (2nd ed.) Ch.5 — Physical Storage

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
