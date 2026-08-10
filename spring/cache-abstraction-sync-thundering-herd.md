# Spring 캐시 추상화의 sync=true: computeIfAbsent 원자적 로딩과 그 한계

> **Primary source:** Spring Framework 소스 `org.springframework.cache.interceptor.CacheAspectSupport` / `org.springframework.cache.concurrent.ConcurrentMapCache` (spring-framework GitHub, main 브랜치)
> **Secondary:** Spring Data Redis 소스 `org.springframework.data.redis.cache.RedisCache` / Spring Framework Reference Docs — Cache Abstraction
> **Date:** 2026-08-10
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/redis-cache-sync-thundering-herd

## 왜 봤나

`@Cacheable(sync = true)`는 레퍼런스 문서에 "동시 호출 시 로더가 한 번만 실행되도록 보장한다" 정도로만 짧게 언급되고, 그 보장이 스프링 자체의 락인지 캐시 구현체의 락인지가 문서만으로는 드러나지 않는다. "어떤 캐시 백엔드를 쓰든 원본 조회는 무조건 한 번만 나간다"는 흔한 오해도 여기서 풀린다 — 보장의 강도는 **캐시 구현체가 무엇이냐에 따라 완전히 달라진다.**

## 핵심 한 문장

> `sync=true`는 스프링이 자체 락으로 "한 번만 실행"을 보장하는 기능이 아니라, `Cache.get(Object key, Callable<T> valueLoader)`라는 **계약을 캐시 구현체에게 떠넘기는** 스위치이고, 이 계약을 실제로 지키는지는 구현체마다 다르다.

## 내부 동작

### 1. 두 개의 실행 경로

`CacheAspectSupport.execute()`는 메서드에 걸린 캐시 애노테이션들을 모아 `CacheOperationContexts`를 만들고, 이 컨텍스트가 "동기화가 필요한 상태인지"를 판단해 두 경로로 갈린다.

- 기본 경로: `evaluate()` → 조건 평가 → `findCachedValue()` / `findInCaches()`로 **일반 조회**(`doGet(cache, key)`, `Cache.ValueWrapper` 반환) → 미스면 `invokeOperation()` 실행 → 이후 별도로 `doPut(cache, key, value)`.
- sync 경로: `executeSynchronized()` — `CacheOperationContexts.isSynchronized()`가 true일 때만 진입.

두 경로를 가르는 게이트가 `determineSyncFlag(Method method)`이며, 여기서 sync 사용을 매우 좁게 제한한다. 실제 검증 로직(직접 확인):

```java
if (syncEnabled) {
    if (this.contexts.size() > 1) {
        throw new IllegalStateException(
            "A sync=true operation cannot be combined with other cache operations on '" + method + "'");
    }
    if (cacheableContext.getCaches().size() > 1) {
        throw new IllegalStateException(
            "A sync=true operation is restricted to a single cache on '" + operation + "'");
    }
    // ...유사한 방식으로 "@Cacheable 하나만", "unless 미지원"도 검증
}
```

즉 sync=true는 네 조건을 **모두** 요구한다: (1) 같은 메서드에 다른 캐시 오퍼레이션(`@CachePut`, `@CacheEvict`) 결합 금지, (2) `@Cacheable`이 메서드당 하나만, (3) 캐시도 하나만, (4) `unless` 속성 미지원. 어기면 빈 초기화 시점이 아니라 **호출 시점에 `IllegalStateException`**이 던져진다.

### 2. sync 경로가 실제로 하는 일

조건을 통과하면 `executeSynchronized()`는 단일 캐시·단일 키를 골라 다음으로 좁혀진다(직접 확인한 핵심 분기):

```java
try {
    return wrapCacheValue(method, doGet(cache, key, () -> unwrapReturnValue(invokeOperation(invoker))));
}
catch (Cache.ValueRetrievalException ex) {
    ReflectionUtils.rethrowRuntimeException(ex.getCause());
    return null;
}
```

`doGet(cache, key, supplier)`은 내부적으로 `Cache.get(Object key, Callable<T> valueLoader)`를 호출한다. 이 메서드 자바독(직접 확인): "If possible, implementations should ensure that the loading operation is synchronized so that the specified `valueLoader` is only called once in case of concurrent access on the same key." 핵심은 **"if possible" / "should"** — 스프링이 강제하는 불변식이 아니라 **각 `Cache` 구현체에게 위임된 권고 계약**이다(예외는 `ValueRetrievalException`으로 래핑, `@since 4.3`).

### 3. 계약을 실제로 지키는 구현: ConcurrentMapCache

인메모리 구현 `ConcurrentMapCache.get(key, valueLoader)`의 실제 코드(직접 확인):

```java
@Override
public <T> T get(Object key, Callable<T> valueLoader) {
    return (T) fromStoreValue(this.store.computeIfAbsent(key, k -> {
        try {
            return toStoreValue(valueLoader.call());
        }
        catch (Throwable ex) {
            throw new ValueRetrievalException(key, valueLoader, ex);
        }
    }));
}
```

`ConcurrentHashMap.computeIfAbsent`는 대상 키가 매핑되는 버킷(bin)에 대해 원자적으로 동작한다 — 같은 키로 동시에 들어온 스레드 중 하나만 매핑 함수(`valueLoader.call()`)를 실행하고, 나머지는 그 버킷에서 대기하다 동일한 결과를 받는다. 이게 자바독이 말한 "loader called once"가 **실제로 구현된** 사례다: A가 bin lock을 선점해 원본 조회를 1회 실행하고, B·C는 같은 bin에서 대기하다 A의 결과를 그대로 받는다.

