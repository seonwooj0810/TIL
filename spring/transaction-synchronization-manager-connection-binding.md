# Spring TransactionSynchronizationManager: @Transactional이 같은 트랜잭션 안에서 물리 커넥션 하나를 재사용하는 법

> **Primary source:** Spring Framework 소스 `TransactionSynchronizationManager` / `DataSourceUtils` / `DataSourceTransactionManager` / `AbstractPlatformTransactionManager`
> **Secondary:** Spring Framework Reference — Data Access / Transaction Management
> **Date:** 2026-07-31
> **Status:** draft

## 왜 봤나

`@Transactional` 메서드 안에서 `JdbcTemplate` 두 번, MyBatis 매퍼 한 번을 호출했는데 셋 다 **같은 커넥션·같은 트랜잭션**에서 돌았다. 커넥션을 명시적으로 넘긴 적이 없는데 어떻게 "지금 이 스레드의 트랜잭션 커넥션"을 찾아내는가? DataSource에서 매번 `getConnection()` 하는 게 아니라는 건 알겠는데, 그 공유가 어디에 저장되고 어떻게 조회되는지가 흐릿했다. `@Transactional(readOnly=true)`가 왜 성능에 영향을 주는지도 여기서 갈린다.

## 핵심 한 문장

> `@Transactional`은 트랜잭션을 시작할 때 물리 커넥션을 `ConnectionHolder`로 감싸 **`TransactionSynchronizationManager`의 스레드-로컬 Map에 DataSource를 키로 바인딩**해 두고, 이후 모든 DAO는 DataSource에서 새로 열지 않고 이 스레드-로컬을 먼저 조회해 같은 커넥션을 참조 카운트로 나눠 쓴다.

## 내부 동작

### 1. 저장소: 스레드-로컬 자료구조

`TransactionSynchronizationManager`는 상태를 전부 `static ThreadLocal`로 들고 있다. 인스턴스가 아니라 **스레드마다** 트랜잭션 컨텍스트가 산다.

```
TransactionSynchronizationManager (전부 static ThreadLocal)
 ├─ resources            : ThreadLocal<Map<Object, Object>>   ← 핵심
 │     key   = 리소스 팩토리 (보통 DataSource / EntityManagerFactory)
 │     value = 리소스 홀더  (ConnectionHolder / EntityManagerHolder)
 ├─ synchronizations     : ThreadLocal<Set<TransactionSynchronization>>
 ├─ currentTransactionName        : ThreadLocal<String>
 ├─ currentTransactionReadOnly    : ThreadLocal<Boolean>
 ├─ currentTransactionIsolationLevel : ThreadLocal<Integer>
 └─ actualTransactionActive       : ThreadLocal<Boolean>
```

`resources`가 `Map`인 이유: 한 스레드가 **여러 DataSource**(예: 주 DB + 읽기 전용 복제)에 각각 트랜잭션을 가질 수 있어서, 키(DataSource)별로 홀더를 따로 바인딩한다. 그래서 조회도 항상 "어느 DataSource냐"를 키로 한다.

### 2. 트랜잭션 시작: doBegin → bindResource

`DataSourceTransactionManager.doBegin()`이 하는 일(요지):

1. `DataSource.getConnection()`으로 물리 커넥션을 **한 번** 획득.
2. `Connection.setAutoCommit(false)` — 여기서부터 진짜 트랜잭션.
3. 격리 수준(`@Transactional(isolation=...)`)과 read-only 힌트를 커넥션에 적용.
4. 커넥션을 `ConnectionHolder`로 감싸고 `holder.setSynchronizedWithTransaction(true)`.
5. `TransactionSynchronizationManager.bindResource(dataSource, holder)` — **스레드-로컬 Map에 넣는다.**

```java
// DataSourceTransactionManager.doBegin (요지)
Connection newCon = obtainDataSource().getConnection();
txObject.setConnectionHolder(new ConnectionHolder(newCon), true);
con.setAutoCommit(false);                       // 트랜잭션 개시
// ... isolation / readOnly 적용 ...
txObject.getConnectionHolder().setSynchronizedWithTransaction(true);
TransactionSynchronizationManager.bindResource(
        obtainDataSource(), txObject.getConnectionHolder());
```

