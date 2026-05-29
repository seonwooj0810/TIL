# synchronized vs ReentrantLock: 내부 차이

> **Primary source:** JLS SE 21 §17.1 (Monitors), §17.4 (Memory Model); `java.util.concurrent.locks.AbstractQueuedSynchronizer` 소스 (OpenJDK 21), `ReentrantLock` 소스
> **Secondary:** Doug Lea, "The java.util.concurrent Synchronizer Framework" (PODC 2004); HotSpot `synchronizer.cpp` / `objectMonitor.cpp`; JEP 374 (Biased Locking 제거)
> **Date:** 2026-05-29
> **Status:** draft

## 왜 봤나

- "둘 다 상호배제인데 ReentrantLock이 기능이 더 많다" 정도로만 알고 있었다.
- 정작 **`synchronized`가 JVM 내부에서 어떻게 락을 거는지**(mark word, monitor inflation)와 **`ReentrantLock`이 어떤 자료구조로 대기 스레드를 줄 세우는지**(AQS의 CLH 큐)를 따라가 본 적이 없었다.
- "공정성(fairness)", "tryLock", "interruptible"이 왜 `synchronized`로는 안 되고 `ReentrantLock`으로는 되는지 — 그 차이가 **구현 위치(바이트코드/JVM vs 라이브러리/AQS)** 에서 온다는 걸 명확히 하고 싶었다.

## 핵심 한 문장

> `synchronized`는 **JVM이 객체 헤더(mark word)와 ObjectMonitor로 제공하는 내장 모니터 락**이고, `ReentrantLock`은 **`AbstractQueuedSynchronizer`의 `volatile int state` + CLH 기반 대기 큐로 구현된 순수 자바 라이브러리 락**이다 — 같은 상호배제·재진입 의미를 주지만 구현 계층과 제어 가능성이 다르다.

## 내부 동작

### 1) `synchronized` — 객체 모니터

자바 모든 객체는 **모니터(monitor)** 를 가진다 (JLS §17.1). `synchronized` 블록은 컴파일하면 `monitorenter` / `monitorexit` 바이트코드 쌍이 된다 (메서드 레벨은 `ACC_SYNCHRONIZED` 플래그로 처리).

락 상태는 객체 헤더의 **mark word**에 인코딩된다. HotSpot 64비트 기준 mark word 레이아웃(`markWord.hpp`):

```
mark word (64-bit) — 락 상태에 따라 의미가 바뀜
+--------------------------------------------------+------+
| 상태             | 상위 비트                      | tag  |
+------------------+-------------------------------+------+
| Unlocked(normal) | hashCode(31) | age(4) | ...     | 01   |
| Lightweight lock | ptr to lock record (stack)     | 00   |
| Heavyweight lock | ptr to ObjectMonitor           | 10   |
| (Biased — 제거됨) | thread ID                      | 101  |  ← JDK 18+ 기본 제거(JEP 374)
+------------------+-------------------------------+------+
```

락 획득은 단계적으로 **부풀려진다(inflation)**:

```
[무경합]      Lightweight (CAS로 stack의 lock record를 mark word에 설치)
   │ 경합 발생 (다른 스레드가 이미 보유)
   ▼
[경합]        Inflate → ObjectMonitor 생성, mark word는 monitor 포인터(tag 10)
   │
   ▼
[Heavyweight] ObjectMonitor의 _owner / _EntryList / _WaitSet로 OS 수준 블로킹
```

- **Lightweight locking**: 경합이 없으면 OS 뮤텍스 없이 CAS 한 번으로 끝난다. 보유 스레드의 스택에 lock record를 만들고 그 주소를 mark word에 CAS로 심는다.
- **Inflation → Heavyweight**: 경합이 생기면 `ObjectMonitor`(`objectMonitor.hpp`)가 할당된다. 핵심 필드:
  - `_owner`: 현재 보유 스레드
  - `_recursions`: 재진입 횟수 (같은 스레드가 다시 들어오면 +1, 그래서 `synchronized`도 **재진입 가능**)
  - `_EntryList` / `_cxq`: 락을 기다리는 스레드 큐
  - `_WaitSet`: `wait()` 호출로 대기 중인 스레드 집합
