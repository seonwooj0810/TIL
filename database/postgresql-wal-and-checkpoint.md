# PostgreSQL WAL과 체크포인트: 충돌 복구를 보장하는 내부 동작

> **Primary source:** PostgreSQL 16 Documentation — Ch.30 "Write-Ahead Logging (WAL)", Ch.29 "Reliability and the Write-Ahead Log" (§29.4 WAL Configuration, §29.5 WAL Internals)
> **Secondary:** PostgreSQL 소스 `src/backend/access/transam/xlog.c` 주석 (REDO point / checkpoint 설명)
> **Date:** 2026-06-28
> **Status:** draft

## 왜 봤나

- "commit 하면 데이터가 디스크에 써진다"고 막연히 알고 있었는데, 그러면 매 commit마다 랜덤 위치 데이터 페이지를 fsync 해야 해서 느릴 텐데 어떻게 빠른지 설명이 안 됐다.
- 그리고 "체크포인트가 WAL을 디스크에 내린다"고 헷갈리고 있었다. 실제론 거의 반대 방향이라 정리가 필요했다.

## 핵심 한 문장

> WAL은 **데이터 페이지를 고치기 전에 변경 내용을 먼저 순차 로그로 디스크에 기록(write-ahead)** 해서, commit 시점엔 작은 로그만 fsync 하고 실제 데이터 페이지 flush는 체크포인트로 미루는 — durability와 성능을 동시에 잡는 메커니즘이다.

## 내부 동작

### 1. WAL-before-data 규칙과 LSN

모든 변경(INSERT/UPDATE/DELETE, 인덱스 갱신 등)은 먼저 **WAL 레코드**로 만들어져 WAL 버퍼에 append 되고, 그 다음에야 shared buffer의 데이터 페이지가 수정된다. 핵심 불변식:

> 어떤 더티 데이터 페이지를 디스크에 쓰기 전에, **그 페이지를 변경시킨 WAL 레코드가 먼저 디스크에 flush** 되어 있어야 한다. (WAL-before-data, 공식 문서 §30.3)

이걸 강제하는 장치가 **LSN(Log Sequence Number)** — WAL 스트림 안에서의 바이트 오프셋이며 단조 증가한다. 모든 데이터 페이지 헤더에는 그 페이지를 마지막으로 바꾼 WAL 레코드의 LSN(`pd_lsn`)이 박혀 있다. 버퍼 매니저가 더티 페이지를 내보낼 때:

```
flush_data_page(page):
    XLogFlush(page.pd_lsn)   # 이 페이지 LSN까지 WAL을 먼저 디스크로
    write(datafile, page)    # 그 다음에 데이터 페이지 기록
```

즉 데이터 페이지의 디스크 쓰기는 항상 대응 WAL flush에 뒤따른다. 덕분에 크래시가 나도 "데이터엔 반영됐는데 로그엔 없는" 상태가 생기지 않는다.

### 2. commit 시점에 실제로 일어나는 일 (no-force)

commit 하면 commit WAL 레코드를 쓰고 `XLogFlush(commitLSN)` 으로 **거기까지의 WAL만 fsync** 한다. 이때 그 트랜잭션이 더럽힌 데이터 페이지들은 **디스크로 내리지 않는다**(no-force 정책). 데이터 페이지는 나중에 background writer나 checkpointer가 한가할 때, 또는 버퍼가 부족해 evict될 때 내려간다.

이게 성능의 핵심이다. WAL은 **순차 append**라 디스크 한 곳에 몰아 쓰지만, 데이터 페이지 flush는 테이블 곳곳의 **랜덤 위치**다. 매 commit마다 랜덤 fsync를 하는 대신 순차 로그만 fsync하고, 랜덤 쓰기는 모아서 체크포인트로 분산한다.

```
시간 ──────────────────────────────────────▶
WAL:  [..rec][commit rec]│fsync(commit)         ← commit은 여기서 끝
buf:  page A,B dirty (메모리에만)
                          └─(나중에)─▶ checkpointer가 A,B flush
```

### 3. 체크포인트 — REDO point를 끌어올려 복구 비용/WAL을 줄임

체크포인트는 "이 시점 이전의 모든 더티 페이지를 데이터 파일에 안전히 내렸다"고 보장하는 지점이다. 동작 순서(개념):

1. 현재 WAL 위치를 **REDO point**로 기록(이후 복구는 여기서 시작).
2. 그 시점까지 더티였던 shared buffer를 전부 데이터 파일에 write.
3. `pg_control`에 체크포인트 레코드 위치를 기록하고 fsync.
4. REDO point 이전을 다루는 WAL 세그먼트는 더 이상 복구에 불필요 → **recycle/삭제** 가능.

체크포인트 발동 조건: `checkpoint_timeout`(기본 5분) 경과, `max_wal_size`(기본 1GB) 초과 임박, 또는 수동 `CHECKPOINT`. 한 번에 몰아 flush하면 I/O 스파이크가 생기므로 `checkpoint_completion_target`(기본 0.9)에 맞춰 다음 체크포인트 예상 시점의 90% 지점까지 쓰기를 **분산(spread checkpoint)** 한다.