이 시점 이후, 이 스레드에서 "이 DataSource의 커넥션"을 물으면 스레드-로컬이 답을 갖고 있다.

### 3. DAO의 커넥션 조회: DataSourceUtils.getConnection

여기가 마법의 핵심이다. `JdbcTemplate`·`JdbcTransactionManager` 기반 코드·`DataSourceUtils`를 쓰는 모든 통합(MyBatis-Spring 포함)은 `dataSource.getConnection()`을 **직접 부르지 않고** `DataSourceUtils.getConnection(dataSource)`를 부른다. 그 안에서:

```java
// DataSourceUtils.doGetConnection (요지)
ConnectionHolder holder =
    (ConnectionHolder) TransactionSynchronizationManager.getResource(dataSource);
if (holder != null && (holder.hasConnection() || holder.isSynchronizedWithTransaction())) {
    holder.requested();                         // 참조 카운트 ++
    if (!holder.hasConnection()) {
        holder.setConnection(fetchConnection(dataSource));
    }
    return holder.getConnection();              // ← 트랜잭션 커넥션 재사용
}
// 바인딩된 홀더가 없다 = 트랜잭션 밖
Connection con = fetchConnection(dataSource);   // 새로 연다 (자동 커밋)
// ...
```

- 스레드-로컬에 홀더가 있으면 → **새로 열지 않고** 그 커넥션을 돌려준다. `requested()`로 참조 카운트만 올린다.
- 홀더가 없으면(트랜잭션 밖) → DataSource에서 새로 열고, autoCommit=true인 커넥션을 그때그때 쓴다.

그래서 `JdbcTemplate`을 여러 번, MyBatis 매퍼를 섞어 호출해도 전부 같은 물리 커넥션에 실린다. "커넥션을 넘겨준" 적이 없는데도 공유되는 건, 넘긴 게 아니라 **스레드-로컬에서 각자 꺼내 쓰기** 때문이다.

### 4. 참조 카운트와 릴리스

`ConnectionHolder`는 `referenceCount`를 들고 있다. DAO가 끝나면 `DataSourceUtils.releaseConnection`이 호출되는데:

```
getConnection  → holder.requested()  (count++)
releaseConnection → holder.released() (count--)
   └─ 트랜잭션에 묶인 홀더면: 실제 close 안 함 (count만 감소)
   └─ 트랜잭션 밖 커넥션이면: 바로 물리 close
```

즉 트랜잭션 안에서는 각 DAO가 `close()`를 불러도 **실제로 닫히지 않는다**. 커넥션의 진짜 생명주기는 트랜잭션 매니저가 쥐고 있고, 커밋/롤백 후 `doCleanupAfterCompletion`에서 `unbindResource(dataSource)` → autoCommit 복원 → 물리 커넥션 반환(풀로)이 일어난다.

### 5. 동기화 콜백: synchronizations

`resources`와 별개로 `synchronizations` 스레드-로컬이 있다. `TransactionSynchronization`을 등록하면 커밋/롤백 생명주기 훅에 콜백이 걸린다.

```
상태 전이와 콜백 순서 (정상 커밋 경로):
  beforeCommit(readOnly) → beforeCompletion → [물리 COMMIT] → afterCommit → afterCompletion(STATUS_COMMITTED)
롤백 경로:
  beforeCompletion → [물리 ROLLBACK] → afterCompletion(STATUS_ROLLED_BACK)
```

`@TransactionalEventListener(phase = AFTER_COMMIT)`가 바로 이 메커니즘 위에 있다 — 이벤트를 커밋이 물리적으로 끝난 뒤에야 처리하도록 `afterCommit` 콜백에 얹는다. 그래서 트랜잭션이 롤백되면 그 이벤트 리스너는 아예 실행되지 않는다.

### 6. 전파 REQUIRES_NEW = 바인딩 교체(suspend/resume)

`REQUIRES_NEW`가 "새 커넥션에서 별도 트랜잭션"이 되는 것도 이 Map 하나로 설명된다. `AbstractPlatformTransactionManager`는 새 트랜잭션을 시작하기 전에 현재 바인딩을 **suspend**한다:

```
suspend: unbindResource(dataSource) 로 현재 홀더를 떼어
         SuspendedResourcesHolder에 잠시 보관
  → doBegin 으로 새 커넥션을 열어 다시 bindResource
  → 안쪽 트랜잭션 커밋/롤백
resume: 보관해 둔 홀더를 bindResource 로 원복
```

