# Hibernate ActionQueue: persist 호출 순서를 무시하고 flush 때 SQL을 재배열하는 법

> **Primary source:** Hibernate ORM 소스 `org.hibernate.engine.spi.ActionQueue` (OrderedActions / executeActions), Hibernate User Guide §7 Flushing / §A.8 JDBC Batch Settings
> **Secondary:** Vlad Mihalcea, "Knowing flush operations order matters"
> **Date:** 2026-07-11
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/hibernate-actionqueue-flush-order

## 왜 봤나

- `remove(a)` 다음 줄에 `persist(b)`를 호출했는데, 로그를 보면 INSERT가 DELETE보다 **먼저** 나가서 unique 제약 위반이 터졌다. "코드 순서대로 SQL이 나간다"는 내 가정이 틀린 것.
- 왜 Hibernate가 내가 부른 순서를 무시하는지, 무슨 규칙으로 재배열하는지 끝까지 보고 싶었다.

## 핵심 한 문장

> `persist/merge/remove`는 SQL을 즉시 쏘지 않고 `ActionQueue`에 **타입별 액션**으로 쌓아두었다가(transactional write-behind), flush 시점에 **호출 순서가 아니라 액션 타입의 고정 우선순위**대로 실행한다 — INSERT가 맨 앞, DELETE가 맨 뒤.

## 내부 동작

### 1. write-behind: SQL은 flush까지 미뤄진다

`em.persist(entity)`를 호출해도 대부분의 경우 INSERT가 바로 나가지 않는다. Hibernate는 이 작업을 `EntityInsertAction`으로 만들어 세션의 `ActionQueue`에 넣어둔다. `remove`는 `EntityDeleteAction`, dirty checking으로 감지된 변경은 `EntityUpdateAction`이 된다. 실제 SQL은 flush(트랜잭션 커밋, 명시적 `flush()`, 또는 JPQL 실행 전 auto-flush)가 큐를 훑을 때 한꺼번에 나간다.

### 2. flush 시점의 고정 실행 순서

`ActionQueue`는 액션을 종류별 리스트로 분리해서 보관하고, `executeActions()`는 이 리스트들을 **아래 순서대로** 비운다. 이 순서는 액션을 큐에 넣은 시간과 무관하다.

```
executeActions() 실행 순서 (액션 타입 우선순위)
  1. OrphanRemovalAction          고아 객체(orphanRemoval) 제거
  2. AbstractEntityInsertAction   엔티티 INSERT   ← 앞쪽
  3. EntityUpdateAction           엔티티 UPDATE
  4. QueuedOperationCollectionAction
  5. CollectionRemoveAction       컬렉션 원소 삭제
  6. CollectionUpdateAction       컬렉션 갱신
  7. CollectionRecreateAction     컬렉션 재생성
  8. EntityDeleteAction           엔티티 DELETE   ← 맨 뒤
```

즉 코드에서 `remove → persist` 순으로 불러도, flush 때는 **2번(INSERT)이 8번(DELETE)보다 먼저** 실행된다.

```
코드 호출 순서          ActionQueue (타입별 버킷)        flush 실행 순서
remove(post42)   ──┐    deletions:  [del post42]        INSERT post99   (2)
persist(post99)  ──┘    insertions: [ins post99]   →    ...
                                                         DELETE post42   (8)
```

### 3. 왜 이 순서인가 — 참조 무결성

부모를 자식보다 먼저 넣고, 삭제를 맨 뒤로 미루면 FK 참조가 항상 성립한다. 자식 INSERT가 나갈 때 그것이 가리키는 부모 row는 이미 (같은 flush의 앞 단계에서) 존재하고, 부모 DELETE는 이 부모를 참조하던 자식들의 삭제/갱신이 모두 끝난 뒤에 실행된다. 공식 소스의 이 배치는 "가능한 한 제약 위반 없이 한 batch로 밀어넣기 위한" 설계로 볼 수 있다.

컬렉션 액션이 엔티티 UPDATE(3) 뒤, 엔티티 DELETE(8) 앞에 끼어 있는 것도 같은 논리다. `@OneToMany` join 컬럼을 끊는 `CollectionRemoveAction`(5)이 자식 엔티티 DELETE(8)보다 먼저 실행돼, 자식 row가 지워질 때는 이미 부모 쪽 참조가 정리돼 있다. 반대로 새 원소를 넣는 `CollectionRecreateAction`(7)은 엔티티 INSERT(2) 다음이라 참조 대상이 존재한다. 정리하면 **"만들기(2)는 앞, 끊기·지우기(5,8)는 뒤"** 라는 한 방향 규칙이 엔티티와 컬렉션 양쪽에 관통한다.

### 4. INSERT 내부의 2차 정렬 — order_inserts와 배칭

