# PostgreSQL MVCC 튜플 가시성: xmin/xmax와 스냅샷이 만드는 HeapTupleSatisfiesMVCC 판정

> **Primary source:** PostgreSQL 소스 `src/include/access/htup_details.h`(HeapTupleHeaderData·t_infomask 비트), `src/backend/access/heap/heapam_visibility.c`(HeapTupleSatisfiesMVCC), `src/include/utils/snapshot.h`(SnapshotData)
> **Secondary:** PostgreSQL 18 Documentation §66.6 Database Page Layout, §24.1.5 Preventing Transaction ID Wraparound Failures, §13.1 Introduction(MVCC), F.23 pageinspect
> **Date:** 2026-09-02
> **Status:** draft

## 왜 봤나

- 이전에 [Index-Only Scan과 Visibility Map](./postgresql-index-only-scan-and-visibility-map.md) 노트에서 "index tuple만으로는 visibility를 알 수 없고 xmin/xmax는 heap tuple 쪽에 있다"고만 적고 넘어갔다. xmin/xmax가 정확히 어떤 필드고 스냅샷과 어떻게 비교되는지는 다루지 않았다.
- InnoDB MVCC는 undo log와 Read View로 과거 버전을 재구성하는데, PostgreSQL은 undo log 없이 과거 버전이 heap에 그대로 쌓인다. "MVCC"라는 단어는 같아도 판정 메커니즘 자체가 다르다는 걸 소스 레벨에서 확인하고 싶었다.

## 핵심 한 문장

> PostgreSQL의 튜플 가시성은 heap tuple 헤더의 xmin/xmax(및 t_infomask hint bit)와 스냅샷의 xmin/xmax/xip[] 구간 비교를 조합한 `HeapTupleSatisfiesMVCC` 함수 하나가 결정하며, undo log로 되돌아가는 게 아니라 "이 튜플 버전을 만들거나 지운 트랜잭션이 내 스냅샷 기준으로 이미 끝났는가"를 매번 계산하는 방식이다.

## 내부 동작

### 1. undo log 없이 여러 버전을 유지하는 법

InnoDB는 UPDATE 시 최신 버전만 남기고 이전 버전은 undo log 롤백 포인터 체인으로 밀어낸다. PostgreSQL은 UPDATE를 "새 튜플을 heap에 추가 INSERT + 옛 튜플에 삭제 표시"로 처리해, 신·구 버전이 같은 heap에 나란히 존재한다. 핵심 질문이 "어느 버전으로 되돌아가나"가 아니라 "heap의 이 튜플이 내 스냅샷에 보이는가"로 바뀌고, 그 판정 재료가 xmin/xmax다.

### 2. HeapTupleHeaderData 레이아웃

```c
typedef struct HeapTupleFields
{
    TransactionId t_xmin;   /* inserting xact ID */
    TransactionId t_xmax;   /* deleting or locking xact ID */
    union {
        CommandId     t_cid;  /* inserting or deleting command ID, or both */
        TransactionId t_xvac; /* old-style VACUUM FULL xact ID */
    } t_field3;
} HeapTupleFields;

struct HeapTupleHeaderData
{
    union { HeapTupleFields t_heap; DatumTupleFields t_datum; } t_choice;
    ItemPointerData t_ctid;   /* 이 튜플 또는 갱신된 다음 버전의 TID */
    uint16 t_infomask2;       /* 속성 개수 + 플래그 */
    uint16 t_infomask;        /* 가시성/락 플래그 */
    uint8  t_hoff;            /* 유저데이터 시작 offset */
    uint8  t_bits[FLEXIBLE_ARRAY_MEMBER]; /* NULL 비트맵 */
};
```

xmin/xmax는 항상 저장되지만 cmin/cmax/xvac는 `t_field3` 한 필드를 공유한다 — cmin/cmax는 삽입/삭제 트랜잭션이 살아있는 동안만 의미가 있어서라고 소스 주석은 설명한다. `t_ctid`는 평소 자기 자신을 가리키다 UPDATE가 나면 다음 버전 TID로 바뀐다. 체인을 따라갈 땐 "가리켜진 튜플의 xmin == 이 튜플의 xmax"를 검증해야 한다(VACUUM이 중간 버전을 먼저 지울 수 있어서).

### 3. t_infomask hint bit — 커밋 여부 캐시

xmin/xmax는 트랜잭션 ID일 뿐, 커밋/abort 여부는 `pg_xact`(clog)를 봐야 안다. 매번 clog를 뒤지지 않도록 `t_infomask`에 결과를 캐싱한다.

```
HEAP_XMAX_LOCK_ONLY   0x0080  xmax가 유효해도 "삭제자"가 아니라 "락커"일 뿐
HEAP_XMIN_COMMITTED   0x0100  t_xmin 커밋 확인됨
HEAP_XMIN_INVALID     0x0200  t_xmin invalid/abort
HEAP_XMIN_FROZEN      (COMMITTED|INVALID 동시 set) xmin frozen 처리됨
HEAP_XMAX_COMMITTED   0x0400  t_xmax 커밋 확인됨
HEAP_XMAX_INVALID     0x0800  t_xmax invalid/abort
HEAP_XMAX_IS_MULTI    0x1000  t_xmax가 단일 XID가 아니라 MultiXactId
```

