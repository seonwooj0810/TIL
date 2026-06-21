# PostgreSQL Index-Only Scan과 Visibility Map의 상호작용

> **Primary source:** PostgreSQL 18 Documentation §11.9 Index-Only Scans and Covering Indexes, §66.4 Visibility Map
> **Secondary:** PostgreSQL Documentation §14.1 Using EXPLAIN
> **Date:** 2026-06-21
> **Status:** draft

## 왜 봤나

- "Index Only Scan이면 테이블을 전혀 안 읽는다"는 말을 자주 보지만, PostgreSQL에서는 MVCC 가시성 확인 때문에 조건이 하나 더 붙는다.
- 같은 covering index가 있어도 어떤 실행 계획은 `Heap Fetches: 0`이고, 어떤 실행 계획은 heap을 계속 읽는 이유를 visibility map 기준으로 설명하고 싶었다.

## 핵심 한 문장

> PostgreSQL의 Index-Only Scan은 필요한 컬럼이 모두 인덱스에 있어야 할 뿐 아니라, 인덱스 엔트리가 가리키는 heap page가 visibility map에서 all-visible로 표시되어야 heap 접근을 건너뛸 수 있다.

## 내부 동작

### 1. 왜 PostgreSQL은 인덱스만 보고 끝낼 수 없나

일반적인 B-tree 인덱스는 검색 키와 heap tuple 위치를 가리키는 TID를 담는다. covering index라면 `INCLUDE` 컬럼까지 인덱스에 들어가므로, 쿼리가 요구하는 값 자체는 인덱스에서 얻을 수 있다.

문제는 MVCC 가시성이다. PostgreSQL 문서에 따르면 index tuple만으로는 그 row version이 현재 snapshot에 보이는지 알 수 없다. xmin/xmax 같은 tuple header 정보는 heap tuple 쪽에 있다. 따라서 executor는 인덱스에서 값을 찾은 뒤에도 heap을 방문해 visibility를 확인해야 한다.

Index-Only Scan은 이 비용을 줄이기 위해 page 단위의 요약 정보를 사용한다. 그 요약 자료구조가 visibility map이다.

### 2. Visibility Map의 자료구조

PostgreSQL 공식 문서 §66.4에 따르면 각 heap relation은 별도 relation fork로 visibility map을 가진다. 파일 이름은 filenode 뒤에 `_vm` suffix가 붙는 형태로 알려져 있다. VM은 heap page마다 두 비트를 저장한다.

| 비트 | 의미 | Index-Only Scan과의 관계 |
| --- | --- | --- |
| all-visible | 해당 heap page의 모든 tuple이 모든 활성 트랜잭션에 보이는 것으로 알려짐 | set이면 heap visibility check를 생략할 수 있음 |
| all-frozen | 해당 heap page의 모든 tuple이 frozen 상태 | anti-wraparound vacuum이 다시 방문하지 않아도 됨 |

Index-Only Scan에 직접 쓰이는 것은 all-visible bit다. 중요한 점은 tuple 단위가 아니라 **heap page 단위**라는 것이다. 한 page 안에 dead tuple, 최근 update/delete 흔적, 모든 트랜잭션에 보인다고 말하기 어려운 tuple이 하나라도 있으면 그 page 전체를 all-visible로 다루기 어렵다.

대략적인 배치는 다음처럼 볼 수 있다.

```
relation: orders

main fork (heap)             visibility map fork (_vm)
+---------+                  +--------------------------+
| page 0  | <--------------> | p0: all-visible=1        |
| page 1  | <--------------> | p1: all-visible=0        |
| page 2  | <--------------> | p2: all-visible=1        |
+---------+                  +--------------------------+

btree index
+-------------------------------+
| key=(customer_id, created_at)  |
| payload=(amount)              |
| tid=(page 1, offset 7)        |
+-------------------------------+
```

인덱스 엔트리는 결국 heap TID를 가진다. executor는 TID에서 page number를 얻고, visibility map에서 그 page의 all-visible bit를 확인한다.

### 3. Index-Only Scan의 실행 흐름

공식 문서 §11.9의 설명을 알고리즘처럼 풀면 다음 순서가 된다.

```
for each index tuple matched by index condition:
    tid = index_tuple.heap_tid
    heap_page_no = tid.block_number

    if visibility_map[heap_page_no].all_visible:
        return values from index tuple
    else:
        heap_tuple = fetch_heap_tuple(tid)
        if visible_to_snapshot(heap_tuple):
            return values from heap/index as needed
```

즉 "Index-Only Scan" 계획 노드가 항상 heap을 0번 읽는다는 뜻은 아니다. all-visible bit가 set된 page에서는 인덱스 값만 반환하지만, bit가 unset이면 heap tuple visibility를 확인해야 한다. `EXPLAIN (ANALYZE, BUFFERS)`에서 `Heap Fetches`가 보이는 이유가 여기에 있다.

상태 전이를 page 관점으로 보면 더 명확하다.

```
             VACUUM 확인
  not all-visible ───────────▶ all-visible
       ▲                         │
       │                         │ INSERT/UPDATE/DELETE 등
       └─────────────────────────┘ page 내용 변경
```

VACUUM은 page를 검사해 모든 tuple이 모든 트랜잭션에 보인다고 판단할 수 있을 때 all-visible bit를 세울 수 있다. 반대로 page에 변경이 생기면 all-visible 상태는 깨질 수 있다. 그래서 오래 변하지 않는 이력성 테이블은 이점을 얻기 쉽고, update/delete가 잦은 hot table은 heap fetch가 많이 남을 수 있다.

