# InnoDB 넥스트키 락: 갭 락으로 팬텀 로우를 막는 잠금 읽기의 내부 동작

> **Primary source:** MySQL 8.0 Reference Manual §15.7.1 (InnoDB Locking) / §15.7.2.3 (Consistent Nonlocking Reads) / §15.7.4 (Phantom Rows)
> **Secondary:** MySQL Reference Manual §15.7.3 (Locks Set by Different SQL Statements in InnoDB)
> **Date:** 2026-07-17
> **Status:** draft

## 왜 봤나

- InnoDB에서 "REPEATABLE READ가 팬텀을 막는다"는 문장을 MVCC(스냅샷 읽기)로만 설명하곤 했는데, `SELECT ... FOR UPDATE`나 `UPDATE ... WHERE range` 같은 **잠금 읽기(locking read)** 는 스냅샷이 아니라 최신 커밋본을 읽으면서 팬텀을 막는다. 그 팬텀 방지를 실제로 담당하는 건 MVCC가 아니라 **넥스트키 락**이다.
- 예전에 "레코드에 락을 걸면 그 행만 잠긴다"고 알고 있었는데, InnoDB는 존재하지 않는 행이 끼어들 **틈(gap)** 까지 잠근다는 걸 놓치고 있었다.

## 핵심 한 문장

> 넥스트키 락 = **인덱스 레코드에 대한 record lock + 그 레코드 바로 앞 gap에 대한 gap lock**의 결합이며, gap lock이 "그 틈으로의 INSERT"를 막기 때문에 잠금 읽기가 보는 범위에 새 행(팬텀)이 나중에 끼어들 수 없다.

## 내부 동작

### 세 가지 락의 층위

공식 매뉴얼(§15.7.1)은 잠금 읽기가 거는 락을 세 종류로 정의한다.

- **Record lock**: 인덱스 레코드 하나에 걸리는 락. 매뉴얼은 "record lock always lock **index records**"라고 명시한다. 테이블에 인덱스가 하나도 없어도 InnoDB가 만든 숨은 클러스터드 인덱스(`GEN_CLUST_INDEX`)의 레코드에 건다. 즉 InnoDB의 행 잠금은 언제나 "인덱스 엔트리 잠금"이다.
- **Gap lock**: "a lock on a **gap between index records**, or a lock on the gap before the first or after the last index record" — 인덱스 레코드 *사이의 틈*, 또는 최소값 앞/최대값 뒤의 틈에 거는 락.
- **Next-key lock**: 위 둘의 결합. "a combination of a record lock on the index record and a gap lock on the gap **before** the index record" — 레코드와 그 **앞쪽** 틈을 함께 잠근다.

### 넥스트키 락이 덮는 구간 (반개구간)

인덱스에 값 `10, 11, 13, 20`이 있을 때, 매뉴얼이 드는 예시대로 넥스트키 락이 커버할 수 있는 구간은 아래와 같다. 왼쪽은 열리고 오른쪽 레코드는 포함되는 **(앞 gap, 레코드]** 형태다.

```
(-∞, 10]
(10, 11]
(11, 13]
(13, 20]
(20, +∞)        ← supremum pseudo-record
```

마지막 구간이 중요하다. 인덱스 페이지에는 `supremum`이라는 **가짜 레코드(pseudo-record)** 가 맨 끝에 있고, 최대값(20) 위쪽 틈을 잠글 때 이 supremum에 넥스트키 락을 건다. 매뉴얼은 "the supremum is not a real index record, so, in effect, this next-key lock locks **only the gap** following the largest index value"라고 설명한다 — supremum은 실재 행이 아니므로 record lock 부분은 사실상 무의미하고, 20 위의 gap만 잠기는 셈이다.

### 왜 이게 팬텀을 막나

팬텀 로우는 "같은 조건의 범위 쿼리를 두 번 돌렸을 때, 다른 트랜잭션이 그 사이 INSERT한 새 행이 두 번째 결과에 나타나는 것"이다(§15.7.4). 잠금 읽기는 최신본을 읽으므로 MVCC 스냅샷의 보호를 못 받는다. 대신:

1. 범위 스캔이 지나간 각 인덱스 레코드에 record lock을 건다 → 기존 행의 수정/삭제 차단.
2. 그 레코드들 **사이의 gap**에도 gap lock을 건다 → 그 틈으로의 INSERT 차단.

결과적으로 "조건을 만족하는 값이 들어올 수 있는 모든 위치"가 잠기므로, 다른 트랜잭션이 그 범위에 새 행을 넣지 못한다. §15.7.2.3의 요약대로 "InnoDB uses next-key locks for searches and index scans, which **prevents phantom rows**."

```sql
-- 세션 A (REPEATABLE READ)
SELECT * FROM t WHERE id BETWEEN 10 AND 20 FOR UPDATE;
-- id=10,11,13,20 레코드락 + (10,11](11,13](13,20] gap + 20 위 (13,20]까지 넥스트키

-- 세션 B
INSERT INTO t(id) VALUES (15);   -- (13,20] gap에 막혀 BLOCK (A 커밋까지 대기)
INSERT INTO t(id) VALUES (25);   -- 잠긴 범위 밖 → 통과
```

