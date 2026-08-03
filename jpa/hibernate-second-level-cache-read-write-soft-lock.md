# Hibernate 2차 캐시 READ_WRITE 전략: soft lock과 timestamp 2단계 무효화로 정합성을 지키는 법

> **Primary source:** Hibernate ORM 소스 (hibernate/hibernate-orm GitHub) `org.hibernate.cache.spi.support.AbstractReadWriteAccess`, `org.hibernate.cache.spi.access.AccessType`
> **Secondary:** `org.hibernate.action.internal.EntityUpdateAction`, `org.hibernate.cache.internal.TimestampsCacheEnabledImpl`, `org.hibernate.engine.internal.AfterTransactionCompletionProcessQueue`, `org.hibernate.cache.spi.support.SimpleTimestamper`
> **Date:** 2026-08-03
> **Status:** draft

## 왜 봤나

- 2차 캐시를 켜면 "조회가 빨라진다"는 효과만 보이지만, 실제로는 캐시와 DB 사이의 정합성 문제가 새로 생긴다. `READ_WRITE` 전략은 "읽기·쓰기를 안전하게 캐시로 처리해준다"는 인상을 주는데, 그 "안전"이 정확히 어떤 보장인지 — 진짜 락인지, 얼마나 오래 막히는지, 락을 쥔 트랜잭션이 죽으면 어떻게 되는지 — 소스 레벨에서 확인하고 싶었다.
- "쿼리 캐시는 영향받은 데이터가 바뀌면 그 결과만 무효화된다"는 것도 막연한 통념이었다. 실제 무효화 단위를 확인할 필요가 있었다.

## 핵심 한 문장

> `READ_WRITE` 2차 캐시는 DB 락이 아니라 캐시 접근 계층에만 걸리는 **soft lock**(스스로 timeout으로 풀리고 `multiplicity`로 중첩을 센다)이며, 쿼리 캐시의 무효화는 행 단위가 아니라 **그 쿼리가 건드린 테이블(space) 전체** 단위로, 게다가 트랜잭션 성공 여부와 무관하게 수행된다.

## 내부 동작

### 1. 네 가지 concurrency strategy

`org.hibernate.cache.spi.access.AccessType`은 엔티티/컬렉션 리전에 붙일 수 있는 4가지 전략을 정의한다(소스의 javadoc 그대로).

| 전략 | external name | 설명 |
| --- | --- | --- |
| `READ_ONLY` | `read-only` | 추가/삭제는 가능하지만 값을 바꿀 수 없다. |
| `READ_WRITE` | `read-write` | 추가/삭제/변경 모두 가능. 변경 중 동시 접근을 관리하기 위해 캐시 항목에 "soft" lock을 건다. |
| `NONSTRICT_READ_WRITE` | `nonstrict-read-write` | 트랜잭션 전/후에 항목을 무효화해 동시 접근을 관리. `READ_WRITE`보다 약하지만 처리량이 높을 수 있다. |
| `TRANSACTIONAL` | `transactional` | JTA 트랜잭션과 결합된 일종의 hard lock을 유지. |

이 노트는 가장 널리 쓰이면서 오해가 많은 `READ_WRITE`에 집중한다.

### 2. 캐시에 저장되는 두 가지 형태: `Item`과 `SoftLockImpl`

`AbstractReadWriteAccess`는 캐시에 넣는 값을 항상 `Lockable` 인터페이스로 감싼다. 실제 구현은 두 가지뿐이다.

- `Item(value, version, timestamp)` — 잠기지 않은 상태. `value`/`version`과 "이 항목이 캐시에 들어간 시각" `timestamp`를 들고 있다.
- `SoftLockImpl(timeout, sourceUuid, lockId, version)` — 잠긴 상태. `timeout`, 중첩 횟수 `multiplicity`(기본 1), 동시 잠금 여부 `concurrent`, 잠금이 전부 풀린 시각 `unlockTimestamp`를 들고 있다.

상태 전이는 다음과 같다.

