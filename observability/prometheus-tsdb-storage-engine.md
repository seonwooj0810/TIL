# Prometheus TSDB 저장 엔진: WAL·Head·Gorilla 압축·블록 compaction

> **Primary source:** Prometheus `tsdb` 소스 (`tsdb/chunkenc/xor.go`, `tsdb/head.go`, `tsdb/wlog`, `tsdb/index`) / Prometheus Docs "Storage" / Gorilla 논문 (Pelkonen et al., VLDB 2015)
> **Secondary:** Fabian Reinartz "Writing a Time Series Database from Scratch" (2017)
> **Date:** 2026-07-22
> **Status:** draft

## 왜 봤나

- 메트릭이 초당 수만 개씩 쏟아지는데 Prometheus 한 노드가 어떻게 이걸 다 저장하고 몇 주씩 보관하는지 궁금했다. 막연히 "샘플마다 timestamp 8B + value 8B로 쌓겠지" 생각했는데, 그렇다면 디스크가 진작 터졌어야 한다.
- 샘플 하나가 평균 **1~2바이트**로 줄어든다는 말을 보고, 그 압축(Gorilla)이 정확히 어떤 자료구조인지 끝까지 따라가 보기로 했다.

## 핵심 한 문장

> Prometheus TSDB는 들어온 샘플을 **① WAL에 비압축 append(내구성) → ② 메모리 Head 청크에 delta-of-delta+XOR로 압축(Gorilla) → ③ 청크가 차면 mmap → ④ 2시간 경과분을 불변 블록(chunks+역색인 index)으로 compaction** 하는, 쓰기 경로와 압축 시점이 분리된 append-only 엔진이다.

## 내부 동작

### 데이터 모델
하나의 **시리즈**는 라벨 집합(메트릭 이름도 `__name__` 라벨)으로 유일하게 식별되고, `(timestamp int64 ms, value float64)` 샘플의 시퀀스를 가진다. 저장 단위는 시리즈별 **청크(chunk)** 이며, 기본 `XORChunk` 하나는 **최대 120 샘플** 또는 청크 시간 범위를 넘으면 잘린다(cut).

### 쓰기 경로
```
scrape → Appender
   │
   ├─(1) WAL append  ── wal/ 세그먼트(128MB), record: series/samples/tombstones/exemplars
   │        · 비압축, 순차 write. 크래시 복구 전용.
   │
   └─(2) Head 메모리 청크에 append (압축 인코딩)
            · headChunk 가 꽉 참(120샘플/범위) → chunks_head/ 로 flush 후 mmap
            · 활성(append 중) 청크만 힙에 상주, 나머지는 mmap 참조만 유지
```
핵심은 **압축이 디스크 쓰기 시점이 아니라 메모리 청크 append 시점에 일어난다**는 것. WAL은 순차 append라 빠르고, 압축된 in-memory 청크가 진짜 저장 표현이다. 청크를 120 샘플에서 자르고 mmap으로 넘기는 이유는 힙 관리 때문 — append 중인 청크만 GC가 훑는 힙에 두고 나머지는 파일로 밀어 OS 페이지 캐시에 맡기면, 활성 시리즈가 수십만 개여도 상주 힙이 시리즈 헤더와 마지막 청크 수준으로 억제된다.

### Gorilla 압축 (`xor.go`)
**타임스탬프 — delta-of-delta.** 스크레이프 간격이 거의 일정(예 15s)하므로 `DoD = (tₙ−tₙ₋₁) − (tₙ₋₁−tₙ₋₂)` 는 대부분 0이다. Prometheus 구현의 인코딩(제어비트 + 비트폭):
| 조건 | 제어비트 | 데이터 비트 |
| --- | --- | --- |
| DoD == 0 | `0` | 0 |
| ∈ 14비트 범위 | `10` | 14 |
| ∈ 17비트 범위 | `110` | 17 |
| ∈ 20비트 범위 | `1110` | 20 |
| 그 외 | `1111` | 64 |

즉 간격이 안 흔들리면 **샘플 하나의 타임스탬프가 단 1비트**로 줄어든다. (첫 샘플은 raw, 둘째는 delta 그대로 저장.)

**값 — 이전 값과 XOR.** 값이 그대로면 `XOR==0` → `0` 한 비트. 다르면 `1` + 다음 분기:
- 이번 XOR의 leading/trailing 0 개수가 **직전 "의미 블록" 창 안에 들어가면** → `10` + 이전 창 재사용, 의미 비트만 기록.
- 벗어나면 → `11` + leading-zero 5비트 + 의미블록 길이 6비트 + 의미 비트.

게이지처럼 조금씩 변하는 float은 XOR 결과의 상·하위가 0으로 몰려 의미 비트가 얼마 안 된다. Gorilla 논문은 실운영 데이터에서 timestamp+value 합쳐 **평균 약 1.37바이트/샘플**(16B 대비 ~12×)을 보고한다.

### 재시작과 복구
셧다운/크래시 후 기동 시: `chunks_head/`의 mmap 청크를 참조로 되살린 뒤, **WAL을 리플레이**하되 이미 mmap 청크에 반영된 구간은 건너뛰고 그 이후 샘플만 메모리로 올린다. WAL은 무한정 자라지 않게 **checkpoint**로 잘린다 — 오래된 세그먼트를 순회하며 아직 필요한 series/샘플 레코드만 새 checkpoint로 옮기고 원본 세그먼트를 삭제.

