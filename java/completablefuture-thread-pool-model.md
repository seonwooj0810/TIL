# CompletableFuture 스레드 풀 모델: 어느 스레드가 콜백을 실행하는가

> **Primary source:** Java SE 21 API docs (`java.util.concurrent.CompletableFuture`); OpenJDK 21 `CompletableFuture.java` 소스; `ForkJoinPool.commonPool()` docs
> **Secondary:** JEP 266 (More Concurrency Updates, CompletableFuture 도입 배경); Doug Lea, "A Java Fork/Join Framework" (2000)
> **Date:** 2026-05-30
> **Status:** draft

## 왜 봤나

- `thenApply` vs `thenApplyAsync`를 "동기/비동기" 정도로만 구분하고, **실제로 어느 스레드가 콜백을 실행하는지**를 따져본 적이 없었다.
- `supplyAsync(() -> ...)`에 executor를 안 넘기면 어디서 돌까? "어딘가 풀에서"라고만 알았는데, 그 "어딘가"가 `ForkJoinPool.commonPool()`이고 **CPU 코어가 1개면 동작이 완전히 달라진다**는 걸 몰랐다.
- 콜백 체인이 내부적으로 어떤 자료구조에 쌓이는지(Treiber stack) 따라가 보고 싶었다.

## 핵심 한 문장

> `*Async` 메서드는 명시된 executor(없으면 `defaultExecutor()` = 보통 `ForkJoinPool.commonPool()`)에 콜백을 제출하고, **비-Async 메서드는 별도 스레드를 쓰지 않고 "future를 완료시킨 스레드" 또는 "이미 완료됐다면 호출한 스레드"가 직접 실행**한다 — 콜백들은 lock-free Treiber stack에 LIFO로 쌓였다가 완료 시점에 발화(fire)된다.

## 내부 동작

### 1) 세 가지 메서드 변형과 실행 스레드

거의 모든 단계 메서드는 3종 오버로드를 가진다. 실행 스레드 규칙은 다음과 같다.

```
변형                         실행 스레드
--------------------------- ------------------------------------------
thenApply(fn)               완료 시점이 미래 → 완료시키는 스레드가 실행
  (비-Async)                이미 완료됨     → thenApply를 호출한 스레드가 실행
thenApplyAsync(fn)          defaultExecutor()에 제출
thenApplyAsync(fn, exec)    명시한 exec에 제출
```

핵심 함정: **비-Async 콜백의 실행 스레드는 "타이밍에 따라" 달라진다.** 소스의 `uniApplyStage`를 따라가면:

```java
private <V> CompletableFuture<V> uniApplyStage(Executor e, Function<...> f) {
    CompletableFuture<V> d = newIncompleteFuture();
    if (e != null || !d.uniApply(this, f, null)) {  // ← e==null이면 즉시 시도
        UniApply<T,V> c = new UniApply<>(e, d, this, f);
        push(c);            // 아직 완료 안 됨 → 스택에 push
        c.tryFire(SYNC);    // push 직후 다시 시도(경쟁 보정)
    }
    return d;
}
```

- `e == null`(비-Async)이고 소스가 **이미 완료**면 → `uniApply`가 그 자리에서 `true`를 반환하며 **호출 스레드가 즉시 실행**.
- 아직 미완료면 → Completion 노드를 **스택에 push**하고, 나중에 소스를 완료시키는 스레드가 발화시킨다.

### 2) 콜백 저장소 — Treiber stack (lock-free)

`CompletableFuture`의 핵심 필드는 둘뿐이다:

```java
volatile Object result;       // null=미완료, 그 외=결과(또는 AltResult)
volatile Completion stack;    // 의존 콜백들의 lock-free LIFO 스택의 top
```

`Completion`은 다음 노드를 가리키는 `next` 필드를 가진 **침투형(intrusive) 노드**다. 여러 스레드가 동시에 `thenApply`를 걸면 CAS로 top을 교체하며 push한다(Treiber stack):

```
push(c):  do { c.next = stack; } while (!STACK.compareAndSet(this, c.next, c));
```

```
    완료 전 콜백 등록 상태
    stack(top) ─▶ [UniApply] ─▶ [UniAccept] ─▶ null
                    next           next
    result = null   ← 아직 미완료
```

소스가 완료되면 `result`를 CAS로 채운 뒤 `postComplete()`가 스택을 **pop하며 각 Completion의 `tryFire`를 호출**한다. LIFO이므로 **등록 역순으로 발화**된다(같은 의존이면 순서 보장 안 함이 정확).

