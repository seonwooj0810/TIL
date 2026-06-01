# InnoDB MVCC: undo log와 Read View

> **Primary source:** MySQL 8.0 Reference Manual §15.3 (InnoDB Multi-Versioning), §15.6.6 (Undo Logs)
> **Secondary:** §15.7 (Locking and Transaction Model), MySQL `read0read.h` / `ReadView` 소스
> **Date:** 2026-06-01
> **Status:** draft

## 왜 봤나

- "REPEATABLE READ인데 왜 팬텀이 (대부분) 안 생기지?", "락 없이 어떻게 일관된 읽기가 되지?"를 한 번에 설명하려면 MVCC 내부를 봐야 했다.
- 막연히 "스냅샷을 통째로 복사해 둔다"고 알고 있었는데, 실제로는 **undo log를 거꾸로 따라가며 버전을 재구성**한다는 게 핵심이라 정리한다.

## 핵심 한 문장

> InnoDB MVCC는 행마다 숨은 트랜잭션 ID와 롤백 포인터를 두고, 읽을 때 **Read View**가 정한 가시성 규칙에 따라 **undo log 버전 체인**을 거꾸로 따라가 그 트랜잭션이 "봐도 되는" 버전을 재구성하는 방식이다.

## 내부 동작

### 1. 행에 숨겨진 시스템 컬럼

InnoDB의 모든 클러스터형 인덱스 레코드에는 사용자가 정의하지 않은 숨은 컬럼이 붙는다 (공식 문서 §15.3 기준).

| 컬럼 | 크기 | 역할 |
| --- | --- | --- |
| `DB_TRX_ID` | 6 byte | 이 행을 마지막으로 **insert/update**한 트랜잭션 ID |
| `DB_ROLL_PTR` | 7 byte | 직전 버전을 담은 **undo log 레코드를 가리키는 롤백 포인터** |
| `DB_ROW_ID` | 6 byte | PK가 없을 때만 자동 생성되는 행 ID (단조 증가) |

`DB_ROLL_PTR`이 버전 체인의 연결 고리다. 현재 행 → undo log의 이전 버전 → 그 이전 버전 … 으로 단방향 링크드 리스트가 만들어진다.

### 2. undo log: insert undo vs update undo

undo log는 두 종류로 나뉜다 (§15.6.6).

- **insert undo log**: INSERT로 생긴 레코드용. 해당 트랜잭션만 볼 수 있고, **커밋 즉시 폐기 가능**하다 (다른 트랜잭션은 애초에 그 행을 본 적이 없으므로).
- **update undo log**: UPDATE/DELETE용. 이전 버전을 복원하는 데 쓰이며, MVCC 읽기가 참조하므로 **그 버전을 필요로 하는 Read View가 모두 사라질 때까지 보관**된다.

DELETE는 실제로 행을 즉시 지우지 않는다. 레코드에 **delete-mark 비트**만 세우고, 물리 삭제는 나중에 purge가 처리한다. 그래야 그 행을 아직 봐야 하는 오래된 트랜잭션이 버전 체인을 따라갈 수 있다.

```
[현재 레코드]  DB_TRX_ID=50  DB_ROLL_PTR ──┐
                                          ▼
                          [update undo]  v(trx=42)  roll_ptr ──┐
                                                               ▼
                                              [update undo]  v(trx=30)  roll_ptr → NULL
   버전 체인: 최신(50) → 42 → 30 → (체인 끝)
```

### 3. Read View: 가시성 판정의 핵심 자료구조

일관된 읽기(consistent read)를 시작할 때 InnoDB는 `ReadView` 객체를 만든다. 소스(`read0types.h`)상 핵심 필드는 다음과 같이 알려져 있다.

| 필드 | 의미 |
| --- | --- |
| `m_low_limit_id` | **이 값 이상**의 trx_id는 무조건 안 보임 (Read View 생성 시점의 next trx id) |
| `m_up_limit_id` | **이 값 미만**의 trx_id는 무조건 보임 (활성 트랜잭션 중 최소 ID) |
| `m_ids` | Read View 생성 시점에 **활성(미커밋) 상태였던** 트랜잭션 ID 정렬 목록 |
| `m_creator_trx_id` | 이 Read View를 만든 트랜잭션 자신의 ID |

### 4. 가시성 판정 알고리즘

레코드의 `DB_TRX_ID`를 `trx_id`라 할 때, 한 버전이 보이는지는 다음 순서로 판정된다 (`changes_visible` 로직).