### Compaction과 불변 블록
Head에서 청크 범위(기본 2h)를 벗어난 데이터는 백그라운드로 디스크의 **영구 블록**으로 잘려 나가고, 그 만큼 Head와 WAL이 truncate된다. 이후 인접 블록들은 더 큰 블록으로 병합(compaction)된다 — 블록 크기는 보존 기간의 10% 또는 31일 중 작은 값까지 커진다(공식 docs). 블록 하나의 디렉터리 구조:
```
01ABC.../
  ├─ chunks/000001   압축된 청크 바이트 (세그먼트 파일, 최대 512MB)
  ├─ index           역색인(postings) + 심볼테이블 + 시리즈→청크 위치
  ├─ meta.json       min/maxTime, 샘플/시리즈 수, compaction level
  └─ tombstones      삭제 마커
```
블록은 **불변(immutable)**. 그래서 `delete` API는 데이터를 즉시 지우지 않고 **tombstone에 (시리즈, 시간범위)만 기록**하며, 실제 물리 삭제는 다음 compaction이 재기록할 때 반영된다.

### 역색인(index)로 쿼리 풀기
`index` 파일은 라벨 매칭을 위한 **inverted index**다. `label=value` → 그 라벨을 가진 **시리즈 ID의 오름차순 리스트(postings list)**. 모든 라벨 문자열은 **심볼 테이블**에 중복 제거되어 offset으로만 참조된다(index 크기 절감). `up{job="api"}` 같은 쿼리는 `__name__="up"` postings와 `job="api"` postings를 **정렬 리스트 교집합**(merge/seek)으로 좁힌 뒤, 각 시리즈 레코드에 담긴 청크 위치(min/maxTime + chunks 파일 offset)로 실제 데이터를 읽는다. postings가 오름차순으로 정렬돼 있기에 교집합이 두 커서를 앞으로만 밀며 진행하는 선형 merge(또는 큰 쪽을 건너뛰는 galloping)로 끝나는 게 포인트다. 정규식 `=~`은 해당 라벨의 값들을 훑어 postings를 합집합한다. 라벨 없는 전체 스캔용으로는 모든 시리즈를 담은 특수 postings(`""` 키)도 유지된다.

## 검증

`xor.go`의 append 로직을 손으로 따라가 보면(15s=15000ms 간격, 값 고정 42.0 가정):

```
t0=1000, v0=42.0  → t0 raw(varint) + v0 raw(64bit)
t1=16000, v1=42.0 → delta=15000 기록 + (v XOR==0 → '0' 1비트)
t2=31000, v2=42.0 → DoD=(31000-16000)-(16000-1000)=0 → '0' 1비트
                     + 값 XOR==0 → '0' 1비트  ⇒ 이 샘플 총 2비트
```
즉 카운터/게이지가 일정 간격으로 같은(혹은 규칙적으로 증가하는) 값을 뱉으면 샘플당 몇 비트로 수렴한다. 반대로 값이 매 스크레이프 크게 요동치면 XOR 의미 비트가 커져 압축률이 떨어진다 — "고카디널리티/고엔트로피가 저장을 키운다"가 여기서 정량적으로 보인다.

## 잘못 알고 있던 것

- **"Prometheus는 샘플을 받자마자 디스크에 압축 저장한다."** → 아니다. 쓰기 경로에서 디스크로 먼저 가는 건 **비압축 WAL**(내구성용)이고, Gorilla 압축은 **메모리 Head 청크 append 시점**에 일어난다. 압축된 데이터가 디스크의 영구 블록으로 내려가는 건 2시간 뒤 compaction이다. 압축 시점과 디스크 내구성 시점은 별개다.
- **"샘플 하나는 timestamp 8B + value 8B = 16B."** → 원시 표현일 뿐 저장 표현이 아니다. delta-of-delta로 규칙적 간격 타임스탬프는 1비트까지, XOR로 안정적 값도 1비트까지 줄어 **평균 1~2바이트/샘플** 수준이 된다.
- **"delete 하면 그 시계열이 바로 사라진다."** → 블록은 불변이라 tombstone에 마커만 남고, 실제 제거는 다음 compaction의 재기록에서 이뤄진다.

## 더 파고들 만한 것

- Head의 append **isolation**(append id로 부분 append가 쿼리에 안 보이게 하는 MVCC 유사 메커니즘).
- `index` 파일 포맷 v2의 postings offset table과 galloping 교집합 구현.
- Remote write / remote read와 Thanos·Mimir가 이 블록 포맷을 오브젝트 스토리지로 확장하는 방식.

## 참고

- Prometheus Docs — Storage (`localhost` TSDB on-disk layout, block/WAL 설명)
- `prometheus/prometheus` 소스: `tsdb/chunkenc/xor.go`, `tsdb/head.go`, `tsdb/wlog/`, `tsdb/index/`
- Pelkonen et al., "Gorilla: A Fast, Scalable, In-Memory Time Series Database", VLDB 2015 (delta-of-delta + XOR)
- Fabian Reinartz, "Writing a Time Series Database from Scratch" (2017)
