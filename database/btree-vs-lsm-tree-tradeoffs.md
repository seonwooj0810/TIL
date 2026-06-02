# B+Tree vs LSM-Tree 트레이드오프

> **Primary source:** Alex Petrov, *Database Internals* (O'Reilly, 2019) — Part I, Ch.2 (B-Tree Basics), Ch.4 (Implementing B-Trees), Ch.7 (Log-Structured Storage)
> **Secondary:** O'Neil et al. "The Log-Structured Merge-Tree (LSM-Tree)" (Acta Informatica, 1996); RocksDB Wiki
> **Date:** 2026-06-02
> **Status:** draft

## 왜 봤나

- MySQL(InnoDB)은 B+Tree, RocksDB·Cassandra·LevelDB는 LSM-Tree를 쓴다. "왜 스토리지 엔진마다 다른 트리를 고르나"가 막연했다.
- 막연히 "LSM은 쓰기가 빠르고 B+Tree는 읽기가 빠르다"고만 외우고 있었는데, 그 이유를 read/write/space amplification 관점에서 정리하고 싶었다.

## 핵심 한 문장

> B+Tree는 **in-place 갱신**으로 페이지를 직접 덮어써 읽기 경로를 짧게 유지하는 대신 랜덤 쓰기를 유발하고, LSM-Tree는 **append-only + 나중에 병합(compaction)** 전략으로 쓰기를 순차화하는 대신 읽기와 공간을 희생한다. 둘은 같은 정렬 인덱스를 정반대 방향으로 최적화한 자료구조다.

## 내부 동작

### B+Tree — 페이지 단위 in-place 트리

Petrov Ch.2에 따르면 B+Tree는 디스크 블록(페이지) 크기에 맞춘 노드를 갖는 균형 트리다. 핵심 불변식:

- 모든 리프가 같은 깊이 (balanced).
- 노드 하나가 한 페이지(보통 4KB~16KB). fanout이 수백 단위라 트리 높이가 매우 낮다.
- **키-값은 리프에만**, 내부 노드는 separator key + 자식 포인터만 보관(이것이 B-Tree와 구분되는 B+Tree의 특징). 리프끼리 sibling 포인터로 연결되어 범위 스캔이 리프 체인 순회로 끝난다.

```
            [ 50 | 90 ]              <- internal (separator only)
           /    |     \
     [..30][50..70][90..]           <- leaf (key+value), linked: -> -> ->
```

조회는 루트→리프 경로를 따라간다. 높이가 h면 점조회는 O(log_fanout N), 실제로 수억 건도 h=3~4 수준이다.

**쓰기가 비싼 이유 (Ch.4):** 갱신은 해당 키가 속한 리프 페이지를 찾아 **그 자리(in-place)에서 수정**한다. 페이지가 디스크 곳곳에 흩어져 있으면 갱신은 랜덤 I/O가 된다. 또 리프가 꽉 차면 **split**이 일어나 separator key가 부모로 전파되고, 부모도 차면 위로 연쇄된다(재귀적 split, 최악엔 루트까지 올라가 높이 증가). 삭제로 점유율이 낮아지면 merge/rebalance가 발생한다. 부분 페이지만 바꿔도 페이지 전체를 다시 써야 하므로 **write amplification**이 생긴다.

상태 전이(리프 insert) 요약:

| 상황 | 동작 |
| --- | --- |
| 리프에 여유 있음 | 페이지 내 정렬 위치에 삽입, 그 페이지만 dirty |
| 리프 full | split → 중앙 키를 부모로 승격 → 부모에 재귀 |
| 부모도 full | 위로 split 전파, 최악엔 새 루트 생성(높이+1) |

### LSM-Tree — append-only + compaction

Petrov Ch.7과 1996 원논문에 따르면 LSM은 쓰기를 **메모리의 정렬 구조(MemTable)** 에 모았다가, 가득 차면 디스크에 **불변(immutable) SSTable**로 통째로 flush한다. 한 번 쓴 SSTable은 절대 in-place 수정하지 않는다.

자료구조 구성:

- **MemTable**: 메모리상의 정렬 자료구조(주로 skip list / 균형 트리). 쓰기는 여기에만 들어간다 → 디스크 I/O 없음.
- **WAL(commit log)**: 내구성 보장용. MemTable 쓰기 전에 append-only 로그에 기록.
- **SSTable (Sorted String Table)**: 키로 정렬된 불변 파일. sparse index + 보통 Bloom filter 동반.

```
write ─▶ WAL(append) ─▶ MemTable(정렬, in-mem)
                              │ full?
                              ▼ flush (순차 쓰기)
        ┌──────────────── SSTable ────────────────┐
 L0:  [SST][SST][SST]        (겹치는 키 범위 허용)
 L1:  [ SST ][ SST ]         compaction으로 병합·정렬
 L2:  [   SST   ][   SST   ]
```

**갱신·삭제도 append:** 같은 키를 또 쓰면 새 버전이 상위 레벨에 쌓이고, 삭제는 **tombstone**이라는 삭제 마커를 append한다. 실제 데이터 제거와 중복 정리는 background **compaction**이 SSTable들을 merge-sort로 병합하면서 수행한다. 이때 같은 키의 옛 버전·tombstone을 버린다.

**읽기가 비싼 이유:** 한 키가 MemTable, L0의 여러 SSTable, 하위 레벨에 동시에 존재할 수 있다. 따라서 조회는 최신부터 여러 곳을 뒤져야 한다. 이를 줄이려 각 SSTable에 **Bloom filter**를 둬 "이 파일엔 없음"을 빠르게 판정한다(false positive만 존재, false negative 없음). 그래도 존재하는 키나 범위 스캔은 여러 SSTable을 병합 순회해야 한다.

**Compaction 전략 (RocksDB Wiki):**
- **Size-tiered**: 비슷한 크기 SSTable이 여러 개 모이면 병합. 쓰기 증폭이 낮지만 같은 키가 여러 파일에 퍼져 **공간 증폭**이 크다.
- **Leveled**: 레벨별로 키 범위가 겹치지 않게 유지(L0 제외). 읽기·공간 증폭은 낮지만 병합이 잦아 **쓰기 증폭**이 크다.

### 세 가지 amplification으로 본 트레이드오프

Petrov는 스토리지 엔진을 read/write/space amplification의 균형으로 설명한다. 세 가지를 동시에 최소화할 수는 없다("RUM conjecture"와 같은 맥락).

| 지표 | B+Tree | LSM-Tree |
| --- | --- | --- |
| Write amplification | 페이지 split·부분갱신 → 중간 | compaction 재기록 → 전략 따라 큼(leveled) |
| Read amplification | 경로 1회 + 리프 1페이지 → 작음 | 여러 SSTable·Bloom 조회 → 큼 |
| Space amplification | 페이지 단편화(fill factor) → 중간 | 중복 버전·tombstone 잔존 → 큼(size-tiered) |
| 쓰기 패턴 | 랜덤 in-place | 순차 append |

순차 쓰기가 랜덤 쓰기보다 압도적으로 싼 매체(특히 디스크, SSD에서도 GC 측면)에서 LSM의 쓰기 처리량이 유리하다고 알려져 있다.

## 검증

직접 코드 실험 대신 두 오픈소스의 실제 선택을 출처로 따라가 봤다.

- **InnoDB (MySQL Reference Manual §14.6)**: clustered index가 B+Tree. PK 순서로 리프에 row가 저장되고 secondary index 리프는 PK를 값으로 갖는다 → 점조회·범위 스캔이 짧은 경로로 끝나는 OLTP 읽기에 유리. 이는 [[innodb-mvcc-undo-log-read-view]]에서 본 undo log 기반 in-place 갱신과도 맞물린다.
- **RocksDB (Wiki, Leveled Compaction)**: MemTable→L0 flush→leveled compaction 구조. write-heavy·SSD 환경 처리량을 노린 설계로, 읽기 비용은 Bloom filter + block cache로 상쇄한다.

흐름을 따라가 보면 "어느 트리가 우월하다"가 아니라 **워크로드(읽기/쓰기 비율)와 매체 특성에 따른 선택**임이 드러난다.

## 잘못 알고 있던 것

- **"LSM은 항상 쓰기가 빠르다"** — 사용자 입장 쓰기 지연은 낮지만, background compaction이 같은 데이터를 여러 번 재기록하므로 **누적 디스크 쓰기량(write amplification)은 오히려 클 수 있다**. 특히 leveled compaction에서 그렇다.
- **"B+Tree는 append-only다"** — 반대다. B+Tree의 핵심은 **in-place 갱신**이다. append-only로 변경 이력을 쌓는 건 LSM 쪽이다.
- **"Bloom filter가 범위 스캔도 빠르게 해준다"** — Bloom filter는 **점조회(이 키 있나?)** 의 음성 판정에만 쓸 수 있다. 범위 스캔은 키를 특정할 수 없어 Bloom filter로 SSTable을 건너뛸 수 없다.

## 더 파고들 만한 것

- LSM의 **Leveled vs Size-tiered vs Universal compaction** 비교와 각 amplification 수치 (RocksDB tuning).
- **Fractional cascading / Bw-Tree** 같은 lock-free·하이브리드 변형 (SQL Server Hekaton).
- InnoDB **change buffer**가 secondary index 랜덤 쓰기를 어떻게 LSM처럼 지연·배치 처리하는지.

## 참고

- Alex Petrov, *Database Internals*, Ch.2 / Ch.4 / Ch.7
- O'Neil, Cheng, Gawlick, O'Neil, "The Log-Structured Merge-Tree (LSM-Tree)", 1996
- RocksDB Wiki — Leveled Compaction, Bloom filters
- MySQL Reference Manual §14.6 — InnoDB and the B-tree Index
