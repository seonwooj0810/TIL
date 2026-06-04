# REPEATABLE READ in InnoDB의 실제 동작

> **Primary source:** MySQL 8.0 Reference Manual §15.7.2.1 (Transaction Isolation Levels), §15.7.2.3 (Consistent Nonlocking Reads), §15.7.1 (InnoDB Locking)
> **Secondary:** InnoDB 소스 `storage/innobase/include/read0types.h` (`ReadView`), Database Internals (Petrov) Ch.5
> **Date:** 2026-06-04
> **Status:** draft

## 왜 봤나

- "InnoDB는 RR이 기본인데 왜 팬텀이 거의 안 보이지?"가 출발점. SQL 표준 RR은 팬텀을 허용하는데 InnoDB는 그렇지 않다.
- 같은 트랜잭션 안에서 일반 `SELECT`와 `SELECT ... FOR UPDATE`가 **다른 결과**를 보는 현상을 한 번 겪고 나서 정확히 이해하고 싶었다.

## 핵심 한 문장

> InnoDB의 RR은 트랜잭션의 **첫 일관성 읽기 시점에 고정된 Read View**로 스냅숏 읽기를 처리하고, 잠금 읽기·DML은 **next-key lock**으로 갭을 막아, MVCC와 락 두 메커니즘으로 팬텀까지 방어한다.

## 내부 동작

### 1. 두 종류의 읽기

InnoDB의 읽기는 성격이 완전히 다른 두 가지다.

| 구분 | 대상 | 보는 버전 | 락 |
| --- | --- | --- | --- |
| 일관성 비잠금 읽기 (snapshot read) | 평범한 `SELECT` | Read View 기준 과거 스냅숏 | 없음 |
| 잠금 읽기 (current read) | `SELECT ... FOR UPDATE/SHARE`, `UPDATE`, `DELETE`, `INSERT` | **최신 커밋 버전** | next-key lock |

RR의 까다로움은 한 트랜잭션이 이 둘을 섞어 쓸 때 생긴다. 스냅숏 읽기는 과거를 보고, 잠금 읽기는 현재를 본다.

### 2. Read View의 생성 시점 — RR vs RC

공식 문서(§15.7.2.3)에 따르면:

- **REPEATABLE READ**: 트랜잭션 안의 모든 일관성 읽기는 **그 트랜잭션의 첫 읽기가 만든 스냅숏**을 공유한다. → 트랜잭션 내내 같은 화면.
- **READ COMMITTED**: 일관성 읽기마다 **매번 새 스냅숏**을 뜬다. → 다른 트랜잭션 커밋이 중간에 보인다(non-repeatable read).

즉 RR에서 스냅숏을 결정하는 건 `BEGIN`이 아니라 **첫 일관성 읽기**다. `START TRANSACTION WITH CONSISTENT SNAPSHOT`을 쓰면 시작 즉시 Read View를 만든다(RR에서만 의미 있음).

### 3. Read View 자료구조와 가시성 판정

각 행에는 숨은 컬럼 `DB_TRX_ID`(이 버전을 마지막으로 쓴 트랜잭션 id)와 `DB_ROLL_PTR`(undo 로그의 이전 버전 포인터)가 붙는다. Read View는 생성 순간의 트랜잭션 상태를 박제한다(`ReadView` 멤버):

```
m_up_limit_id   : 활성 트랜잭션 중 가장 작은 id  (이 미만은 전부 보임)
m_low_limit_id  : (당시 최대 trx id) + 1         (이 이상은 전부 안 보임)
m_ids           : Read View 생성 시점에 "활성(미커밋)"이던 trx id 집합
m_creator_trx_id: 이 View를 만든 트랜잭션 자신의 id
```

행 버전의 `DB_TRX_ID = trx`에 대한 가시성 판정:

```
if trx == m_creator_trx_id      -> 보임   (내가 쓴 변경)
elif trx <  m_up_limit_id       -> 보임   (View 생성 전에 커밋됨)
elif trx >= m_low_limit_id      -> 안 보임 (View 생성 후 시작됨)
else  # up_limit <= trx < low_limit
    if trx in m_ids             -> 안 보임 (생성 시점에 미커밋)
    else                        -> 보임   (생성 시점에 이미 커밋)
```

"안 보임"이면 `DB_ROLL_PTR`을 따라 undo 로그의 **더 과거 버전**으로 내려가 다시 판정한다. 이 체인을 끝까지 따라가며 처음으로 "보임"이 되는 버전을 반환한다. 읽는 쪽은 락을 전혀 걸지 않고 과거 버전을 재구성만 하므로, 쓰기와 읽기가 서로를 막지 않는다(MVCC의 본질). 대신 어떤 Read View도 더는 참조하지 않는 과거 버전은 **purge 스레드**가 undo 로그에서 정리한다. 그래서 오래 열린 RR 트랜잭션은 undo 로그 비대(history list length 증가)를 유발할 수 있다.

```
  현재 행 ──DB_ROLL_PTR──> undo v3 ──> undo v2 ──> undo v1
   trx=50                   trx=42       trx=30      trx=12
     │ 내 View가 trx=50을 못 보면 한 칸씩 내려가
     └─> 보이는 첫 버전(예: trx=30)을 결과로
```