같은 INSERT 버킷 안에서도, `hibernate.order_inserts=true`이면 액션들을 **엔티티 타입별로 묶고 FK 의존성으로 위상정렬**한다(내부 InsertActionSorter). 이유는 JDBC 배칭이다. `PreparedStatement` batch는 **같은 SQL 문자열**이 연속될 때만 쌓인다. `A, B, A, B`처럼 타입이 번갈아 오면 batch가 매번 깨져(flush) 왕복이 늘고, `A, A, B, B`로 정렬하면 `batch_size`만큼 묶여 한 번에 나간다. `order_updates`도 UPDATE에 대해 같은 역할을 한다. 즉 이 설정들이 §A.8 "JDBC Batch Settings"에 `batch_size`와 함께 묶여 있는 이유가 이것이다.

```
batch_size=50, Author 10건 + Book 10건을 번갈아 persist
 order_inserts=false:  [A][B][A][B]...  SQL 문자열이 매번 바뀜
                       → executeBatch가 20번, 배치 이점 0
 order_inserts=true:   [A×10][B×10]      같은 SQL 연속
                       → executeBatch 2번 (Author 1묶음, Book 1묶음)
```

주의: `order_inserts`는 이미 큐에 쌓인 액션을 flush 직전 재배열할 뿐, INSERT가 **지연 가능**할 때만 의미가 있다. 아래 IDENTITY처럼 persist 즉시 INSERT가 나가면 정렬할 큐 자체가 없다.

### 5. IDENTITY 전략은 이 write-behind를 깨뜨린다

`GenerationType.IDENTITY`는 식별자를 DB의 auto-increment가 채워야 하고, 영속성 컨텍스트는 1차 캐시 키로 식별자가 **즉시** 필요하다. 그래서 IDENTITY에서는 `persist()` 순간 INSERT를 **바로 실행**해서 생성된 키를 받아온다(EntityIdentityInsertAction이 지연되지 않음). 결과적으로 IDENTITY로는 insert 배칭이 사실상 불가능하다. SEQUENCE/TABLE 전략은 키를 미리 확보할 수 있어 INSERT를 flush까지 미루고 배칭할 수 있다 — 배칭이 목적이면 IDENTITY를 피하는 이유다.

## 검증

Hibernate User Guide의 flushing 챕터와 `ActionQueue` 소스의 순서 정의를 따라가 위 8단계를 확인했고, 아래 재현 흐름으로 오작동을 관찰할 수 있다.

```java
// Post.slug 에 UNIQUE 제약이 있다고 하자.
Post old = em.find(Post.class, 1L);   // slug = "hello"
em.remove(old);                        // → EntityDeleteAction 큐잉 (아직 DELETE 안 나감)

Post fresh = new Post();
fresh.setSlug("hello");                // 같은 unique 값
em.persist(fresh);                     // → EntityInsertAction 큐잉

// 커밋 flush: 순서상 INSERT(2)가 DELETE(8)보다 먼저 실행됨
// → INSERT "hello" 시점에 옛 row가 아직 살아있어 UNIQUE 위반
// SQLIntegrityConstraintViolation: unique constraint SLUG_UQ
```

우회책: `em.remove(old); em.flush();` 로 DELETE를 강제로 먼저 내보내면 통과한다 — 다만 이는 write-behind/배칭 이점을 버리는 코드 스멜이다. 애초에 지우고-다시-넣기보다 **기존 row를 update** 하는 편이 인덱스·라운드트립 면에서 낫다(Vlad Mihalcea).

## 잘못 알고 있던 것

- **"내가 부른 순서대로 SQL이 나간다."** 아니다. flush는 호출 순서를 버리고 액션 **타입 우선순위**(INSERT→…→DELETE)로 재배열한다. 한 트랜잭션 안에서 delete-then-insert가 필요하면 순서가 뒤집힌다.
- **"batch_size만 켜면 INSERT가 배칭된다."** IDENTITY 전략에서는 `persist` 즉시 INSERT가 나가서 배칭이 안 된다. 또 여러 엔티티 타입이 섞이면 `order_inserts` 없이는 batch가 매번 깨진다.
- **"flush() = commit."** flush는 큐를 SQL로 내보내는 동기화일 뿐, 커밋이 아니다. flush 후에도 롤백 가능하다.

## 더 파고들 만한 것

- `InsertActionSorter`의 위상정렬 구현과 순환 FK 의존일 때의 처리.
- auto-flush(`FlushModeType.AUTO`)가 JPQL 실행 전 어떤 테이블 오염을 감지해 flush를 트리거하는지.

## 참고

- Hibernate ORM User Guide — Flushing / JDBC Batch Settings (`order_inserts`, `order_updates`, `jdbc.batch_size`)
- Hibernate 소스 `ActionQueue` (OrderedActions, executeActions)
- Vlad Mihalcea, "A beginner's guide to Hibernate flush operation order"