`HEAP_XMIN_FROZEN`이 COMMITTED+INVALID를 동시에 켜는 조합인 게 흥미로운데, "원래 나올 수 없는 조합"을 역이용해 비트를 아낀 인코딩이다.

hint bit는 `TransactionIdDidCommit()`으로 clog를 한 번 확인한 뒤 결과를 다시 써서 다음 방문자가 clog를 안 보게 만드는 캐시다. `SetHintBitsExt`는 커밋 WAL이 flush됐다고 보장되기 전엔(`BufferGetLSNAtomic(buffer) < commitLSN`) committed hint를 세우지 않는다 — 버퍼가 커밋 WAL보다 먼저 디스크에 내려가면 크래시 복구 후 "커밋됐다"는 hint만 남고 실제 커밋 레코드는 없는 모순이 생기기 때문이다(임시/unlogged 테이블은 예외).

### 4. Snapshot 구조체와 구간 판정

```c
TransactionId xmin;   /* 이 값보다 작은 XID는 모두 나에게 보인다 */
TransactionId xmax;   /* 이 값 이상 XID는 모두 나에게 안 보인다 */
TransactionId *xip;   /* xmin<=xip[i]<xmax 구간에서 "아직 진행 중"이던 XID 목록 */
CommandId     curcid; /* 내 트랜잭션 안에서 CID < curcid만 보인다 */
```

스냅샷은 "xmax 미만은 전부 안다"는 전제 위에서, xmin~xmax 구간 XID 중 **스냅샷을 뜬 순간 아직 커밋 안 된 것만** `xip[]`에 나열한다.

```
XID:  ...  xmin ─────────────── xmax  ...
xmin 미만  → 전부 보임(오래 전에 커밋 확정)     구간 내 xip[]에 있음 → 안 보임(진행 중 취급)
xmax 이상  → 전부 안 보임(스냅샷 이후 시작)     구간 내 xip[]에 없음 → 보임(이미 커밋)
```

덕분에 대부분의 튜플은 xmin/xmax 비교만으로 끝나고, `xip[]` 탐색은 "스냅샷을 뜰 때 마침 진행 중이던 트랜잭션"이 만든 튜플에만 필요하다.

### 5. HeapTupleSatisfiesMVCC 판정 흐름

```
HeapTupleSatisfiesMVCC(tuple, snapshot):
    if XMIN_COMMITTED hint 없음:
        if XMIN_INVALID hint 있음:             -> 안 보임 (삽입 트랜잭션 abort/crash)
        elif xmin == 내 트랜잭션:
            if Cmin >= snapshot.curcid: 안 보임 (스캔 시작 후 내가 넣음)  else: xmax 판정으로
        elif XidInMVCCSnapshot(xmin, snapshot): -> 안 보임 (xip[] 매칭, 진행 중 취급)
        elif TransactionIdDidCommit(xmin): hint 세팅 후 xmax 판정으로
        else: XMIN_INVALID hint 세팅            -> 안 보임 (abort/crash)
    else:
        if not XMIN_FROZEN and XidInMVCCSnapshot(xmin, snapshot): -> 안 보임 (커밋은 됐지만 내 스냅샷 이후)
    # 여기까지 왔으면 삽입 트랜잭션은 "내 스냅샷 기준" 커밋 확정. xmax도 동일 구조로 대칭 판정:
    #   XMAX_INVALID/LOCK_ONLY  -> 보임 / 내가 스캔 후 지움 -> 보임 / 삭제자 진행 중 -> 보임
    #   삭제자 커밋 확정        -> 안 보임 / 삭제자 abort   -> 보임
```

핵심 포인트 둘. 첫째, `XMIN_COMMITTED` hint가 있어도 "모든 스냅샷에 보인다"는 뜻이 아니다 — 커밋이 **내 스냅샷 이후**일 수 있어 `XidInMVCCSnapshot`으로 다시 거른다(주석: "maybe not according to our snapshot"). 둘째, in-progress 확인이 항상 `TransactionIdDidCommit`보다 먼저다 — 순서가 바뀌면 "막 커밋됐지만 PGPROC에서 자기 xid를 아직 못 지운" 찰나에 오판할 수 있다고 주석이 못박는다.

### 6. Freezing과 XID wraparound