### 3) `defaultExecutor()` — commonPool, 그리고 코어 1개의 함정

`*Async`에 executor를 안 주면 `defaultExecutor()`가 쓰인다. 소스의 정적 필드:

```java
private static final boolean USE_COMMON_POOL =
    (ForkJoinPool.getCommonPoolParallelism() > 1);

private static final Executor ASYNC_POOL = USE_COMMON_POOL
    ? ForkJoinPool.commonPool()
    : new ThreadPerTaskExecutor();   // 매 작업마다 새 스레드!
```

- 공식 docs에 따르면 commonPool의 기본 병렬도는 `Runtime.availableProcessors() - 1`이다.
- 따라서 **vCPU가 1개인 환경(작은 컨테이너 등)에서는 병렬도가 0 또는 1**이 되고, `USE_COMMON_POOL`이 `false`가 되어 **작업마다 새 스레드를 만드는 `ThreadPerTaskExecutor`로 폴백**한다. 풀링 이점이 사라지므로 별도 executor를 명시하는 게 안전하다.

### 4) 실행 모드 — SYNC / ASYNC / NESTED

`tryFire(int mode)`는 세 모드로 호출된다(소스 상수 `SYNC=0, ASYNC=1, NESTED=-1`).

```
SYNC   : 등록 시점/완료 시점에 호출 스레드가 직접 실행 (비-Async 경로)
ASYNC  : 이미 executor 스레드 안 → 그 스레드가 그대로 실행
NESTED : postComplete 연쇄 중 스택 깊이 폭주를 막기 위한 모드
         (자기 자신을 재귀 발화하지 않고 호출자에게 반환해 루프로 처리)
```

`NESTED`는 긴 콜백 체인에서 `postComplete → tryFire → postComplete → ...` 재귀로 **스택 오버플로**가 나는 것을 막으려고, 발화를 호출 스택이 아니라 **루프로 평탄화**하는 장치다.

## 검증

소스 흐름 + 간단한 코드로 "비-Async 콜백 스레드가 타이밍 의존"임을 확인.

```java
// 케이스 A: 이미 완료된 future에 비-Async 콜백 → 호출 스레드(main)가 실행
CompletableFuture<String> done = CompletableFuture.completedFuture("x");
done.thenApply(s -> {
    System.out.println("A thread = " + Thread.currentThread().getName());
    return s;                       // 출력: A thread = main
});

// 케이스 B: 미완료 future → 완료시키는 스레드가 실행
CompletableFuture<String> cf = new CompletableFuture<>();
cf.thenApply(s -> {
    System.out.println("B thread = " + Thread.currentThread().getName());
    return s;                       // 출력: B thread = pool-1-thread-1 (complete를 부른 쪽)
});
Executors.newSingleThreadExecutor().submit(() -> cf.complete("y"));
```

- A는 등록 시점에 이미 `result != null`이라 `uniApply`가 즉시 `true` → main 실행.
- B는 등록 시 미완료라 스택에 쌓였다가, 다른 스레드의 `complete("y")` → `postComplete()`가 그 스레드 위에서 콜백을 발화.

→ **비-Async 콜백을 "항상 백그라운드"로 착각하면, 무거운 작업이 의도치 않게 main이나 완료 스레드(예: Netty I/O 스레드)를 점유**할 수 있다.

## 잘못 알고 있던 것

- "`thenApply`는 비동기니까 별도 스레드에서 돈다" → **틀림.** 별도 스레드를 보장하는 건 `*Async`뿐이다. 비-Async는 완료/호출 스레드를 그대로 빌려 쓴다.
- "executor 안 주면 항상 commonPool 스레드 풀" → **항상은 아님.** 병렬도 ≤ 1이면 작업마다 새 스레드(`ThreadPerTaskExecutor`)로 폴백한다.
- "콜백은 등록 순서대로 실행된다" → 내부가 Treiber **스택(LIFO)** 이라 등록 역순에 가깝게 발화된다. 동일 소스에 건 여러 의존 간 순서는 의존하면 안 된다.

## 더 파고들 만한 것

- `ForkJoinPool`의 work-stealing 큐 구조와 commonPool 동작(왜 병렬도 = 코어-1인가).
- `CompletableFuture`의 예외 전파: `AltResult` 래핑, `CompletionException` vs `ExecutionException`의 경계.

## 참고

- Java SE 21 API docs — `CompletableFuture`, `ForkJoinPool#commonPool`.
- OpenJDK 21 `CompletableFuture.java` (`uniApplyStage`, `postComplete`, `ASYNC_POOL`).
- JEP 266 — More Concurrency Updates.
