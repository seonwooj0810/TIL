# @OneToMany fetch=LAZY 의 프록시 객체 동작

> **Primary source:** Hibernate User Guide §6.2 (Lazy fetching) + Jakarta Persistence 3.2 §11.1.36 (OneToMany)
> **Secondary:** Hibernate ORM 소스 `AbstractPersistentCollection`, `PersistentBag`, `CollectionLoadContext`
> **Date:** 2026-05-24
> **Status:** draft

## 왜 봤나

- `@ManyToOne(fetch=LAZY)`의 프록시(`HibernateProxy`)와 `@OneToMany(fetch=LAZY)`의 "프록시"를 같은 것으로 막연히 묶어 이해하고 있었다. 둘은 만들어지는 방식과 초기화 트리거가 다르다.
- 컬렉션 필드에 `new ArrayList<>()`로 초기화해 두는 관용구가 왜 안전한지, 그리고 왜 setter로 갈아끼우면 안 되는지를 자료구조 차원에서 짚고 싶었다.

## 핵심 한 문장

> `@OneToMany(LAZY)`의 컬렉션은 `HibernateProxy`(엔티티 프록시)가 아니라 **`PersistentCollection` 래퍼**다. 자식 엔티티가 아닌 **`List`/`Set` 자체**를 감싸 두고, 첫 read/write 호출이 들어올 때 SQL을 실행해 내부 배열을 채운다.

## 내부 동작

### 1) 두 종류의 "Lazy" 객체 — 헷갈리지 말 것

| 연관 | LAZY 표현형 | 만들어지는 방법 |
| --- | --- | --- |
| `@ManyToOne` / `@OneToOne` | `HibernateProxy` (엔티티 서브클래스) | 런타임 서브클래싱(Bytebuddy/CGLIB) 또는 build-time enhancement |
| `@OneToMany` / `@ManyToMany` | `PersistentCollection` (`PersistentBag` 등) | 엔티티 로드 시 부모의 컬렉션 필드를 Hibernate가 **교체** |

Hibernate User Guide §6.2에 따르면 단일 엔티티 LAZY는 **프록시 서브클래스**가, 컬렉션 LAZY는 **인터페이스 구현(PersistentCollection)** 가 사용된다. 따라서 컬렉션 LAZY는 컴파일 타임에 final 클래스로 잠가도 동작한다 — 인터페이스만 같으면 되기 때문.

### 2) PersistentCollection의 메모리 레이아웃

```
parent (Order, MANAGED)
   └─ items : List<Item>   ──►  PersistentBag
                                ├─ session         : SharedSessionContractImplementor
                                ├─ role            : "Order.items"
                                ├─ key             : owner FK
                                ├─ initialized     : boolean
                                ├─ initializing    : boolean
                                ├─ bag             : List  ← 실제 데이터 (초기엔 null/empty)
                                └─ storedSnapshot  : Serializable  ← dirty 비교용
```

`bag` 필드가 실제 자식 엔티티들을 담는 컨테이너이고, `storedSnapshot`은 flush 시점에 add/remove를 가려내기 위한 별도 스냅샷이다 ([[flush-and-dirty-checking]] 참고).

### 3) 상태 전이

```
                  read/write 호출
[ uninitialized ] ───────────────► [ initializing ]
   initialized=false                  initializing=true
                                          │
                                  SELECT ... WHERE fk=?
                                          ▼
                                    [ initialized ]
                                    initialized=true
```

`initialized=false`인 상태에서 `size()`, `iterator()`, `get(i)`, `contains(x)` 등 거의 모든 메서드가 진입점이 된다. `AbstractPersistentCollection#readSize`/`#read` 가 호출되면서 `initialize(...)`가 트리거된다.

### 4) 초기화 알고리즘

