# @Transactional 전파 속성 7가지의 실제 흐름

> **Primary source:** Spring Framework Reference §17, `org.springframework.transaction.support.AbstractPlatformTransactionManager` 소스
> **Secondary:** `TransactionDefinition` Javadoc, `DataSourceTransactionManager` 소스
> **Date:** 2026-05-25
> **Status:** draft

## 왜 봤나

- `REQUIRES_NEW` 안쪽이 예외를 던졌는데 바깥까지 롤백된 사례를 디버깅했다.
- 7가지를 외우긴 했지만 **언제 새 Connection이 잡히는지 / 언제 SAVEPOINT가 찍히는지**를 코드 레벨로 정리한 적이 없었다.

## 핵심 한 문장

> 전파 속성은 `AbstractPlatformTransactionManager.getTransaction()` 한 메서드의 분기이며, 결정 변수는 **현재 트랜잭션이 활성인가**와 **propagation 값** 두 개뿐이다.

## 내부 동작

분기는 **기존 트랜잭션이 있는가**로 갈린다 (Spring Reference §17.5.7).

```
getTransaction(def)
├─ doGetTransaction()                  // PlatformTM별 tx 객체
└─ isExistingTransaction(tx)?
    ├─ YES → handleExistingTransaction()
    │   NEVER         → IllegalTransactionStateException
    │   NOT_SUPPORTED → suspend(tx), 비-tx
    │   REQUIRES_NEW  → suspend(tx), doBegin(newTx)
    │   NESTED        → createSavepoint() (기본)
    │   REQUIRED/SUPPORTS/MANDATORY → 참여
    └─ NO
        MANDATORY → 예외
        REQUIRED/REQUIRES_NEW/NESTED → doBegin()
        SUPPORTS/NOT_SUPPORTED/NEVER → 비-tx
```

### ThreadLocal 자료구조

`TransactionSynchronizationManager`는 ThreadLocal `Map<Object,Object> resources`를 가지고, `DataSourceTransactionManager.doBegin()`이 `DataSource → ConnectionHolder`를 그 맵에 bind한다. **활성 트랜잭션의 본체 = ThreadLocal의 ConnectionHolder**. `suspend(tx)`는 ThreadLocal들을 꺼내 `SuspendedResourcesHolder`에 담아 두고, 끝나면 `resume()`에서 다시 bind한다. `REQUIRES_NEW`는 suspend 후 새 Connection으로 `doBegin()`을 또 호출 — **물리적으로 다른 Connection**.

### NESTED

같은 Connection 위에 `SAVEPOINT`를 찍는다 (`useSavepointForNestedTransaction()` 기본 true). 부분 롤백은 되지만 바깥이 롤백되면 같이 사라진다. JDBC `Savepoint`에 의존하고, JPA에서는 `JpaTransactionManager`가 `nestedTransactionAllowed=false`라 자주 막힌다.

## 검증

```java
@Transactional
public void run() {                              // Outer
    Connection c1 = DataSourceUtils.getConnection(ds);
    inner.newTx(c1);
}

@Transactional(propagation = Propagation.REQUIRES_NEW)
public void newTx(Connection outer) {            // Inner
    Connection c2 = DataSourceUtils.getConnection(ds);
    assert outer != c2;                          // 다른 Connection
    throw new RuntimeException("boom");          // 호출부가 안 잡으면 바깥도 rollback-only
}
```

`handleExistingTransaction`의 `PROPAGATION_REQUIRES_NEW` 분기에서 `suspend` → `doBegin` 순서로 호출된다.

## 잘못 알고 있던 것

- "REQUIRES_NEW 안의 예외는 바깥과 무관" — **틀림**. 예외가 바깥으로 전파되면 바깥도 `rollback-only` 마킹된다. 끊으려면 호출부에서 try/catch.
- "NESTED = REQUIRES_NEW" — 다르다. NESTED는 같은 Connection의 SAVEPOINT, REQUIRES_NEW는 별도 Connection + 별도 물리 트랜잭션.

## 더 파고들 만한 것

- [[aop-jdk-vs-cglib]] — `@Transactional`의 self-invocation 한계.
- `JpaTransactionManager`의 `EntityManager` 바인딩 vs `DataSourceTransactionManager`.

## 참고

- Spring Framework Reference §17.5.7 Transaction Propagation
- `AbstractPlatformTransactionManager`: `getTransaction`, `handleExistingTransaction`, `suspend`
- `DataSourceTransactionManager#doBegin`