같은 스레드지만 "지금 바인딩된 커넥션"이 잠깐 새것으로 갈렸다가 원복된다. 바깥 트랜잭션이 볼 수 없는 이유가 여기 있다 — 스레드-로컬 Map의 값이 통째로 스왑됐으니까.

## 검증

Spring 소스의 호출 사슬을 따라가면 흐름이 맞아떨어진다:
`TransactionInterceptor` → `TransactionAspectSupport.invokeWithinTransaction` → `AbstractPlatformTransactionManager.getTransaction` → `doBegin`(구현체) → `TransactionSynchronizationManager.bindResource`. 그리고 조회 쪽은 `JdbcTemplate.execute` → `DataSourceUtils.getConnection` → `TransactionSynchronizationManager.getResource`.

인라인으로 재사용을 눈으로 확인하는 방법:

```java
@Transactional
public void demo(DataSource ds) throws SQLException {
    // 트랜잭션 매니저가 이미 bindResource 해 둔 상태
    Connection c1 = DataSourceUtils.getConnection(ds);
    Connection c2 = DataSourceUtils.getConnection(ds);
    System.out.println(c1 == c2);              // true — 같은 물리 커넥션
    System.out.println(c1.getAutoCommit());    // false — 트랜잭션 중
    boolean bound = TransactionSynchronizationManager.hasResource(ds);
    System.out.println(bound);                 // true
}
// 같은 코드를 @Transactional 없이 부르면:
//   hasResource(ds) == false, 매 getConnection 이 새 커넥션(autoCommit=true)
```

`c1 == c2`가 `true`인 게 핵심 증거다 — 두 번의 조회가 스레드-로컬의 같은 `ConnectionHolder`를 거쳤다는 뜻이다.

## 잘못 알고 있던 것

- **"트랜잭션 매니저가 DAO에 커넥션을 주입해 준다"** — 아니다. 매니저는 스레드-로컬 Map에 **바인딩만** 하고, DAO는 `DataSourceUtils`로 **스스로 꺼내 간다**. 그래서 `DataSourceUtils`를 우회해 `dataSource.getConnection()`을 직접 부르면 스레드-로컬을 보지 않아 **트랜잭션 밖의 별도 커넥션**을 얻고, 그 작업은 `@Transactional` 롤백에 함께 롤백되지 않는다.
- **"`@Transactional(readOnly=true)`는 단순 힌트라 아무 일도 안 한다"** — DataSource 트랜잭션에서는 JDBC 커넥션에 read-only를 세팅하고, JPA/Hibernate 위에서는 세션의 **FlushMode를 MANUAL로 낮춰 dirty checking flush를 생략**하는 것으로 알려져 있다. 이 flush 생략이 실제 성능/스냅샷 보관 비용에 영향을 준다 — 순수 장식이 아니다.
- **"트랜잭션 안에서 `connection.close()`를 부르면 커넥션이 닫힌다"** — 트랜잭션에 묶인 홀더면 `close()`(=`releaseConnection`)는 참조 카운트만 줄일 뿐 물리적으로 닫지 않는다. 실제 반환은 커밋/롤백 뒤 매니저의 cleanup에서 일어난다.

## 더 파고들 만한 것

- `JpaTransactionManager`에서 `EntityManagerHolder`가 바인딩되는 흐름과 `readOnly`→FlushMode.MANUAL 전이의 정확한 조건.
- `@Async`나 새 스레드로 작업을 넘길 때 트랜잭션 컨텍스트가 **전파되지 않는** 이유(스레드-로컬이므로) — 그리고 그때 커넥션이 어떻게 갈리는지.

## 참고

- Spring Framework 소스: `org.springframework.transaction.support.TransactionSynchronizationManager`, `org.springframework.jdbc.datasource.DataSourceUtils`, `DataSourceTransactionManager`, `AbstractPlatformTransactionManager`.
- Spring Framework Reference — Data Access: Transaction Management / Transaction Synchronization.
- 관련 노트: [@Transactional 전파 속성 흐름](./transactional-propagation-flow.md), [Spring AOP JDK Dynamic Proxy vs CGLIB](./aop-jdk-dynamic-proxy-vs-cglib.md)
