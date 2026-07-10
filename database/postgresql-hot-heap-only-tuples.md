# PostgreSQL HOT 업데이트: 인덱스를 건드리지 않고 같은 페이지 안에서 버전을 잇는 법

> **Primary source:** PostgreSQL 소스 `src/backend/access/heap/README.HOT` / PostgreSQL 16 Docs §73.7 "Heap-Only Tuples (HOT)"
> **Secondary:** PostgreSQL Docs §66.4 (fillfactor), `heapam.c`/`pruneheap.c` 소스
> **Date:** 2026-07-10
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/postgresql-hot-heap-only-tuples

## 왜 봤나

- PostgreSQL은 MVCC 특성상 UPDATE가 "새 row 버전을 추가"하는 append 방식이다. 그러면 인덱싱된 컬럼을 안 바꿔도 매 UPDATE마다 모든 인덱스에 새 엔트리가 생겨야 할 텐데, 실제로는 안 그렇다는 얘기를 듣고 그 메커니즘(HOT)이 궁금했다.
- 막연히 "PostgreSQL UPDATE = DELETE + INSERT라 인덱스도 다 새로 쓴다"고 알고 있었다. 반은 맞고 반은 틀렸다.

## 핵심 한 문장

> HOT은 **인덱싱된 컬럼이 하나도 안 바뀐 UPDATE**에 한해, 새 튜플을 **같은 힙 페이지 안**에 만들고 인덱스는 그대로 둔 채 힙 내부 `t_ctid` 체인으로만 옛→새 버전을 연결하는 최적화다 — 그래서 인덱스 write와 인덱스 bloat를 통째로 없앤다.

## 내부 동작

### 배경: 왜 인덱스가 문제인가

PostgreSQL의 인덱스 엔트리는 항상 **힙 튜플의 물리 위치(TID = 페이지번호, 라인포인터)** 를 가리킨다. MVCC에서 UPDATE는 기존 튜플을 지우지 않고 새 물리 위치에 새 버전을 쓴다. 인덱스 엔트리는 TID를 담으므로, 새 버전이 새 위치에 생기면 원칙적으로 **모든 인덱스**에 "새 TID를 가리키는 새 엔트리"가 추가돼야 한다. 인덱스가 5개면 컬럼 값이 안 바뀌어도 UPDATE 한 번에 인덱스 write가 5번. 이게 HOT 이전의 세계였다.

### HOT의 두 조건

README.HOT이 정의하는 HOT UPDATE 성립 조건:

1. **인덱싱된 컬럼이 하나도 안 바뀐다** (정확히는 인덱스가 참조하는 표현식의 결과가 동일). 인덱스 안 걸린 컬럼만 바뀌면 OK.
2. **새 튜플이 같은 페이지에 들어갈 자리가 있다**. 자리가 없으면 다른 페이지로 가야 하고, 그 순간 인덱스가 가리켜야 할 위치가 페이지를 넘어가므로 HOT 불가.

두 조건을 만족하면:
- 새 튜플은 힙 페이지 안에 쓰이지만 **어떤 인덱스 엔트리도 이 새 튜플을 직접 가리키지 않는다** → 이 튜플이 "heap-only tuple". 자기를 가리키는 인덱스가 없어서 붙은 이름이다.
- 기존(구) 튜플의 `t_ctid` 필드가 새 튜플의 라인포인터를 가리키도록 갱신 → **HOT 체인**이 만들어진다.
- 구 튜플 헤더에 `HEAP_HOT_UPDATED`, 새 튜플 헤더에 `HEAP_ONLY_TUPLE` 플래그가 켜진다.

### 인덱스 스캔이 새 버전을 찾아가는 법

인덱스는 여전히 **체인의 첫(루트) 튜플의 TID**만 안다. 인덱스로 그 TID에 도달한 뒤, 실행기는 그 힙 페이지 안에서 `t_ctid`를 따라 체인을 타고 내려가며 각 버전의 가시성(스냅샷 대비)을 판정한다. 체인은 **한 페이지 안에서만** 존재하므로 이 추적은 추가 페이지 I/O 없이 페이지 내부 포인터 점프로 끝난다. 이게 "인덱스는 안 건드렸는데도 최신 버전을 찾는다"의 정체다.

```
[Index] --TID--> (1)  ← 라인포인터 1 (인덱스가 가리키는 유일한 지점)
힙 페이지:
  LP1 → tuple v1 [HEAP_HOT_UPDATED] t_ctid=LP2
  LP2 → tuple v2 [HEAP_ONLY_TUPLE, HEAP_HOT_UPDATED] t_ctid=LP3
  LP3 → tuple v3 [HEAP_ONLY_TUPLE] t_ctid=self  ← 현재 최신
```

### HOT pruning: 죽은 버전을 VACUUM 없이 걷어내기

체인이 길어지면 스캔 비용이 늘고 페이지가 찬다. PostgreSQL은 **일반 페이지 접근 중에도** (SELECT/UPDATE가 그 페이지를 읽을 때) 기회적으로 `heap_page_prune`을 돌린다:

- 체인 앞쪽의, 모든 트랜잭션에게 더 이상 안 보이는(dead) 튜플들의 저장 공간을 회수한다.
- 이때 인덱스가 가리키던 라인포인터(LP1)를 지우면 인덱스가 깨지므로, LP1을 **redirect 라인포인터**로 바꿔 체인의 살아있는 첫 튜플을 가리키게 한다 (`LP_REDIRECT`). 인덱스는 여전히 LP1을 가리키고, LP1은 이제 "여기 말고 저기"라고 재지향한다.
- 완전히 dead여서 아무도 안 가리키는 라인포인터는 `LP_DEAD`로 표시해 재사용 가능하게 둔다.