```
     (최초 캐시 미스)
            │
            ▼
     ┌────────────┐   lockItem()    ┌──────────────┐
     │    Item    │ ──────────────► │ SoftLockImpl │
     │ (readable) │                 │ (unreadable) │
     └────────────┘ ◄────────────── └──────────────┘
            ▲          afterUpdate()/       │
            │          decrementLock()      │ lockItem() (다른 트랜잭션이 같은 키를 또 잠금)
            │          (multiplicity→0)     ▼
            │                        multiplicity++, concurrent=true
            └────────────────────────────────┘
```

### 3. 쓰기 흐름: `EntityUpdateAction` 기준 상태 전이

UPDATE가 flush될 때 `EntityUpdateAction.execute()`는 실제 `persister.update(...)`(UPDATE SQL 전송) **이전에** `lockCacheItem(previousVersion)`을 호출해 캐시 키를 `SoftLockImpl`로 바꿔둔다. 이 시점부터 다른 트랜잭션은 이 키를 `get()`으로 읽을 수 없다 — `isReadable()`이 무조건 `false`를 반환하기 때문이다.

트랜잭션 커밋/롤백 후(`doAfterTransactionCompletion`) `updateCacheIfNecessary()`가 분기한다.

- 커밋 성공 + 무효화 불필요 + `CacheMode`가 put 허용 → `cache.afterUpdate(...)`로 새 `Item`을 채워 넣는다(내부적으로 락도 해제).
- 그 외(실패, 무효화 필요, put 비활성) → `cache.unlockItem(...)`으로 락만 푼다. 다음 읽기는 캐시 미스로 DB를 다시 탄다.

"쓰기 SQL 전송 → (진행 중엔 읽기 불가) → 커밋 결과에 따라 새 값 채우기 또는 락만 해제"의 3단 파이프라인이다.

### 4. 읽기/쓰기 판정 로직

- `Item.isReadable(txTimestamp)` → `txTimestamp > timestamp`. **항목이 캐시에 들어간 시점보다 나중에 시작한 트랜잭션만** 읽을 수 있다 — 더 오래된 스냅샷을 가진 트랜잭션은 이 값을 신뢰하지 않는다.
- `SoftLockImpl.isReadable(txTimestamp)` → 항상 `false`.
- `SoftLockImpl.isWriteable(...)` → `txTimestamp > timeout`(만료 시 덮어쓰기 허용)이거나 `multiplicity == 0`(모두 unlock)인 경우만 허용한다.

### 5. timeout의 실체: `SimpleTimestamper`

`AbstractRegionFactory.nextTimestamp()`/`getTimeout()`은 `SimpleTimestamper`에 위임한다. `System.currentTimeMillis()`를 12비트 시프트한 뒤, 같은 밀리초 안의 동시 호출도 겹치지 않도록 `AtomicLong` CAS 루프로 최대 4096개의 하위 틱을 채워 반환한다 — 밀리초 해상도로는 부족한 "엄격한 증가"를 보장하는 트릭이다. `timeOut()`은 60,000ms를 같은 단위로 환산한 값(=60초). 클래스 주석은 **"단일 VM에서만 유효하다"**고 명시한다 — 카운터가 JVM 하나짜리 `AtomicLong`이기 때문이다.

### 6. 쿼리 캐시의 2단계 무효화

엔티티 캐시와 별개로, 쿼리 캐시는 "이 쿼리 결과가 지금도 최신인가"를 `TimestampsCache`(구현체 `TimestampsCacheEnabledImpl`)로 판정한다.

```
flush 중 한 종류(action type)의 SQL을 다 보낸 직후 (커밋 전)
        │
        ▼  ActionQueue.invalidateSpaces(spaces)
   preInvalidate(spaces) : region에 (space → now + timeout) 기록
        │
   ... 트랜잭션 진행, 커밋/롤백 ...
        │
        ▼  AfterTransactionCompletionProcessQueue#afterTransactionCompletion(success)
   invalidate(spaces)    : region에 (space → now) 기록  ← success 값과 무관하게 항상 실행
```

읽기 시점엔 `isUpToDate(spaces, resultTimestamp, session)`이 쿼리가 참조한 **모든 space**에 대해 "마지막 갱신 시각 >= resultTimestamp"이면 그 쿼리 결과 전체를 stale로 판정한다. 단위가 "행"이 아니라 "테이블(space)"이고, `invalidateCaches()` 호출 자체는 `success` 값과 무관하게 수행된다는 점이 핵심이다.

