# N+1 문제와 fetch join / @EntityGraph 동작 차이

> **Primary source:** Hibernate User Guide §11 (Fetching), §11.7 (Fetch profiles), Jakarta Persistence Spec §3.7.4 (`EntityGraph`)
> **Secondary:** `org.hibernate.loader.ast.*`, `org.hibernate.graph.*` 소스
> **Date:** 2026-05-24
> **Status:** draft

## 왜 봤나

- `@OneToMany(fetch = LAZY)` 컬렉션을 루프에서 건드릴 때마다 select가 N번 더 나가는 걸 로그로 보면서, `fetch join`만 알면 충분한 줄 알았다.
- `@EntityGraph`가 "fetch join의 어노테이션 버전" 정도인 줄 알았는데, 동작 단계와 한계가 다르다.

## 핵심 한 문장

> N+1 은 **연관 엔티티를 따로 로드하는 select 가 컬렉션 크기만큼 더 나가는 현상**이며, `fetch join`은 JPQL 파서 단계에서 SQL JOIN으로 펴버리는 반면 `@EntityGraph`는 **fetch graph/load graph 힌트를 LoadPlan에 주입**해 런타임에 fetch 전략을 바꾼다.

## 내부 동작

### N+1 발생 메커니즘

```
List<Order> orders = em.createQuery("select o from Order o", Order.class).getResultList();  // SQL 1번
for (Order o : orders) {
    o.getItems().size();  // 컬렉션 프록시 초기화 → SQL N번
}
```

`PersistentBag` 같은 컬렉션 래퍼는 `initialize()` 호출 시 `CollectionLoader`가 `select ... from item where order_id = ?` 를 발행한다 (Hibernate User Guide §11.2). N건의 부모 → N번의 자식 쿼리.

### fetch join 경로

JPQL `join fetch` 는 `HqlSqlWalker` 단계에서 `FromElement` 에 `fetch=true` 플래그를 단 트리로 변환되고, 최종적으로 단일 SQL `JOIN` 으로 떨어진다. 결과 ResultSet 한 번을 walking 하면서 부모/자식 hydration 을 동시에 처리한다.

```
HQL  : select o from Order o join fetch o.items
       │
       ▼ AST: FromElement(Order) ─ JoinElement(items, fetch=true)
       │
       ▼ SQL: SELECT o.*, i.* FROM orders o JOIN items i ON i.order_id = o.id
```

한계 두 가지:
- **Cartesian product**: 결과 row가 부모×자식이라 `distinct` 가 필요. Hibernate 6 부터는 JPA `select distinct` 가 SQL `DISTINCT` 로 항상 번역되지는 않고, ResultTransformer 가 in-memory dedup (User Guide §5.4.3).
- **Pagination + collection fetch**: `setMaxResults` 를 collection fetch 와 함께 쓰면 Hibernate 가 `HHH000104: firstResult/maxResults specified with collection fetch; applying in memory!` 로 경고하고, **전체를 메모리에 올린 뒤 자른다**. OOM의 흔한 경로.

### @EntityGraph 경로

`@EntityGraph` 는 JPA spec §3.7.4 에서 두 모드를 정의한다:

| 모드 | 효과 |
| --- | --- |
| `javax.persistence.fetchgraph` | 그래프에 포함된 속성만 EAGER, 나머지는 LAZY 강제 |
| `javax.persistence.loadgraph` | 그래프에 포함된 속성은 EAGER, 나머지는 매핑된 기본값 유지 |

Hibernate 내부에서는 `EntityGraph` 가 `RootGraphImpl` → `AppliedGraph` 로 변환되어, **LoadPlan/Fetch tree 생성 시 attribute 별 FetchTiming 을 override** 한다 (`org.hibernate.graph.spi.AppliedGraph`). 결과적으로 발행되는 SQL은 보통 `LEFT OUTER JOIN` 이지만, 그래프가 깊거나 다중 컬렉션이면 Hibernate 가 **여러 select 로 쪼개기도 한다** (subselect/batch fetch fallback).

### 핵심 차이

- `fetch join` 은 **쿼리 단위**의 명령형 지시 — 그 쿼리에서만 적용.
- `@EntityGraph` 는 **fetch plan 단위의 선언형 힌트** — Spring Data 메서드, named query 등에 재사용 가능하고 모드(fetch/load)로 의미가 분리됨.
- 둘 다 `MultipleBagFetchException` (List 두 개 이상을 동시에 fetch 시도 시) 위험은 동일. List → Set 으로 바꾸거나, 하나만 join 하고 나머지는 `@BatchSize` / subselect 로 분리한다 (User Guide §11.8).

## 검증

Hibernate 소스 따라가기:

1. `org.hibernate.query.sqm.tree.from.SqmAttributeJoin#isFetched()` — fetch join 플래그가 SQM 트리에 어떻게 박히는지.
2. `org.hibernate.loader.ast.internal.SingleIdEntityLoaderStandardImpl` — load 시 `LoadQueryInfluencers` 에서 entity graph 를 읽어 fetch tree 를 보정.
3. `HHH000104` 경고 발생 지점: `org.hibernate.loader.ast.internal.CollectionLoaderSingleKey` 주변, limit 가 있는데 collection fetch 가 있으면 ScrollableResults 로 전체를 읽도록 분기.

코드 실험으로 확인할 항목:
```java
// 1) N+1 재현
List<Order> a = em.createQuery("select o from Order o", Order.class).getResultList();
a.forEach(o -> o.getItems().size());  // SQL 1 + N

// 2) fetch join
em.createQuery("select distinct o from Order o join fetch o.items", Order.class).getResultList();  // SQL 1

// 3) @EntityGraph
EntityGraph<Order> g = em.createEntityGraph(Order.class);
g.addAttributeNodes("items");
em.createQuery("select o from Order o", Order.class)
  .setHint("jakarta.persistence.fetchgraph", g)
  .getResultList();  // SQL 1 (LEFT JOIN)
```

## 잘못 알고 있던 것

- "fetch join 과 @EntityGraph 는 같은 SQL을 만든다" → 보통 비슷하지만 동일 보장은 없다. EntityGraph는 LoadPlan 단으로 들어가 batch fetch / subselect 와 섞일 수 있다.
- "`distinct` 만 붙이면 fetch join 의 페이징 문제도 해결된다" → 아니다. `HHH000104` 는 그대로다. 메모리 페이징.
- "`@EntityGraph(type = LOAD)` 는 fetch graph 와 사실상 같다" → LOAD 는 매핑된 EAGER 를 죽이지 않는다. 모드 차이가 실제 SQL 차이로 이어진다.

## 더 파고들 만한 것

- `@BatchSize`, `@Fetch(SUBSELECT)` 가 어떤 시점에 발행되는지 (LoadPlan vs Initializer 단계).
- Hibernate 6 의 `SqmTreePrinter` 로 fetch join 이 SQM 단계에서 어떻게 보이는지 따라가기.
- `MultipleBagFetchException` 회피 시 Set 전환과 `@OrderColumn` 의 트레이드오프.

## 참고

- Hibernate ORM 6.x User Guide §11 Fetching
- Jakarta Persistence 3.1 §3.7.4 Entity Graphs
- HHH000104 경고 소스: `org.hibernate.loader.ast.internal.CollectionLoaderSingleKey`