이름이 헷갈리는데 `up_limit`이 작은 쪽 경계, `low_limit`이 큰 쪽 경계다(값이 아니라 "확정 가시 영역의 위/아래 한계"를 가리킴).

### 4. 잠금 읽기와 팬텀 방어

표준 RR은 팬텀(같은 조건 재조회 시 새 행 출현)을 허용한다. InnoDB는 두 경로로 막는다.

- **스냅숏 읽기**: 고정 Read View라 나중에 커밋된 행의 `DB_TRX_ID`가 `m_low_limit_id` 이상 → 애초에 안 보임. 팬텀 발생 불가.
- **잠금 읽기**: `SELECT ... FOR UPDATE` 같은 current read는 **next-key lock**을 건다.

next-key lock = **레코드 락(인덱스 레코드) + 갭 락(레코드 앞 간격)**. 조건에 매칭되는 인덱스 구간 전체와 그 사이 갭을 잠가, 다른 트랜잭션이 그 갭에 `INSERT`하는 것을 막는다 → 팬텀 행이 생길 자리를 봉쇄한다. 갭 락은 RR/SERIALIZABLE에서만 활성화되고, RC에서는 (FK·중복키 검사 등 예외 빼고) 대부분 꺼진다. 이것이 RC가 갭 락 경합이 적은 이유다.

### 5. RR이 직렬화는 아니다

문서가 명시하는 한계(§15.7.2.3): 스냅숏은 `SELECT`에만 적용되고 DML에는 꼭 그렇지 않다. 다른 트랜잭션이 막 커밋한 행을 내 스냅숏 `SELECT`는 못 보지만, 내 `UPDATE`/`DELETE`는 그 **최신 커밋 행에 영향을 줄 수 있다**. 업데이트 후 다시 `SELECT`하면 직전엔 안 보이던 행이 보이기도 한다. 진짜 직렬화가 필요하면 `SERIALIZABLE`(평범한 `SELECT`도 `FOR SHARE`로 승격) 또는 명시적 잠금 읽기를 써야 한다. 이 때문에 RR에서도 **lost update**(두 트랜잭션이 같은 행을 읽고 각자 갱신)나 **write skew**(서로의 조건을 침범하는 갱신)는 막지 못한다. 카운터 증감·재고 차감 같은 read-modify-write는 스냅숏 `SELECT` 후 `UPDATE` 대신 `SELECT ... FOR UPDATE`로 행을 먼저 잠그거나, `UPDATE t SET n = n - 1 WHERE id = ? AND n > 0`처럼 한 문장(current read)으로 처리해야 안전하다.

## 검증

두 세션을 띄워 스냅숏 고정과 잠금 읽기 차이를 따라가 본다.

```sql
-- 세션 A (RR, 기본)
START TRANSACTION;
SELECT val FROM t WHERE id = 1;   -- (1) 첫 읽기 → 여기서 Read View 고정. 결과: 'old'

-- 세션 B
UPDATE t SET val = 'new' WHERE id = 1;
COMMIT;                            -- trx id가 A의 m_low_limit_id 이상

-- 세션 A (계속)
SELECT val FROM t WHERE id = 1;            -- (2) 스냅숏 읽기 → 여전히 'old'
SELECT val FROM t WHERE id = 1 FOR UPDATE; -- (3) 잠금 읽기 → 'new' (current read!)
```

(2)와 (3)이 같은 트랜잭션·같은 행인데 결과가 다른 게 핵심. (2)는 고정 Read View로 undo 체인을 따라 과거 버전을, (3)은 최신 커밋 버전을 읽고 락을 건다. 팬텀 방어도 같은 세션에서 확인 가능하다.

```sql
-- 세션 A: 범위에 갭 락
START TRANSACTION;
SELECT * FROM t WHERE id BETWEEN 10 AND 20 FOR UPDATE;
-- 세션 B: 갭에 INSERT 시도 → 블록(대기). RC였다면 통과되어 팬텀.
INSERT INTO t(id, val) VALUES (15, 'x');
```

## 잘못 알고 있던 것

- **"RR이면 스냅숏은 `BEGIN` 시점에 고정된다"** → 아니다. **첫 일관성 읽기 시점**에 Read View가 만들어진다. `BEGIN` 직후 한참 idle하다 첫 `SELECT`를 하면 그 사이 커밋들은 안 보인다.
- **"표준 RR처럼 InnoDB RR도 팬텀이 난다"** → InnoDB는 스냅숏 + next-key lock으로 팬텀까지 막아 표준보다 강하다.
- **"같은 트랜잭션이면 어떤 읽기든 같은 데이터를 본다"** → 스냅숏 읽기와 잠금 읽기는 보는 버전 자체가 다르다.

## 더 파고들 만한 것

- next-key lock의 정확한 경계와 secondary index에서의 갭 락 동작 (락 충돌 매트릭스).
- RC의 **half-consistent read**: `UPDATE` 시 매칭 안 되는 행은 락을 즉시 푸는 최적화.

## 참고

- MySQL 8.0 Reference Manual §15.7.2.1, §15.7.2.3, §15.7.1
- 관련 노트: `database/innodb-mvcc-undo-log-read-view.md` (Read View·undo 로그 상세), `database/innodb-index-structure.md`