XID는 32비트라 20억(2^31)개가 지나면 원형으로 돈다. §24.1.5는 "커밋된 지 충분히 오래돼 모든 현재/미래 트랜잭션에 보이는 게 확실한" 행을 VACUUM이 `FrozenTransactionId`(항상 "과거"로 취급되는 특수 XID)로 **freeze** 처리한다고 설명한다. 문서에 따르면 9.4 이전엔 실제로 xmin을 덮어썼지만, 이후는 원래 xmin을 보존한 채 플래그만 세운다 — 그게 앞서 본 `HEAP_XMIN_FROZEN` 조합이다. `HeapTupleHeaderGetXmin()`도 `XminFrozen`이 참이면 raw xmin 대신 `FrozenTransactionId`를 반환하도록 구현돼 있어 문서 설명과 소스가 정확히 맞아떨어진다.

### 7. Visibility Map과의 연결

visibility map의 all-visible 비트는 "이 page의 모든 튜플이 `HeapTupleSatisfiesMVCC` 판정 없이도 확실히 보인다"는 사실을 page 단위로 캐싱한 것이다. Index-only scan이 heap을 건너뛸 수 있는 이유는 visibility map이 그 페이지 전체에 대해 이 판정을 미리 실행해 둔 것과 같은 결과를 보장하기 때문이다.

## 검증

이 repo엔 실행 환경이 없으므로 독자가 직접 재현할 방법 두 가지를 적는다.

```sql
CREATE TABLE mvcc_demo(id int primary key, v text);
INSERT INTO mvcc_demo VALUES (1, 'a');

BEGIN;
SELECT xmin, xmax, ctid, v FROM mvcc_demo WHERE id = 1;  -- xmin=삽입 트랜잭션 XID, xmax=0
UPDATE mvcc_demo SET v = 'b' WHERE id = 1;
SELECT xmin, xmax, ctid, v FROM mvcc_demo WHERE id = 1;  -- 새 튜플: ctid·xmin이 바뀜
COMMIT;
```

`ctid`가 바뀌고 새 튜플 `xmin`이 방금 UPDATE한 트랜잭션 XID가 되는지 보면 "UPDATE는 heap에 새 버전을 추가한다"를 확인할 수 있다.

둘째, hint bit는 공식 contrib 모듈 `pageinspect`로 볼 수 있다. `heap_page_items()`가 `t_infomask`/`t_infomask2`를 반환하고 `heap_tuple_infomask_flags()`가 이를 플래그 이름으로 풀어준다(F.23.2).

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;
SELECT (heap_tuple_infomask_flags(t_infomask, t_infomask2)).*
FROM heap_page_items(get_raw_page('mvcc_demo', 0));
```

INSERT 직후엔 아직 커밋 확인 전이라 `HEAP_XMIN_COMMITTED`가 안 보일 수 있고, 그 행을 다시 SELECT해 `HeapTupleSatisfiesMVCC`가 clog를 확인한 뒤에는 hint bit가 세팅되어 플래그 목록에 나타나는 걸 관찰할 수 있다.

## 잘못 알고 있던 것

- **"PostgreSQL도 undo log로 이전 버전을 복원한다"** → 아니다. undo log는 InnoDB([관련 노트](./innodb-mvcc-undo-log-read-view.md)) 쪽이고, PostgreSQL은 이전 버전을 heap에 남긴 채 xmin/xmax 비교로 가시성을 판정한다. 오래된 버전을 치우는 건 롤백이 아니라 VACUUM이다.
- **"xmin이 커밋된 트랜잭션이면 무조건 보인다"** → 아니다. `XMIN_COMMITTED` hint가 있어도 `XMIN_FROZEN`이 아닌 한 `XidInMVCCSnapshot`으로 재확인한다. 남에게는 이미 커밋된 행이라도 내가 먼저 스냅샷을 떴다면 나에겐 안 보일 수 있다.
- **"커밋 여부는 매번 pg_xact(clog)를 찾아 확인한다"** → 절반만 맞다. 최초 한 번만 clog를 보고, 결과는 `t_infomask` hint bit에 캐싱되어 이후엔 재조회하지 않는다. 다만 이 hint는 커밋 WAL이 버퍼보다 먼저 flush됐다는 보장이 있을 때만 세팅된다.

## 더 파고들 만한 것

- VACUUM이 all-visible/all-frozen 비트를 세우거나 지우는 조건과 관련 WAL 기록.
- `SNAPSHOT_DIRTY`/`HeapTupleSatisfiesDirty`가 UPSERT·유니크 제약 충돌 감지에서 쓰이는 방식.

## 참고

- PostgreSQL 소스: `src/include/access/htup_details.h`, `src/backend/access/heap/heapam_visibility.c`, `src/include/utils/snapshot.h` (postgres/postgres, master 브랜치)
- PostgreSQL 18 Documentation, 66.6. Database Page Layout: https://www.postgresql.org/docs/current/storage-page-layout.html
- PostgreSQL 18 Documentation, 24.1.5. Preventing Transaction ID Wraparound Failures: https://www.postgresql.org/docs/current/routine-vacuuming.html
- PostgreSQL 18 Documentation, 13.1. Introduction (MVCC): https://www.postgresql.org/docs/current/mvcc-intro.html
- PostgreSQL 18 Documentation, F.23. pageinspect: https://www.postgresql.org/docs/current/pageinspect.html

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
