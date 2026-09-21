# JPA merge(): detached 엔티티 병합은 UPDATE가 아니라 "SELECT 후 상태 복사"다

> **Primary source:** jakarta.persistence.EntityManager#merge Javadoc (Jakarta Persistence API 소스, `api/src/main/java/jakarta/persistence/EntityManager.java`) / Hibernate ORM 소스 `org.hibernate.event.internal.DefaultMergeEventListener`
> **Secondary:** Hibernate ORM User Guide, "Merging detached objects" 섹션
> **Date:** 2026-09-21
> **Status:** draft

## 왜 봤나

- `merge()`를 "detached 엔티티의 필드값 그대로 UPDATE 쿼리를 날리는 연산"으로 이해하는 경우가 흔하다. 이번 실행에서 Jakarta Persistence API의 `EntityManager.java` 소스와 Hibernate의 `DefaultMergeEventListener` 소스를 직접 열어보니, 실제 흐름은 그것과 다르다.
- 이전 노트([[optimistic-locking-version-mechanism]])에서 "merge와 detached 버전"을 언급했지만 `merge()` 자체가 내부에서 어떤 순서로 동작하는지는 다루지 않았다 — 그 공백을 채운다.

## 핵심 한 문장

> `merge(detached)`는 인자로 받은 객체를 건드리지 않고, 영속성 컨텍스트 안에 이미 있거나 DB에서 새로 조회(SELECT)한 별개의 managed 인스턴스에 상태를 "복사"해 반환하는 연산이다 — 인자와 반환값은 서로 다른 Java 객체 identity를 갖는다.

## 내부 동작

### 1. 스펙 레벨: 반환값은 별개의 객체다

`jakarta.persistence.EntityManager#merge`의 Javadoc을 그대로 인용하면:

> "Return a managed instance with the same persistent state as the given entity instance, but a **distinct Java object identity**. If the given entity is detached, the returned entity has the same persistent identity. This operation cascades to every entity related by an association marked `cascade=MERGE`."

즉 스펙 문서 자체가 "반환값은 인자와 다른 Java 객체"라고 명시한다. 예외는 인자가 이미 managed인 경우뿐 — 이때는 "it is itself ignored, but the operation still cascades, and it is returned directly"라고 되어 있어, 인자==반환값이 성립하는 유일한 케이스다. `merge()`는 `OptimisticLockException`과 "a record could not be read from the database"로 인한 `PersistenceException`을 던질 수 있다고도 명시되어 있다 — 이 두 예외가 아래 Hibernate 구현에서 어디서 나오는지 추적할 수 있다.

### 2. Hibernate 구현: 4가지 상태 분기

Hibernate의 `MergeEvent` → `DefaultMergeEventListener.onMerge()` → `doMerge()` → `merge()`는 넘어온 엔티티를 `PersistenceContext`에서 `EntityKey`로 조회해 4가지 `EntityState` 중 하나로 분류한다.

```
merge(entity) 호출
      │
      ▼
PersistenceContext에서 EntityKey로 엔트리 조회
      │
 ┌────┼────────────┬─────────────┐
 ▼    ▼             ▼             ▼
PERSISTENT      TRANSIENT      DETACHED         (default) DELETED
 │                │               │                    │
그대로 반환      복제 생성       session.find()로     세션에 남아있으면
+cascade만        후 save류       SELECT → 복사        ObjectDeletedException,
                  경로 (persist)  +cascade=MERGE       아니면 unSchedule 후
                                                        DETACHED 경로로 재위임
```

- **PERSISTENT** (`entityIsPersistent`): 이미 이 세션이 관리 중인 바로 그 인스턴스면 `copyCache.put(entity, entity, true)`로 자기 자신을 매핑해두고, `cascadeOnMerge` + `TypeHelper.replace`만 실행한 뒤 **그 인스턴스 자체**를 반환한다. Javadoc의 "managed 인스턴스는 그대로 반환" 문장이 이 분기다.
- **TRANSIENT** (`entityIsTransient`): `copyEntity()`가 `session.instantiate()`로 완전히 새 인스턴스를 만들고, `cascadeBeforeSave` → 필드 복사(`TypeHelper.replace`) → `saveTransientEntity`(내부적으로 `saveWithGeneratedId`/`saveWithRequestedId`, 즉 신규 INSERT 스케줄링) → `cascadeAfterSave` 순서로 진행한다. 이 경로는 `persist()`의 흐름과 거의 같은 코드를 복제된 인스턴스에 대해 수행하는 것에 가깝다.
- **DETACHED** (`entityIsDetached`) — 이 노트의 핵심: 식별자를 복제한(`clonedIdentifier`) 뒤 `session.find(entityName, clonedIdentifier)`를 `CascadingFetchProfile.MERGE` 프로필로 호출한다. **여기서 실제 SELECT가 나간다.** 조회된 managed 인스턴스가 있으면 그 인스턴스에 원본(detached) 값을 복사하고, `cascade=MERGE`로 지정된 연관관계까지 재귀적으로 병합한다.
  - `find()`가 `null`을 반환하면(DB에 해당 row가 없음) `persister.isTransient(entity, session)`으로 재확인한다. 이 값이 `Boolean.FALSE`(생성 식별자나 버전 프로퍼티가 있어 "확실히 detached였다"고 판정 가능한 경우)면 **`StaleObjectStateException`을 던진다** — 다른 트랜잭션이 이미 그 row를 지웠다는 뜻이다. 애매한 경우(할당식 id + 버전 프로퍼티 없음)만 "그냥 transient였을 것"으로 가정하고 계속 진행한다.