- Heavyweight 단계에서 대기는 결국 OS 스케줄러에 위임(park)된다.
- **Biased locking은 JDK 18에서 기본 비활성·이후 제거**되었다(JEP 374). "한 스레드만 반복 진입하면 CAS도 생략" 최적화였는데, 현대 워크로드에서 이득 대비 유지비가 커서 빠졌다 — 예전 자료를 그대로 믿으면 안 되는 부분.

### 2) `ReentrantLock` — AQS와 CLH 큐

`ReentrantLock`은 JVM 기능이 아니라 **`java.util.concurrent.locks` 라이브러리**다. 내부에 `Sync extends AbstractQueuedSynchronizer`를 둔다. AQS의 본질(Doug Lea, PODC 2004):

> **하나의 `volatile int state` + FIFO 대기 큐**로 동기화기를 만든다. `state`의 의미는 서브클래스가 정한다.

`ReentrantLock`에서 `state`의 의미 = **락 보유(재진입) 횟수**. 0이면 free, 1 이상이면 보유 중이고 그 값이 재진입 깊이다.

```
AQS state (volatile int)
  0  → unlocked
  1  → 한 번 획득
  n  → 같은 스레드가 n번 재진입 (그래서 "Reentrant")
```

대기 스레드는 **CLH 변형 큐**(이중 연결 리스트)에 노드로 줄 선다:

```
AQS sync queue (CLH variant)  ── head는 "현재 락 보유/막 넘겨받은" 더미
  head → [Node A] ⇄ [Node B] ⇄ [Node C] ← tail
          (waiting) (waiting) (waiting)
  각 Node: { prev, next, thread, waitStatus(SIGNAL 등) }
```

비공정(non-fair) 락의 획득 흐름 (`NonfairSync.tryAcquire` → `nonfairTryAcquire`):

```java
final boolean nonfairTryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState();
    if (c == 0) {                          // 락이 비어 있으면
        if (compareAndSetState(0, acquires)) {  // CAS로 선점 시도
            setExclusiveOwnerThread(current);
            return true;
        }
    } else if (current == getExclusiveOwnerThread()) {  // 내가 이미 보유 → 재진입
        int nextc = c + acquires;
        if (nextc < 0) throw new Error("Maximum lock count exceeded");
        setState(nextc);                   // volatile write, CAS 불필요(소유자 단독)
        return true;
    }
    return false;                          // 실패 → AQS가 큐에 enqueue + park
}
```

획득 실패 시 AQS의 `acquire()`가 노드를 큐에 넣고 `LockSupport.park()`로 스레드를 잠재운다. 해제(`release` → `tryRelease`)는 `state`를 줄이고 0이 되면 후속 노드를 `unpark`한다.

**공정성**: `FairSync.tryAcquire`는 `c == 0`일 때 바로 CAS 하지 않고 `hasQueuedPredecessors()`로 **앞에 더 오래 기다린 스레드가 있는지** 먼저 확인한다. 있으면 양보 → FIFO 보장. 비공정 락은 이 검사를 생략해 새치기를 허용(throughput↑).

### 3) 메모리 모델(happens-before)

둘 다 JMM(JLS §17.4)의 **happens-before**를 보장한다:

- `synchronized`: 한 모니터의 unlock은 그 모니터의 후속 lock보다 happens-before (JLS §17.4.4). 락 안에서 쓴 값이 다음 락 획득 스레드에 보인다.
- `ReentrantLock`: AQS의 `state`가 `volatile`이라, `release`의 `state` write가 `acquire`의 `state` read에 happens-before. **volatile 읽기/쓰기 규칙으로 동일한 가시성**을 얻는다 — 락 기능을 평범한 volatile + CAS로 재구성할 수 있다는 게 AQS 설계의 요점.

### 4) 기능·구현 비교