```
visible(trx_id):
  1. if trx_id == m_creator_trx_id:  return true     # 내가 바꾼 건 보인다
  2. if trx_id <  m_up_limit_id:     return true     # Read View 전에 커밋된 과거 버전
  3. if trx_id >= m_low_limit_id:    return false    # Read View 후에 시작된 미래 트랜잭션
  4. if trx_id in m_ids:             return false     # 생성 시점에 아직 미커밋이었음
     else:                          return true      # 그 사이 커밋 완료
```

판정이 `false`면 `DB_ROLL_PTR`을 따라 **이전 버전으로 내려가 다시 1번부터 판정**한다. `true`인 버전을 만날 때까지 체인을 거슬러 올라간다. 즉 "스냅샷"은 미리 복사된 데이터가 아니라, **읽는 순간 undo log로 재구성되는 논리적 뷰**다.

### 5. 격리 수준에 따른 Read View 생성 시점 — 상태 전이

같은 MVCC 엔진이지만, Read View를 **언제 만드느냐**가 격리 수준을 가른다.

```
READ COMMITTED:
   statement 1 ── 새 Read View ──▶ 읽기
   statement 2 ── 새 Read View ──▶ 읽기   (매 SELECT마다 갱신 → non-repeatable read 발생)

REPEATABLE READ:
   첫 consistent read ── Read View 생성 ─┐
   이후 모든 SELECT ───────────────────┴▶ 같은 Read View 재사용 (트랜잭션 동안 고정)
```

REPEATABLE READ는 트랜잭션의 첫 일관된 읽기에서 Read View를 한 번 만들고 끝까지 재사용하므로 같은 쿼리는 항상 같은 결과를 본다. READ COMMITTED는 매 statement마다 새로 만들어 "그 시점까지 커밋된" 것을 본다.

### 6. purge: 버전 쓰레기 수거

더 이상 어떤 Read View도 참조하지 않는 update undo log와 delete-mark된 레코드는 백그라운드 **purge 스레드**가 물리적으로 제거한다. 가장 오래된 활성 Read View가 오래 살아 있으면(긴 트랜잭션) purge가 진행되지 못해 undo log가 쌓이는 **history list length** 증가 문제가 생긴다.

## 검증

소스/문서 흐름을 직접 따라가 확인한 부분:

- `SHOW ENGINE INNODB STATUS`의 `TRANSACTIONS` 섹션에 `History list length`가 노출된다. 긴 트랜잭션을 열어 두고 다른 세션에서 UPDATE를 반복하면 이 값이 증가하고, 트랜잭션을 커밋/롤백하면 purge가 따라잡으며 줄어든다.
- READ COMMITTED vs REPEATABLE READ 차이는 두 세션으로 재현 가능하다.

```sql
-- 세션 A
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT v FROM t WHERE id = 1;   -- 여기서 Read View 고정, 결과 = 'old'

-- 세션 B
UPDATE t SET v = 'new' WHERE id = 1;
COMMIT;

-- 세션 A (같은 트랜잭션 내)
SELECT v FROM t WHERE id = 1;   -- 여전히 'old' (Read View 재사용)
                                -- READ COMMITTED였다면 'new'
```

## 잘못 알고 있던 것

- **"스냅샷 = 데이터 전체 복사본"** → 틀렸다. 복사본은 없다. 행의 `DB_ROLL_PTR`로 연결된 undo log 체인을 읽는 시점에 거꾸로 따라가 **필요한 버전만 그때그때 재구성**한다. 비용은 "오래된 행을 읽을수록 체인을 더 길게 따라가는" 형태로 나타난다.
- **"REPEATABLE READ는 매 쿼리 스냅샷을 다시 찍는다"** → 그건 READ COMMITTED 쪽이다. REPEATABLE READ는 첫 일관된 읽기에서 만든 Read View를 트랜잭션 끝까지 고정한다.
- **"DELETE하면 행이 바로 사라진다"** → 아니다. delete-mark만 세우고 물리 삭제는 purge가 한다. 그래서 오래된 트랜잭션이 삭제된 행의 과거 버전을 여전히 읽을 수 있다.

## 더 파고들 만한 것

- InnoDB의 REPEATABLE READ에서 팬텀이 막히는 실제 메커니즘 — consistent read(MVCC)와 잠금 읽기(next-key lock)의 역할 분담.
- gap lock / next-key lock의 키 범위 잠금 동작과 데드락 패턴.

## 참고

- MySQL 8.0 Reference Manual §15.3 InnoDB Multi-Versioning
- MySQL 8.0 Reference Manual §15.6.6 Undo Logs, §15.7 Locking and Transaction Model
- InnoDB 소스: `storage/innobase/include/read0types.h` (`ReadView`)