## 검증

이 repo엔 실행 환경이 없으므로, 독자가 직접 재현하거나 확인할 수 있는 두 경로를 남긴다.

1. **로그로 확인**: `logging.level.org.hibernate.cache=debug`를 켜면 `AbstractReadWriteAccess`가 `Locking cache item ... (timeout=..., version=...)`, `Cache hit, but item is unreadable/invalid` 같은 디버그 로그를 그대로 남긴다(위에서 인용한 문자열이 소스의 `log.debugf` 호출과 일치한다). 같은 엔티티를 두 트랜잭션에서 동시에 갱신하면서 이 로그를 관찰하면 3번 절의 3단 파이프라인이 그대로 보인다.
2. **소스로 확인**: `hibernate/hibernate-orm` GitHub 저장소의 `AbstractReadWriteAccess`, `SimpleTimestamper`, `EntityUpdateAction`, `TimestampsCacheEnabledImpl`, `AfterTransactionCompletionProcessQueue`를 열면 이 노트가 인용한 메서드/필드명이 그대로 나온다.

```java
// 실제 소스의 필드/메서드명을 유지한 축약형 재구성 (로깅·이벤트 코드 제거)
class SoftLockImpl implements Lockable {
    long timeout;
    int multiplicity = 1;
    long unlockTimestamp;

    boolean isReadable(long txTimestamp) { return false; }

    boolean isWriteable(long txTimestamp, Object newVersion, Comparator cmp) {
        if (txTimestamp > timeout) return true;     // 락 만료 → 덮어쓰기 허용
        if (multiplicity > 0) return false;          // 아직 누가 쥐고 있음
        return txTimestamp > unlockTimestamp;        // 모두 풀린 뒤 시점만 허용
    }

    void unlock(long ts) {
        if (--multiplicity == 0) unlockTimestamp = ts;
    }
}
```

## 잘못 알고 있던 것

- **"`READ_WRITE`의 락은 DB 트랜잭션 락처럼 다른 세션의 쓰기를 막는다"** → 아니다. 이 락은 캐시 접근(`DomainDataAccess`) 계층에만 있는 soft lock이다. DB엔 행 락이 걸리지 않고 다른 세션의 DB 트랜잭션도 영향받지 않는다. 영향받는 건 "그 사이 이 키를 읽으려는 요청이 캐시 미스로 DB를 다시 탄다"는 것뿐이다. 게다가 `multiplicity`로 중첩만 세고 `timeout`이 지나면 소유자 생존과 무관하게 스스로 풀린다 — 크래시로 unlock을 못 부른 트랜잭션이 캐시를 영구 잠그지 않게 한 설계다.
- **"쿼리 캐시는 실제로 바뀐 행을 담은 결과만 무효화된다"** → 아니다. `isUpToDate`는 행 단위 비교를 하지 않는다. 어떤 쓰기든 테이블(space)에 닿으면 그 테이블을 참조한 **모든** 쿼리 캐시 결과가 통째로 stale 처리된다. 이 무효화는 트랜잭션 성공 여부와도 무관하게(`success`를 무시하고 `invalidateCaches()` 호출) 실행된다 — 롤백된 쓰기도 쿼리 캐시를 비운다.

## 더 파고들 만한 것

- `NONSTRICT_READ_WRITE`/`TRANSACTIONAL`은 각각 어떤 구현으로 "락 없는 무효화"와 JTA 결합 hard-lock을 구현하는지.
- 클러스터형 2차 캐시(예: Infinispan 분산 모드)에서 `SimpleTimestamper`의 "단일 VM 전제"가 어떻게 대체되는지.

## 참고

- Hibernate ORM 소스 (hibernate/hibernate-orm GitHub): `AccessType`, `AbstractReadWriteAccess`, `SimpleTimestamper`, `EntityUpdateAction`, `TimestampsCacheEnabledImpl`, `AfterTransactionCompletionProcessQueue`, `ActionQueueLegacy`
- Hibernate ORM User Guide — Caching (RegionFactory, 2차 캐시 개요)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