### gap lock의 반직관적 성질

매뉴얼이 강조하는 두 가지가 오해를 부른다.

- **"purely inhibitive"**: gap lock의 "only purpose is to prevent other transactions from inserting to the gap" — 즉 gap lock은 오직 **INSERT만** 막는다. 이미 그 틈에 값이 없으니 UPDATE/DELETE 대상 자체가 없다.
- **gap lock끼리는 충돌하지 않는다**: "A gap lock taken by one transaction does not prevent another transaction from taking a gap lock on the same gap." 그래서 S-gap과 X-gap의 구분도 사실상 없다("no difference between shared and exclusive gap locks. They do not conflict... perform the same function"). 두 트랜잭션이 같은 gap을 동시에 gap-lock해도 서로 대기하지 않는다 — 충돌은 오직 "gap을 잠근 쪽 vs 그 gap에 INSERT하려는 쪽"에서만 발생한다.

### Insert Intention Lock

그 INSERT 쪽이 거는 게 **insert intention lock**이다. INSERT 전에 대상 gap에 거는 특수한 gap lock으로, "여러 트랜잭션이 같은 gap의 **서로 다른 위치**에 INSERT하려 할 때는 서로 기다릴 필요가 없다"는 신호다. 하지만 그 gap에 이미 (넥스트키 락 등으로) gap lock이 잡혀 있으면 insert intention lock은 대기한다 — 위 세션 B의 `INSERT 15`가 막히는 정확한 지점이 이것이다.

### 상태표: 격리 수준별 gap locking

| 격리 수준 | 잠금 읽기의 gap locking | 팬텀 방지(잠금 읽기) |
| --- | --- | --- |
| READ COMMITTED | **비활성** — "Gap locking is disabled for searches and index scans and is used only for foreign-key / duplicate-key checking" | 안 됨 |
| REPEATABLE READ (기본) | 활성 — 넥스트키 락 사용 | 됨 |

READ COMMITTED에서는 gap이 사라지고 매칭된 레코드에만 record lock이 남으며, 매칭 안 된 레코드의 락은 스캔 후 **바로 해제(semi-consistent read)** 된다. 그래서 동시성은 오르지만 팬텀은 열린다.

## 검증

MySQL 8.0 Reference Manual §15.7.1의 정의문(record/gap/next-key/insert intention)과 §15.7.4의 팬텀 예시, 그리고 §15.7.2.3의 "next-key locks ... prevents phantom rows" 문장을 직접 따라가며 인용으로 확인했다. 위 `BETWEEN 10 AND 20 FOR UPDATE` 시나리오는 매뉴얼의 gap/next-key 정의에서 논리적으로 도출한 것으로, `performance_schema.data_locks`(8.0) 테이블을 조회하면 `LOCK_TYPE=RECORD`, `LOCK_MODE=X` / `X,GAP` / `X,REC_NOT_GAP` 형태로 각 락의 실체를 확인할 수 있다(이 repo엔 실행 환경이 없어 스니펫 흐름으로 대체).

```sql
-- 세션 A가 FOR UPDATE 후, 다른 세션에서:
SELECT INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_DATA
FROM performance_schema.data_locks WHERE OBJECT_NAME='t';
-- 기대: X,GAP / X,REC_NOT_GAP / X (next-key) 조합이 관측됨
```

## 잘못 알고 있던 것

- **"REPEATABLE READ의 팬텀 방지는 MVCC가 다 한다"** → 아니다. 순수 스냅샷 읽기(`SELECT`)는 MVCC가 막지만, **잠금 읽기**(`FOR UPDATE`/`FOR SHARE`/`UPDATE`/`DELETE`)는 최신본을 읽으므로 MVCC 보호 밖이고, 여기서 팬텀을 막는 건 **넥스트키 락(gap lock)** 이다. 두 메커니즘은 별개 축이다.
- **"레코드 락은 딱 그 행만 잠근다"** → 범위/비유니크 조건의 잠금 읽기는 지나간 레코드의 **앞쪽 gap까지** 넥스트키로 잠근다. 존재하지도 않는 값의 자리를 잠그는 것이라 처음엔 반직관적이다.
- **"gap lock끼리 부딪혀 데드락이 잦다"** → gap lock은 서로 충돌하지 않는다. 충돌은 gap-lock 보유 vs 그 gap으로의 insert intention 사이에서만 난다. (다만 서로 다른 두 트랜잭션이 상대의 gap에 INSERT하려 대기하며 데드락이 나는 패턴은 존재한다.)

## 더 파고들 만한 것

- InnoDB 데드락 감지(wait-for graph)와 `innodb_deadlock_detect`, 그리고 gap lock이 얽힌 대표적 데드락 시나리오.
- 유니크 인덱스 동등 조건(`WHERE uk = ?`)에서 넥스트키 락이 record lock으로 **축약(degenerate)** 되는 최적화 조건.

## 참고

- MySQL 8.0 Reference Manual §15.7.1 InnoDB Locking
- MySQL 8.0 Reference Manual §15.7.2.3 Consistent Nonlocking Reads / §15.7.4 Phantom Rows
- MySQL 8.0 Reference Manual §15.7.3 Locks Set by Different SQL Statements in InnoDB