### 4. Cost model이 보는 핵심 신호

공식 문서는 Index-Only Scan이 유리하려면 heap page의 상당 부분이 all-visible이어야 한다고 설명한다. VM은 heap보다 훨씬 작아 메모리에 머무를 가능성이 높지만, unset page가 많으면 결국 heap random access를 반복하기 때문이다. `pg_class.relallvisible / relpages` 비율은 planner가 heap을 얼마나 피할 수 있을지 추정하는 신호로 알려져 있다.

### 5. Covering Index와 INCLUDE의 역할

Index-Only Scan에는 두 가지 큰 조건이 있다.

1. 인덱스 타입이 index-only scan을 지원해야 한다.
2. 쿼리가 참조하는 컬럼이 모두 인덱스에서 제공되어야 한다.

두 번째 조건 때문에 PostgreSQL은 `INCLUDE` 컬럼을 제공한다. 예를 들어 다음 쿼리를 자주 실행한다고 하자.

```sql
SELECT amount
FROM orders
WHERE customer_id = 42
ORDER BY created_at DESC
LIMIT 20;
```

이 경우 검색과 정렬에는 `customer_id`, `created_at`이 필요하고 반환에는 `amount`가 필요하다.

```sql
CREATE INDEX orders_customer_created_idx
ON orders (customer_id, created_at DESC)
INCLUDE (amount);
```

공식 문서에 따르면 `INCLUDE` 컬럼은 search key가 아니라 payload로 저장된다. B-tree 탐색 순서를 결정하지는 않지만, executor가 heap에 가지 않고 반환 값을 만들 수 있게 인덱스 tuple 안에 실린다. 그러나 해당 TID의 heap page가 all-visible이 아니면 PostgreSQL은 여전히 heap을 방문한다.

```
Covering index 있음?
   no  -> 일반 Index Scan 또는 다른 계획
   yes -> VM all-visible?
           yes -> 진짜로 heap 생략
           no  -> heap fetch로 visibility 확인
```

### 6. 왜 visibility map은 page 단위인가

tuple마다 visibility 정보를 인덱스에 복제하면 heap 확인을 더 자주 피할 수 있다. 하지만 update/delete 때마다 여러 인덱스의 메타데이터까지 동기화해야 하므로 write path가 무거워진다. VM은 대신 page 단위의 보수적인 요약을 둔다. 한 비트로 많은 tuple을 대표하므로 작고 캐시에 남기 쉽다. false는 "안 보인다"가 아니라 "heap을 확인해야 한다"는 뜻이다.

## 검증

문서 흐름을 따라가면 실험은 다음 형태로 재현할 수 있다. 핵심은 같은 covering index를 유지한 채 VACUUM 전후로 `Heap Fetches`가 줄어드는지 보는 것이다.

```sql
CREATE TABLE ios_demo (
    id bigserial PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ios_demo (customer_id, amount)
SELECT (g % 100), g
FROM generate_series(1, 100000) AS g;

CREATE INDEX ios_demo_customer_idx
ON ios_demo (customer_id, id)
INCLUDE (amount);

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, amount
FROM ios_demo
WHERE customer_id = 42
ORDER BY id
LIMIT 100;

VACUUM ios_demo;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, amount
FROM ios_demo
WHERE customer_id = 42
ORDER BY id
LIMIT 100;
```

공식 문서 기준으로 계획 노드는 `Index Only Scan`으로 나올 수 있다. VACUUM 뒤에는 `Heap Fetches`가 0에 가까워질 수 있고, 이후 같은 page에 UPDATE/DELETE가 발생하면 다시 늘 수 있다.

운영 환경에서 확인할 때는 `EXPLAIN (ANALYZE, BUFFERS)`의 `Heap Fetches`와 함께 다음 통계를 같이 본다.

```sql
SELECT relname, relpages, relallvisible
FROM pg_class
WHERE relname = 'ios_demo';
```

`relallvisible / relpages`가 높을수록 heap I/O를 줄일 여지가 크다. 판단은 `EXPLAIN ANALYZE`로 확인한다.

## 잘못 알고 있던 것

- **"Index Only Scan은 heap을 절대 읽지 않는다"** → PostgreSQL에서는 틀린 표현이다. 계획 이름은 Index-Only Scan이어도 VM의 all-visible bit가 unset이면 heap tuple을 읽어 snapshot visibility를 확인한다.
- **"covering index만 만들면 끝난다"** → 부족하다. covering index는 값 제공 조건을 해결할 뿐이고, MVCC 가시성 조건은 visibility map이 해결한다. 두 조건이 같이 맞아야 heap 접근을 실질적으로 피한다.
- **"visibility map은 row마다 저장된다"** → 아니다. 공식 문서 기준 heap page마다 두 비트를 저장한다. 한 page의 일부 tuple 변화가 그 page 전체의 index-only 효과를 낮출 수 있다.

## 더 파고들 만한 것

- PostgreSQL VACUUM이 all-visible bit를 세우거나 지우는 정확한 조건과 lock/WAL 처리.
- HOT update가 index scan, index-only scan, visibility map에 미치는 영향.

## 참고

- PostgreSQL 18 Documentation, 11.9. Index-Only Scans and Covering Indexes: https://www.postgresql.org/docs/current/indexes-index-only-scans.html
- PostgreSQL 18 Documentation, 66.4. Visibility Map: https://www.postgresql.org/docs/current/storage-vm.html
- PostgreSQL Documentation, Using EXPLAIN: https://www.postgresql.org/docs/current/using-explain.html