### 4. 계약이 약해지는 구현: RedisCache

분산 캐시인 `RedisCache.get(key, valueLoader)`의 실제 코드(직접 확인, 시그니처 축약):

```java
public <T> T get(Object key, Callable<T> valueLoader) {
    byte[] binaryValue = getCacheWriter().get(getName(), createAndConvertCacheKey(key),
            () -> serializeCacheValue(toStoreValue(loadCacheValue(key, valueLoader))),
            getTimeToLive(key), getCacheConfiguration().isTimeToIdleEnabled());
    ValueWrapper result = toValueWrapper(deserializeCacheValue(binaryValue));
    return result != null ? (T) result.get() : null;
}
```

`RedisCache` 자신은 `synchronized` 블록도 락 객체도 갖지 않는다. "로더를 한 번만 실행하라"는 책무를 `RedisCacheWriter.get(...)` 한 단계 더 아래로 넘길 뿐이다. 여러 JVM 인스턴스가 같은 키로 동시에 미스를 겪으면, `RedisCacheWriter`가 실제로 분산 락(예: 원자적 `SET NX`류 연산)을 걸지 않는 한 **여러 인스턴스가 동시에 원본 조회를 실행할 수 있다.** `RedisCacheWriter`가 실제로 그런 락을 거는지는 이번 노트에서 확인하지 못했다 — 다음 노트 후보로 남긴다.

### 5. sync 없이 쓰면 왜 문제인가 (check-then-act)

기본 경로(`findCachedValue`/`findInCaches`)는 "조회 후 미스면 계산 후 put"을 **하나의 원자적 연산이 아니라 두 단계**로 수행한다:

```
[sync 없음]  A,B,C 모두 doGet(cache,key) → MISS (A가 아직 put 전이라 다같이 미스)
             → 셋 다 invokeOperation() 실행 (원본 조회 3회, thundering herd)
             → 셋 다 doPut(cache,key,value)
```

이 check-then-act 사이의 창(window)이 "캐시 스탬피드"의 원인이고, `sync=true`는 이 창을 캐시 구현체의 원자적 연산(있다면)으로 없애기 위한 스위치다.

## 검증

이 저장소엔 실행 환경이 없으므로, 아래 두 가지로 직접 재현·확인할 수 있다.

**(a) 소스 직접 확인** — 인용 코드 경로: `spring-projects/spring-framework`의 `spring-context/.../cache/interceptor/CacheAspectSupport.java`(`executeSynchronized`, `determineSyncFlag`)와 `.../cache/concurrent/ConcurrentMapCache.java`(`get`), `spring-projects/spring-data-redis`의 `.../cache/RedisCache.java`(`get`).

**(b) `ConcurrentHashMap.computeIfAbsent`의 단일 실행 보장을 순수 JDK로 재현** — `ConcurrentMapCache`가 기대는 것과 동일한 메커니즘:

```java
var store = new java.util.concurrent.ConcurrentHashMap<String, String>();
var loaderCalls = new java.util.concurrent.atomic.AtomicInteger();
var pool = java.util.concurrent.Executors.newFixedThreadPool(8);
var start = new java.util.concurrent.CountDownLatch(1);
for (int i = 0; i < 8; i++) {
    pool.submit(() -> {
        try { start.await(); } catch (InterruptedException ignored) {}
        store.computeIfAbsent("k", k -> {
            loaderCalls.incrementAndGet();
            try { Thread.sleep(50); } catch (InterruptedException ignored) {}
            return "loaded-value";
        });
    });
}
start.countDown();
pool.shutdown();
pool.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS);
System.out.println("loader calls = " + loaderCalls.get()); // 항상 1
```

8개 스레드가 동시에 같은 키로 진입해도 `loader calls`는 항상 1이다. `sync=true` + `ConcurrentMapCache` 조합이 실제로 보장하는 동작과 동일하다 — `computeIfAbsent`가 버킷 단위로 배타적이라 스레드 수를 늘려도 결과는 바뀌지 않는다.

## 잘못 알고 있던 것

- **오해 1: "sync=true면 분산 환경에서도 원본 조회가 무조건 한 번만 나간다."** → 그 보장은 캐시 구현체에 위임된 계약이라, `ConcurrentMapCache`처럼 로컬 자료구조 기반 구현에서만 강하게 성립한다. `RedisCache`는 자체 락 없이 `RedisCacheWriter`로 책무를 더 넘기므로, 여러 인스턴스 환경에서 "한 번만"이 자동 보장된다고 단정할 수 없다.
- **오해 2: "sync=true는 옵션 하나 더 켜는 것이라 아무 데나 붙여도 된다."** → `determineSyncFlag`가 다른 캐시 오퍼레이션 결합, 여러 `@Cacheable`, 여러 캐시, `unless` 사용을 모두 `IllegalStateException`으로 막는다. 어기면 컴파일 타임이 아니라 **런타임 첫 호출 시점**에 실패한다.

## 더 파고들 만한 것

- `RedisCacheWriter.get(...)`이 실제로 원자적 연산(Lua 스크립트, `SET ... NX` 등)을 쓰는지, 아니면 무보호 상태인지.
- `CaffeineCache`는 Caffeine의 `LoadingCache`/`AsyncLoadingCache`로 sync 로딩을 어떻게 구현하며 `computeIfAbsent` 방식과 무슨 차이가 있는지.

## 참고

- Spring Framework Reference Docs — Cache Abstraction
- Spring Data Redis 소스 `RedisCache` / `RedisCacheWriter`

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