```java
// AbstractPersistentCollection#initialize 의 단순화된 흐름
void initialize(boolean writing) {
    if (initialized) return;
    if (session == null || !session.isOpen())
        throw new LazyInitializationException(
            "could not initialize proxy - no Session");
    session.initializeCollection(this, writing);
    // 내부적으로 CollectionPersister 가 role(예: "Order.items")로
    // SQL: select i.* from item i where i.order_id = ?  실행
    // 결과를 this.bag 에 채우고 storedSnapshot 갱신 후
    // initialized = true 로 전이
}
```

세션이 닫혀 있으면 여기서 `LazyInitializationException`이 던져진다. 즉 예외의 근원은 "프록시"가 아니라 **PersistentCollection이 자기 세션을 잃었다는 사실**이다.

### 5) 부모 엔티티 로드 시점에 일어나는 일

`em.find(Order.class, id)`가 호출되면 Hibernate는 Order의 모든 컬렉션 필드를 **PersistentCollection 인스턴스로 교체**한다. 사용자가 엔티티에 `new ArrayList<>()`로 초기화해 둔 인스턴스는 버려진다. 그래서 다음 규약이 따른다.

- 컬렉션 필드는 **재할당 금지** (`order.setItems(new ArrayList<>())` 금지). 재할당하면 PersistentBag을 잃어 dirty checking·orphanRemoval이 깨진다.
- 추가/삭제는 항상 컬렉션 메서드(`add`, `remove`)로. 그래야 PersistentCollection이 자신이 dirty임을 안다.

## 검증

Hibernate 소스 흐름:

```
order.getItems().size()
  → PersistentBag#size
    → AbstractPersistentCollection#readSize
      → initialize(false)
        → session.initializeCollection(this, false)
          → DefaultInitializeCollectionEventListener#onInitializeCollection
            → CollectionPersister#initialize
              → CollectionLoader#load   // SQL 발사
```

세션 밖에서 호출했을 때:

```java
Order o = txTemplate.execute(s -> em.find(Order.class, 1L));
o.getItems().size();   // LazyInitializationException
// AbstractPersistentCollection#throwLazyInitializationException
```

OSIV(Open Session In View)가 켜져 있으면 뷰 렌더링까지 세션이 살아 있어 같은 호출이 통과한다 — 같은 코드가 환경에 따라 결과가 다르다는 흔한 함정.

## 잘못 알고 있던 것

- "컬렉션도 `HibernateProxy` 서브클래스다." → 틀림. 엔티티 프록시와 컬렉션 프록시는 구현이 완전히 다르다. 컬렉션은 `List`/`Set` 인터페이스를 구현한 `PersistentBag`/`PersistentSet` 등이고, 서브클래싱이 아니라 **인터페이스 교체**다.
- "`getItems()`를 호출하는 순간 SQL이 나간다." → 정확히는 틀림. `getItems()`는 PersistentCollection 참조만 돌려준다. SQL은 그 컬렉션의 메서드(`size`, `iterator`...)가 호출되는 시점에 나간다.
- "필드를 `new ArrayList<>()`로 초기화해도 무방하다." → 부분적으로만 맞다. **초기 상태(엔티티가 still transient)**에서는 안전하지만, 일단 영속화된 엔티티의 컬렉션 필드를 새 ArrayList로 갈아끼우면 PersistentBag을 잃는다.

## 더 파고들 만한 것

- bytecode enhancement(`hibernate-enhance-maven-plugin`)가 컬렉션 lazy 동작에 미치는 영향과 lazy attribute loading.
- N+1 문제와 fetch join / `@EntityGraph`의 동작 차이 ([[n-plus-one-and-entity-graph]] 후보).

## 참고

- Hibernate User Guide §6.2 Lazy fetching, §6.3 Bytecode enhancement.
- Jakarta Persistence 3.2 §11.1.36 OneToMany, §3.2.4 Synchronization.
- Hibernate ORM 소스: `org.hibernate.collection.spi.AbstractPersistentCollection`, `org.hibernate.collection.spi.PersistentBag`, `org.hibernate.event.internal.DefaultInitializeCollectionEventListener`.