핵심: **HOT pruning은 인덱스를 만지지 않는다.** heap-only 튜플들은 애초에 인덱스가 안 가리키므로, 힙 안에서 조용히 정리할 수 있다. 이것이 일반 VACUUM(인덱스까지 청소)과 다른, HOT이 주는 저비용 정리다.

정리하면 라인포인터(ItemId)는 세 상태를 오간다:

| 상태 | 의미 | 인덱스가 가리켜도 되나 |
| --- | --- | --- |
| `LP_NORMAL` | 실제 튜플을 가리키는 정상 포인터 | 예 |
| `LP_REDIRECT` | "여기 말고 저 라인포인터로" 재지향 (pruning이 체인 루트를 살릴 때) | 예 (재지향을 따라감) |
| `LP_DEAD` | 튜플은 회수됐고 포인터만 남음 (재사용 대기) | 아니오 |

한 가지 미묘한 점: HOT 체인은 **커밋된 버전만이 아니라 진행 중/롤백된 버전도 잠시 담는다.** UPDATE가 abort되면 그 새 튜플은 곧 dead가 되어 다음 pruning 때 회수된다. 인덱스는 처음부터 이 실패한 버전을 안 가리켰으므로 롤백해도 인덱스 정합성 문제가 없다 — HOT이 없다면 abort된 인덱스 엔트리까지 나중에 청소해야 했을 것이다.

### fillfactor — HOT이 계속 성립하게 하는 여백

두 번째 조건("같은 페이지에 자리")을 자주 만족시키려면 페이지에 빈 공간이 있어야 한다. `fillfactor`(기본 100)를 90 등으로 낮추면 INSERT 시 페이지의 10%를 비워두고, 이후 UPDATE의 새 버전이 그 여백에 들어가 HOT을 유지할 확률이 올라간다. 자주 UPDATE되는 테이블에서 fillfactor를 낮추는 튜닝이 여기서 나온다.

## 검증

플래그·체인 동작을 `pageinspect` 확장으로 따라가 확인한 흐름:

```sql
CREATE EXTENSION pageinspect;
CREATE TABLE t (id int PRIMARY KEY, val text, memo text) WITH (fillfactor = 90);
CREATE INDEX ON t (val);           -- val은 인덱싱됨
INSERT INTO t VALUES (1, 'a', 'x');

-- (A) 인덱스 안 걸린 memo만 UPDATE → HOT 기대
UPDATE t SET memo = 'y' WHERE id = 1;

-- (B) 인덱싱된 val을 UPDATE → HOT 불가, 새 인덱스 엔트리 발생 기대
UPDATE t SET val = 'b' WHERE id = 1;

-- 힙 튜플 플래그 확인 (t_infomask2의 HEAP_HOT_UPDATED / HEAP_ONLY_TUPLE 비트)
SELECT lp, t_ctid, t_infomask2
FROM heap_page_items(get_raw_page('t', 0));
```

- (A) 후: 새 튜플에 `HEAP_ONLY_TUPLE`, 구 튜플에 `HEAP_HOT_UPDATED`가 켜지고 `t_ctid`가 다음 라인포인터를 가리킨다.
- (B) 후: 새 튜플에는 heap-only 플래그가 없고, `val` 인덱스에 새 엔트리가 추가된다.
- 통계로도 확인 가능: `SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='t';` — (A)는 `n_tup_hot_upd`를 증가시키지만 (B)는 `n_tup_upd`만 올린다. (컬럼명은 버전에 따라 `n_tup_newpage_upd` 등이 추가됐다고 공식 문서에 나온다.)

## 잘못 알고 있던 것

- **"PostgreSQL UPDATE는 항상 DELETE+INSERT라 인덱스도 매번 새로 쓴다"** → 인덱싱된 컬럼이 안 바뀌고 페이지에 자리가 있으면 HOT이 인덱스 write를 통째로 생략한다. "항상"이 틀렸다.
- **"HOT이면 새 row 버전이 아예 안 생긴다"** → 아니다. 새 버전은 여전히 힙에 만들어진다. 단지 **인덱스 엔트리**를 안 만들고, 정리를 VACUUM 없이 힙 내부에서 할 수 있을 뿐이다. MVCC의 append 성질 자체는 그대로다.
- **"인덱스가 최신 튜플을 직접 가리킨다"** → 인덱스는 HOT 체인의 루트(또는 redirect 라인포인터)만 가리킨다. 최신 버전은 힙 안에서 `t_ctid`를 따라가 찾는다.

## 더 파고들 만한 것

- redirect/dead 라인포인터가 쌓일 때의 인덱스 bloat와 `VACUUM`의 `LP_DEAD` 회수 상호작용.
- HOT과 index-only scan·visibility map의 관계 (이미 정리한 [postgresql-index-only-scan-and-visibility-map] 노트와 연결).
- `n_tup_hot_upd` vs `n_tup_newpage_upd` 통계로 HOT 실패율을 진단하고 fillfactor를 조정하는 실전 튜닝.

## 참고

- PostgreSQL 소스 `src/backend/access/heap/README.HOT`
- PostgreSQL 16 Documentation §73.7 Heap-Only Tuples (HOT)
- PostgreSQL Documentation — Storage Parameters (fillfactor), `pageinspect`, `pg_stat_user_tables`