| 항목 | `synchronized` | `ReentrantLock` |
| --- | --- | --- |
| 구현 계층 | JVM (바이트코드 + ObjectMonitor) | 라이브러리 (AQS, 순수 자바) |
| 상태 저장 | 객체 mark word / ObjectMonitor | `volatile int state` |
| 재진입 | 가능 (`_recursions`) | 가능 (`state` 증가) |
| 공정성 선택 | 불가 (항상 비공정에 가까움) | `new ReentrantLock(true)`로 공정 가능 |
| tryLock / 타임아웃 | 불가 | `tryLock()`, `tryLock(t, unit)` |
| 인터럽트 대기 | 불가 (blocked 상태 interrupt 불가) | `lockInterruptibly()` |
| 조건 변수 | 객체당 1개 (`wait/notify`) | `newCondition()`로 여러 개 |
| 해제 | 블록/메서드 종료 시 자동 | **수동 `unlock()` 필수 (finally)** |

## 검증

`examples/ReentrantStateTest.java`로 재진입 시 AQS `state`가 증가하는지 확인 가능(`getHoldCount()`가 `state`를 노출):

```java
ReentrantLock lock = new ReentrantLock();
lock.lock();              // state 0 -> 1
System.out.println(lock.getHoldCount());   // 1
lock.lock();              // 재진입, state 1 -> 2
System.out.println(lock.getHoldCount());   // 2
lock.unlock();            // state 2 -> 1, 아직 보유
System.out.println(lock.isLocked());       // true
lock.unlock();            // state 1 -> 0, 해제
System.out.println(lock.isLocked());       // false
```

`synchronized`의 락 단계는 코드로 직접 보긴 어렵지만, JOL(`org.openjdk.jol`)로 객체 헤더의 mark word를 덤프하면 lock 진입 전후로 tag 비트가 `01`(unlocked) → `00`(lightweight) → `10`(monitor)로 바뀌는 것을 관찰할 수 있다(HotSpot `markWord.hpp` 정의와 일치).

흐름을 직접 따라가 본 부분: `ReentrantLock.lock()` → `Sync.lock()` → `acquire(1)`(AQS) → `tryAcquire`(서브클래스) → 실패 시 `addWaiter` + `acquireQueued` + `park`. 즉 **"무엇을 락의 획득 조건으로 볼지"만 서브클래스가 정하고, 큐잉·블로킹·웨이크업은 전부 AQS가 처리**한다.

## 잘못 알고 있던 것

- **"`synchronized`는 무조건 무겁고 OS 뮤텍스를 쓴다"** → 무경합 구간은 lightweight locking(CAS 한 번)으로 끝나고, OS 블로킹은 경합으로 inflate된 후의 heavyweight 단계에서만 일어난다.
- **"`synchronized`는 재진입이 안 된다"** → 된다. `ObjectMonitor._recursions`로 같은 스레드의 재진입을 센다. 재진입 가능은 둘의 공통점이지 차이점이 아니다.
- **"biased locking이 여전히 기본 최적화"** → JDK 18부터 기본 비활성, 이후 제거(JEP 374). 오래된 블로그를 그대로 인용하면 틀린다.
- **"`ReentrantLock`이 더 빠르다"** → 일반화 불가. 무경합/낮은 경합에선 `synchronized`의 lightweight 경로가 충분히 빠르고, JIT 최적화(락 생략·조합)도 받는다. `ReentrantLock`의 이점은 속도가 아니라 **제어(tryLock·타임아웃·인터럽트·공정성·다중 condition)** 다.

## 더 파고들 만한 것

- AQS의 공유 모드(`acquireShared`)로 만든 `Semaphore` / `CountDownLatch` / `ReentrantReadWriteLock` 내부.
- `StampedLock`의 낙관적 읽기(optimistic read)가 AQS를 쓰지 않고 어떻게 더 가벼운지.
- HotSpot의 lock elision / lock coarsening 같은 JIT 락 최적화가 `synchronized`에만 적용되는 이유.

## 참고

- JLS SE 21 §17.1, §17.4 — Monitors, Java Memory Model.
- OpenJDK `AbstractQueuedSynchronizer`, `ReentrantLock` 소스 (java.util.concurrent.locks).
- Doug Lea, "The java.util.concurrent Synchronizer Framework", PODC 2004.
- HotSpot `markWord.hpp`, `objectMonitor.hpp/.cpp`; JEP 374 (Disable and Deprecate Biased Locking).
