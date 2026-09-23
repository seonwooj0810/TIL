# @TransactionalEventListener(AFTER_COMMIT)는 afterCommit이 아니라 afterCompletion에서 돈다: 커밋 후 리스너의 쓰기가 사라지는 이유

> **Primary source:** Spring Framework 소스 (`main`, 2026-09-23 확인) — `TransactionalApplicationListenerMethodAdapter`, `TransactionalApplicationListenerSynchronization`, `TransactionPhase`, `AbstractPlatformTransactionManager#processCommit`/`triggerAfterCompletion`, `TransactionSynchronizationUtils`, `RestrictedTransactionalEventListenerFactory`, `DataSourceTransactionManager`
> **Secondary:** Spring Framework Reference — Transaction-bound Events, 관련 노트 [TransactionSynchronizationManager 커넥션 바인딩](./transaction-synchronization-manager-connection-binding.md)
> **Date:** 2026-09-23
> **Status:** draft

## 왜 봤나

- "커밋이 끝난 뒤 알림 발송이나 이력 저장을 하려면 `@TransactionalEventListener`를 쓰면 된다"는 조언이 흔하다. 그런데 리스너 안에서 DB에 쓰면 에러 없이 반영되지 않는 일이 생긴다. 이 동작은 공식 javadoc에 WARNING으로 적혀 있다.
- 기본 phase인 `AFTER_COMMIT`이라는 이름 때문에 `TransactionSynchronization#afterCommit()` 콜백에서 돈다고 생각하기 쉽다. 실제로는 그렇지 않고, 그 차이가 예외 전파와 리소스 상태를 가른다.

## 핵심 한 문장

> `@TransactionalEventListener`는 publish 시점에 이벤트를 현재 스레드의 `TransactionSynchronization`으로 등록해 두었다가, `BEFORE_COMMIT`이면 `beforeCommit()`에서, 나머지 세 phase는 모두 `afterCompletion(status)`에서 실행한다. 이 시점에 물리 커밋은 끝났지만 커넥션 바인딩은 아직 풀리지 않았다. 그래서 리스너의 데이터 접근은 이미 끝난 트랜잭션에 "참여"만 하고, 다시 커밋되지 않는다.

## 내부 동작

### 1. publish 시점: 실행하지 않고 등록만 한다

`onApplicationEvent`는 세 갈래다.

```
publishEvent(e)
   │
   ▼
register(e, listener, callbacks)
   ├─ isSynchronizationActive() && isActualTransactionActive()
   │     → registerSynchronization(new PlatformSynchronization(e, ...)) → true
   ├─ (reactive) event.getSource()가 TransactionContext면 reactive 매니저에 등록
   └─ 그 외 → false
         ├─ fallbackExecution=true → processEvent(e) 즉시 실행
         └─ false → "No transaction is active - skipping" (이벤트 버림)
```

- 트랜잭션 밖 publish는 기본값에서 **조용히 버려진다**(DEBUG 로그 한 줄).
- 등록 위치는 스레드-로컬 synchronization 집합이고, `getSynchronizations()`가 조회 시 `OrderComparator`로 lazily 정렬하므로 리스너 순서는 `@Order`를 따른다.

### 2. phase → 콜백 매핑 (`PlatformSynchronization`)

| TransactionPhase | 실행되는 콜백 | 조건 |
| --- | --- | --- |
| `BEFORE_COMMIT` | `beforeCommit(readOnly)` | 항상 |
| `AFTER_COMMIT` (기본) | `afterCompletion(status)` | `status == STATUS_COMMITTED` |
| `AFTER_ROLLBACK` | `afterCompletion(status)` | `status == STATUS_ROLLED_BACK` |
| `AFTER_COMPLETION` | `afterCompletion(status)` | 무조건 |

`PlatformSynchronization`은 `afterCommit()`을 오버라이드하지 않으며, `TransactionPhase` javadoc도 "(and not in `TransactionSynchronization#afterCommit()`)"라고 명시한다. `STATUS_UNKNOWN`(=2)으로 끝나면 `AFTER_COMMIT`/`AFTER_ROLLBACK` 리스너는 둘 다 돌지 않는다.

### 3. 커밋 경로의 순서 (`processCommit`)

```
prepareForCommit
triggerBeforeCommit      ← BEFORE_COMMIT 리스너 (여기서 예외 → doRollbackOnCommitException → 롤백)
triggerBeforeCompletion
doCommit                 ← 물리 COMMIT (isNewTransaction일 때만)
triggerAfterCommit       ← TransactionSynchronization#afterCommit (예외가 호출자에게 전파)
finally:
  triggerAfterCompletion(STATUS_COMMITTED)
     ├─ synchs = getSynchronizations()
     ├─ clearSynchronization()        ★ synchronization 비활성화가 먼저
     └─ invokeAfterCompletion(synchs) ← AFTER_COMMIT / AFTER_COMPLETION 리스너
finally:
  cleanupAfterCompletion
     └─ doCleanupAfterCompletion      ★ 커넥션 unbind · autoCommit 복원 · holder.clear()
```

★ 두 개 사이의 구간이 핵심이다. 리스너가 도는 동안 스레드 상태는 다음과 같다.