```
checkpoint ─────── checkpoint_timeout(5m) ─────── checkpoint
   │REDO point                                       │
   ▼                                                 ▼
   ├── dirty buffer flush를 이 구간의 0.9까지 천천히 ──┤
```

### 4. Full Page Writes — torn page 방어

OS/디스크의 원자적 쓰기 단위(흔히 512B~4KB)는 PostgreSQL 페이지(기본 8KB)보다 작다. 크래시가 페이지 쓰기 도중에 나면 **앞 4KB는 신버전, 뒤 4KB는 구버전**인 torn page가 생길 수 있다. WAL 레코드는 보통 "이 페이지의 이 오프셋을 이렇게 바꿔라"는 **델타**라, 베이스 페이지가 깨졌으면 델타를 적용해도 복구가 안 된다.

그래서 `full_page_writes=on`(기본)이면, **각 체크포인트 직후 그 페이지를 처음 변경할 때 페이지 전체 이미지(FPI)를 WAL에 통째로** 싣는다. 복구 시엔 이 풀 이미지로 페이지를 통째 덮어쓴 뒤 이후 델타를 적용 → torn page여도 안전. 대신 체크포인트 직후 WAL이 부풀어 오른다(체크포인트를 너무 자주 돌리면 안 되는 이유 중 하나).

### 5. 크래시 복구 (REDO)

재기동 시 `pg_control`에서 마지막 체크포인트의 **REDO point**를 읽고, 거기서부터 WAL을 순차로 읽으며 replay 한다. 각 WAL 레코드에 대해 대상 페이지를 읽어 `page.pd_lsn < record.LSN` 이면(아직 미반영) 적용, 아니면 건너뛴다(이미 반영됨). 이 LSN 비교가 **멱등 복구**를 만든다 — 같은 WAL을 여러 번 돌려도 결과가 같다. commit 레코드가 WAL에 있는 트랜잭션만 최종 커밋으로 살아남는다.

## 검증

공식 문서 §29.5와 `pg_controldata` 출력을 따라가며 개념을 확인한 흐름(인라인 재현):

```sql
-- 현재 WAL 위치(LSN). 단조 증가하는 바이트 오프셋임을 확인
SELECT pg_current_wal_lsn();              -- 예: 3/A52C1F0

-- 강제로 체크포인트 → 이후 REDO point가 위로 당겨짐
CHECKPOINT;

-- 두 LSN의 차이는 '바이트 거리'로 계산된다(LSN이 오프셋이라는 증거)
SELECT pg_wal_lsn_diff('3/A52C2A0', '3/A52C1F0');   -- = 177 (바이트)
```

```
$ pg_controldata $PGDATA | grep -E "REDO|checkpoint location"
Latest checkpoint location:        3/A52C2A0
Latest checkpoint's REDO location: 3/A52C2A0   # 복구는 여기서 시작
```

commit 직후 데이터 파일이 즉시 바뀌지 않는다는 것은, commit 후 곧바로 `kill -9`로 죽여도 재기동 시 WAL replay로 데이터가 복원된다는 사실(공식 문서가 보장하는 durability)로 확인된다 — 데이터 파일이 아니라 WAL이 진실의 원천이다.

## 잘못 알고 있던 것

- **"체크포인트가 WAL을 디스크에 flush한다"** → 반대에 가깝다. WAL flush는 **commit마다**(`XLogFlush`) 일어난다. 체크포인트가 내리는 건 **데이터 페이지(더티 버퍼)** 이고, 그 결과로 오래된 WAL을 **recycle/삭제**할 수 있게 된다.
- **"commit하면 그 행이 데이터 파일에 써진다"** → 아니다. commit은 작은 WAL 레코드만 순차 fsync(no-force). 데이터 페이지는 checkpointer/bgwriter가 나중에 랜덤 쓰기로 내린다. commit의 durability는 데이터 파일이 아니라 **WAL fsync** 가 책임진다.
- **"WAL은 복제·백업용 부가 기능"** → crash recovery의 본체다. 복제(streaming replication)·PITR가 WAL을 재사용하는 건 부수 효과지, WAL의 1차 목적은 단일 노드의 durability와 복구다.
- **"full_page_writes는 그냥 안전 옵션, 꺼도 비슷"** → torn page 방어 장치다. 끄면 체크포인트 직후 부분 페이지 쓰기 중 크래시에 데이터가 깨질 수 있다(파일시스템이 페이지 원자성을 보장하는 특수 환경이 아닌 한 켜둬야 함).

## 더 파고들 만한 것

- `synchronous_commit` 단계(on/remote_apply/local/off)와 group commit — commit 지연 vs durability 트레이드오프.
- WAL을 이용한 streaming replication / PITR에서 REDO point·timeline 개념이 어떻게 확장되는가.
- InnoDB의 redo log + doublewrite buffer와 비교: full page writes ≈ doublewrite의 역할 차이.

## 참고

- PostgreSQL 16 Documentation, Ch.30 Write-Ahead Logging; Ch.29 §29.4–29.5.
- `src/backend/access/transam/xlog.c` (REDO point, CreateCheckPoint 주석).
- 비교용: [InnoDB MVCC undo log·Read View 노트](./innodb-mvcc-undo-log-read-view.md)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