- **DELETED** (default 분기): 현재 세션의 `PersistenceContext`에 이미 그 엔트리가 남아있으면(같은 트랜잭션에서 `remove()`한 그 인스턴스를 다시 `merge()`) `ObjectDeletedException`을 던진다. 반면 엔트리가 이미 사라졌지만 "unloaded deletion"으로 스케줄만 남아있는 경우엔 `unScheduleUnloadedDeletion()`으로 삭제 예약을 취소하고 `entityIsDetached()`로 재위임한다 — 즉 삭제를 취소하고 detached처럼 다시 로딩한다.

### 3. MergeContext: 그래프 순환과 아이덴티티 재사용

`doMerge()`는 처리마다 `copiedAlready`(`MergeContext`)라는 원본→복제 매핑 맵을 확인한다. `copiedAlready.containsKey(entity) && copiedAlready.isOperatedOn(entity)`이면 이미 처리 중인 노드로 보고 즉시 그 복제본을 반환한다. 이 체크가 없으면 양방향 연관관계(A→B, B→A)를 가진 엔티티 그래프를 병합할 때 무한 재귀에 빠진다. 동시에 이 맵은 "같은 원본 인스턴스가 그래프의 여러 지점에서 참조돼도 항상 같은 복제 인스턴스로 매핑된다"를 보장해, 병합 후에도 그래프 안의 identity 동등성이 깨지지 않게 한다.

## 검증

- **SQL 로그로 확인**: `hibernate.show_sql=true`(또는 Spring이면 `spring.jpa.show-sql=true`)를 켜고, DB에 이미 존재하는 row에 대응하는 detached 엔티티의 필드 하나만 바꿔서 `merge()`를 호출해본다. `entityIsDetached`의 `session.find()` 호출 때문에 **UPDATE 이전에 먼저 SELECT 문이 나가는 것**을 로그에서 볼 수 있다. 값을 하나도 바꾸지 않고 `merge()`만 호출하면 SELECT만 나가고 UPDATE는 안 나갈 수도 있다(dirty checking이 변경분이 없다고 판단하면).
- **로거로 분기 확인**: Hibernate 로거 `org.hibernate.event.internal`을 TRACE 레벨로 켜면, 위에서 확인한 `EVENT_LISTENER_LOGGER` 호출부(`mergingDetachedInstance`, `ignoringPersistentInstance`, `mergingTransientInstance`) 덕분에 "Merging detached instance"류의 로그가 실제로 찍혀 지금 어떤 상태 분기를 타는지 바로 확인할 수 있다.
- **소스 확인 지점**: 이번 실행에서 `hibernate-orm` 저장소의 `hibernate-core/src/main/java/org/hibernate/event/internal/DefaultMergeEventListener.java`를 직접 열어 `onMerge`/`doMerge`/`merge`/`entityIsPersistent`/`entityIsTransient`/`entityIsDetached` 메서드 본문을 확인했고, `jakartaee/persistence` 저장소의 `EntityManager.java`에서 `merge()` 메서드 Javadoc 전문을 확인했다.

## 잘못 알고 있던 것

- **"merge()는 detached 인스턴스를 그대로 다시 managed로 만든다(같은 레퍼런스가 이제 managed다)"** — 틀렸다. 반환된 인스턴스는 별개의 Java 객체이고, 넘긴 detached 인스턴스는 호출 후에도 여전히 detached 상태로 남는다. 이후 코드는 반드시 `merge()`의 **반환값**을 사용해야 한다 (`entity = em.merge(entity)` 패턴이 관용구인 이유).
- **"merge()는 항상 UPDATE 쿼리를 보낸다"** — detached 케이스는 먼저 `session.find()`로 SELECT를 해서 현재 상태를 가져오고, 그 위에 필드를 덮어쓴 뒤 flush 시점에 dirty checking으로 실제 바뀐 컬럼만 UPDATE한다. 아무 필드도 안 바뀌었으면 UPDATE 자체가 안 나갈 수 있다.
- **"삭제된 row를 detached 엔티티로 merge하면 그냥 조용히 새로 INSERT된다"** — 아니다. Hibernate가 "확실히 detached였다"고 판정할 수 있는 경우(생성 식별자 또는 버전 프로퍼티 존재)에는 `find()`가 null을 반환하는 순간 `StaleObjectStateException`을 던진다. 재삽입 경로는 애매한 경우(할당식 id + 버전 없음)에만 선택된다.

## 더 파고들 만한 것

- Hibernate `EntityCopyObserver`가 "같은 detached 엔티티의 서로 다른 두 표현이 그래프 안에 동시에 존재"하는 상황을 allow/disallow/log 정책으로 어떻게 다루는지 — `MergeContext` 바로 옆에서 등장했던 영역.
- `cascade=MERGE`가 없는 연관관계에서 merge 이후 컬렉션의 dirty 판정이 어떻게 되는지, 그리고 [[hibernate-actionqueue-flush-ordering]]에서 다룬 flush 순서와의 상호작용.

## 참고

- Jakarta Persistence API 소스 (`jakartaee/persistence`, `api/src/main/java/jakarta/persistence/EntityManager.java`)
- Hibernate ORM 소스 (`hibernate/hibernate-orm`, `hibernate-core/src/main/java/org/hibernate/event/internal/DefaultMergeEventListener.java`)
- Hibernate ORM User Guide, "Merging detached objects" 섹션

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