| 상태 | 값 | 근거 |
| --- | --- | --- |
| `isSynchronizationActive()` | false | 직전에 `clearSynchronization()` |
| DataSource → `ConnectionHolder` 바인딩 | 남아 있음 | unbind는 `doCleanupAfterCompletion`에서 |
| `ConnectionHolder.transactionActive` | true | `ConnectionHolder#clear()`가 false로 바꾸는 것도 cleanup 단계 |

`DataSourceTransactionManager#isExistingTransaction`은 `hasConnectionHolder() && isTransactionActive()`이므로, 이 구간의 `@Transactional(REQUIRED)` 호출은 "Participating in existing transaction" 경로를 탄다. 참여 트랜잭션은 `isNewTransaction()=false`라 `doCommit`에 들어가지 않고, 물리 커밋은 이미 끝났다 — javadoc 표현으로 "with no commit following anymore".

### 4. 예외는 삼켜진다

`TransactionSynchronizationUtils#invokeAfterCompletion`은 콜백마다 `catch (Throwable ex) { logger.error(...) }`로 감싸므로 `AFTER_COMMIT` 리스너 예외는 ERROR 로그로만 남는다. 반면 `invokeAfterCommit`엔 try/catch가 없어 "propagated to callers"(`processCommit` 주석)다. 이름은 비슷해도 실패 의미론이 정반대다.

### 5. 6.1+의 기동 시점 가드

`AbstractTransactionManagementConfiguration`이 등록하는 `RestrictedTransactionalEventListenerFactory`(`@since 6.1`)는 phase가 `BEFORE_COMMIT`이 아닌 리스너 메서드(또는 클래스)에 `REQUIRES_NEW`/`NOT_SUPPORTED`가 아닌 `@Transactional`이 붙으면 `IllegalStateException`을 던진다. 즉 리스너 자체에 REQUIRED를 붙이는 실수는 기동 실패로 드러나지만, 리스너가 **다른 빈의** REQUIRED 서비스를 부르는 경우는 가드에 걸리지 않고 3번의 조용한 참여가 그대로 일어난다.

## 검증

`application.yml`에 `logging.level.org.springframework.transaction: DEBUG`를 켜고 아래 코드를 실행한다.

```java
@Service
class OrderService {
    @Transactional
    public void place(Order o) {
        repo.save(o);
        publisher.publishEvent(new OrderPlaced(o.getId()));   // ① 등록만
    }
    public void placeWithoutTx(Order o) {
        publisher.publishEvent(new OrderPlaced(o.getId()));   // ② 버려짐
    }
}

@Component
class OrderListener {
    private final AuditService audit;   // audit.write()는 @Transactional(REQUIRED)

    @TransactionalEventListener      // phase = AFTER_COMMIT
    public void on(OrderPlaced e) {
        audit.write(e);              // ③ 끝난 트랜잭션에 참여
    }

    @TransactionalEventListener
    @Transactional(propagation = Propagation.REQUIRES_NEW)   // ⑤ 올바른 형태
    public void good(OrderPlaced e) { audit.write(e); }
}
```

로그에서 확인할 문자열:

- ①: `Registered transaction synchronization for`
- ②: `No transaction is active - skipping`
- ③: 리스너 구간에서 `Participating in existing transaction`. 이후 audit 쓰기에 대한 `Initiating transaction commit`이 **나오지 않는다**.
- (리스너 메서드에 직접 REQUIRED `@Transactional`을 붙이면 기동 시 `must not be annotated with @Transactional unless when declared as REQUIRES_NEW or NOT_SUPPORTED`)
- ⑤: `Suspending current transaction, creating new transaction with name`. 이어서 새 트랜잭션의 커밋 로그가 나온다.

소스로는 `triggerAfterCompletion`의 `clearSynchronization()`→`invokeAfterCompletion` 순서와, 그 뒤 `finally`의 `cleanupAfterCompletion`을 확인하면 된다.

## 잘못 알고 있던 것

- **"AFTER_COMMIT = `afterCommit()` 콜백"** → 실제로는 `afterCompletion(STATUS_COMMITTED)`. 그래서 리스너 예외는 로그로 삼켜지고 호출자는 후속 실패를 모른다.
- **"커밋이 끝났으니 리스너의 쓰기는 새 트랜잭션에서 커밋된다"** → 홀더가 아직 바인딩돼 REQUIRED는 끝난 트랜잭션에 참여하고, javadoc대로 "changes will not be committed to the transactional resource". 쓰기가 필요하면 `REQUIRES_NEW`로 새 트랜잭션을 연다.
- **"트랜잭션 밖에서 publish해도 그냥 실행된다"** → 기본값에서는 버려진다. `fallbackExecution=true`일 때만 즉시 실행된다.
- (관련 노트 `transaction-synchronization-manager-connection-binding.md`의 "`afterCommit` 콜백에 얹는다" 서술은 이 확인 결과로 정정 필요.)

## 더 파고들 만한 것

- 예외를 삼키고 크래시 시 유실되는 한계 → Spring Modulith Event Publication Registry·Outbox와 비교.
- `@Async` 조합: 스레드가 바뀌면 3번의 참여 문제가 사라지는지, 대신 무엇을 잃는지.

## 참고

- `TransactionPhase` / `TransactionSynchronization#afterCompletion` javadoc ("Use PROPAGATION_REQUIRES_NEW for any transactional operation that is called from here")
- Spring Framework Reference — Data Access › Transaction Management › Transaction-bound Events
