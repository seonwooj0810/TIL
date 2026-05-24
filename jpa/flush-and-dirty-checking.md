# flush() 시점과 dirty checking 내부 동작

> **Primary source:** Jakarta Persistence 3.2 §3.2 (Entity Instance's Life Cycle), §3.10.7 (Synchronization to the Database) + Hibernate User Guide §6 (Flushing)
> **Secondary:** Hibernate ORM 소스 `DefaultFlushEventListener`, `AbstractEntityPersister#findDirty`
> **Date:** 2026-05-24
> **Status:** draft

## 왜 봤나

- `save()`를 호출하지 않았는데 UPDATE가 나가는 동작이 "마법"처럼 느껴진 적이 있어, 어떤 자료구조 위에서 어떤 비교가 일어나는지 정확히 짚고 싶었다.
- flush가 commit 시점에만 일어난다고 막연히 알고 있었던 것을 바로잡고 싶었다.

## 핵심 한 문장

> 영속성 컨텍스트는 엔티티가 attach 될 때 **snapshot**을 따로 떠 놓고, flush 시점에 현재 상태와 필드 단위로 비교(`findDirty`)해서 변경된 컬럼만 UPDATE를 만들어낸다.

## 내부 동작

### 1) FlushMode와 flush가 일어나는 시점

Jakarta Persistence §3.10.8에 정의된 FlushModeType은 두 가지뿐이다.

| FlushModeType | 동작 |
| --- | --- |
| `AUTO` (default) | 트랜잭션 commit 직전 + 쿼리 실행 직전마다 동기화 |
| `COMMIT` | commit 직전에만 동기화 (쿼리 실행 전 X) |

Hibernate는 여기에 `ALWAYS`, `MANUAL` 등을 더 두지만 표준은 위 둘. 즉 `em.flush()` 명시 호출이 없어도 다음 3가지가 자동 트리거다.

- `tx.commit()` 직전
- `JPQL/Criteria` 쿼리 실행 직전 (AUTO일 때, 쿼리가 변경분을 봐야 하므로)
- `em.flush()` 명시 호출

> 주의: native query는 Hibernate 입장에서 영향 테이블을 알 수 없으므로 보수적으로 flush 대상이지만 설정에 따라 다르다 (Hibernate User Guide §6).

### 2) Snapshot 자료구조

영속성 컨텍스트(Hibernate에서는 `PersistenceContext`)는 attach 시점에 엔티티 필드 값을 **Object[]**로 복사한다. 이를 `loadedState`(또는 snapshot)라 부른다.

```
PersistenceContext
├── entitiesByKey:        Map<EntityKey, Object>          // 1차 캐시
└── entityEntryContext:   IdentityHashMap<Object, EntityEntry>
                                                │
                                                ▼
                                         EntityEntry
                                         ├── id
                                         ├── status   (MANAGED, DELETED, ...)
                                         ├── loadedState : Object[]   ← snapshot
                                         └── persister
```

핵심은 **현재 엔티티 인스턴스의 필드값**과 **`loadedState`**가 별개의 메모리 공간에 산다는 점이다. dirty checking은 이 두 배열을 인덱스 단위로 비교하는 작업이다.

### 3) 상태 전이

```
       new          persist()
new ─────────► [ MANAGED ] ◄────────── find()/query result
                │   ▲
        remove()│   │ merge()
                ▼   │
            [ REMOVED ]               detach()/close()
                                ┌──────────────────────┐
                                ▼                      │
                          [ DETACHED ] ─── merge() ────┘
```

flush는 `MANAGED` 상태의 엔티티만 본다. `REMOVED`는 DELETE, `MANAGED && dirty`는 UPDATE, 새로 `persist()`된 것은 INSERT로 변환된다.

### 4) `findDirty` 알고리즘

Hibernate `AbstractEntityPersister#findDirty`의 흐름은 대략 다음과 같다.

```java
// 단순화한 의사코드
int[] findDirty(Object[] current, Object[] loaded, EntityPersister p) {
    List<Integer> dirty = new ArrayList<>();
    for (int i = 0; i < p.propertySpan; i++) {
        if (!p.propertyTypes[i].isEqual(current[i], loaded[i])) {
            dirty.add(i);
        }
    }
    return dirty.isEmpty() ? null : toIntArray(dirty);
}
```

복잡도는 **O(N), N = 엔티티 필드 수**이고, 영속성 컨텍스트 전체에 대해서는 O(엔티티 수 × 필드 수). 그래서 영속성 컨텍스트가 비대해질수록 flush 비용이 선형으로 늘어난다 (Hibernate User Guide §6.1에서 명시).

### 5) 어떤 UPDATE가 나가는가

기본 설정에서는 **변경된 컬럼만** 골라 동적으로 UPDATE를 만든다 (`@DynamicUpdate` 없이도 Hibernate는 dirty 컬럼만 SET하는 동적 SQL을 생성할 수 있다 — 단, 캐시되는 SQL 모양이 늘어남). 반대로 `@DynamicUpdate`를 끄면 **모든 컬럼**을 SET하는 고정 SQL이 캐시되어 재사용된다 — PreparedStatement 캐시 친화적이라는 트레이드오프.

## 검증

Hibernate 소스에서 흐름을 따라가면 다음 경로로 떨어진다.

```
session.flush()
  → DefaultFlushEventListener#onFlush
    → AbstractFlushingEventListener#flushEverythingToExecutions
      → flushEntities()                       // managed 엔티티 순회
        → DefaultFlushEntityEventListener#dirtyCheck
          → persister.findDirty(current, loaded, ...)
      → flushCollections()
      → ActionQueue.executeActions()          // INSERT → UPDATE → DELETE 순
```

`ActionQueue`의 실행 순서는 §3.2.4의 제약(참조 무결성)을 만족시키기 위해 고정되어 있다: insertions → updates → collection removals → collection updates → collection creations → deletions.

검증용 코드 스니펫:

```java
// examples/DirtyCheckingTest.java 참고
@Test
void update_without_save() {
    Long id = txTemplate.execute(s -> {
        Member m = new Member("A");
        em.persist(m);
        return m.getId();
    });

    txTemplate.executeWithoutResult(s -> {
        Member m = em.find(Member.class, id);
        m.setName("B");          // setter만 호출, save/merge 없음
        // tx commit 직전 AUTO flush → UPDATE member set name=? where id=?
    });

    assertThat(repo.findById(id).get().getName()).isEqualTo("B");
}
```

## 잘못 알고 있던 것

- "flush는 commit 시점에만 일어난다." → 틀림. `AUTO`에서는 **JPQL 실행 직전에도** 자동 flush 된다. 그래야 같은 트랜잭션 안에서 변경한 결과를 쿼리가 볼 수 있다.
- "dirty checking은 메서드 호출(setter)을 가로채서 추적한다." → 틀림. Hibernate는 기본적으로 **bytecode enhancement 없이는 setter를 가로채지 않는다**. 그냥 flush 시점에 snapshot과 통째로 비교한다. (옵션으로 enhancement 기반 dirty tracking을 켤 수 있다 — Hibernate User Guide §6.2.)
- "변경된 필드만 SET하는 SQL이 나가는 건 `@DynamicUpdate`를 붙여야 한다." → Hibernate는 동적 UPDATE를 만들 수 있지만, **기본값은 모든 컬럼을 SET하는 고정 SQL**이다. 동적 SET을 원하면 `@DynamicUpdate` 필요.

## 더 파고들 만한 것

- bytecode enhancement 기반 dirty tracking과 lazy attribute loading의 동작.
- 영속성 컨텍스트가 매우 클 때 flush 비용을 줄이는 패턴 (StatelessSession, 배치 flush/clear).

## 참고

- Jakarta Persistence 3.2 — §3.2 Entity Instance's Life Cycle, §3.10 Synchronization to the Database.
- Hibernate User Guide §6 Flushing, §6.2 Dirty Tracking.
- Hibernate ORM 소스: `org.hibernate.event.internal.DefaultFlushEventListener`, `org.hibernate.persister.entity.AbstractEntityPersister#findDirty`.
