# 가상 스레드의 마운트/언마운트와 pinning: 블로킹이 왜 캐리어를 놓아주는가

> **Primary source:** JEP 444 (Virtual Threads) / JEP 425 (Preview) / OpenJDK `java.lang.VirtualThread`·`Continuation` 소스 (JDK 21)
> **Secondary:** Ron Pressler, "State of Loom" / JEP 491 (Synchronize Virtual Threads without Pinning)
> **Date:** 2026-07-08
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/java-virtual-threads-mount-unmount-pinning

## 왜 봤나

- "가상 스레드는 그냥 가벼운 스레드"라고만 알고 있었는데, *왜* 가벼운지 — 블로킹 호출이 어떻게 OS 스레드를 붙잡지 않고 놓아주는지 — 의 인과 사슬을 설명 못 했다.
- `synchronized` 안에서 블로킹하면 성능이 죽는다는 말을 들었는데, 그 "pinning"이 정확히 어느 지점에서 일어나는지 몰랐다.

## 핵심 한 문장

> 가상 스레드는 **힙에 저장된 재개 가능한 스택(continuation)** 이고, 블로킹 지점에서 이 스택을 캐리어(플랫폼) 스레드에서 떼어냈다가(unmount) 나중에 아무 캐리어에나 다시 붙여(mount) 실행을 이어가는 것이 전부다 — 단, 떼어낼 수 없는 프레임이 스택에 있으면 캐리어에 **고정(pinned)** 된다.

## 내부 동작

### 두 층 구조: VirtualThread = Continuation + Scheduler

가상 스레드는 두 조각의 합성이다.

```
VirtualThread
 ├─ Continuation  ← 재개 가능한 실행 상태 (스택 프레임들)
 └─ Scheduler     ← 기본값: ForkJoinPool (FIFO async 모드, parallelism = CPU 코어 수)
```

- **Continuation**: 실행 중인 스택 프레임 전체를 캡처했다가 나중에 그 지점부터 다시 이어 실행할 수 있는 원시 구조. `yield`하면 현재 스택을 접어(freeze) 힙의 **stack chunk** 객체로 옮기고, 제어를 호출자에게 반환한다. 재개 시 그 chunk를 다시 캐리어 스택 위로 펼친다(thaw).
- **Carrier thread**: 가상 스레드를 실제로 실행하는 플랫폼(OS) 스레드. 기본 스케줄러인 ForkJoinPool의 워커다. 가상 스레드는 스스로 CPU에서 도는 게 아니라, 캐리어 위에 *올라타서(mount)* 돈다.

### mount / unmount 사이클

```
  가상 스레드 T가 소켓 read()에서 블로킹 하려는 순간:

  [carrier P1]  스택:  ...→ read()→ park()
        │
        │ 1. JDK I/O 코드가 "지금 데이터 없음" 감지 → Continuation.yield()
        ▼
  freeze: T의 스택 프레임을 힙 stack chunk로 복사   ← UNMOUNT
        │
        ▼
  [carrier P1]  이제 자유 → FJPool 큐에서 다른 가상 스레드 U를 mount
  ...
  (데이터 도착, Selector가 T를 깨움)
        │
        ▼
  thaw: T의 stack chunk를 아무 캐리어 P2 스택으로 복사 → 이어서 실행   ← MOUNT
```

핵심은 **블로킹 API가 재작성되어 있다**는 점이다. `SocketChannel.read()`, `Thread.sleep()`, `LockSupport.park()`, `BlockingQueue.take()` 등 JDK의 블로킹 지점들은 내부적으로 "가상 스레드면 OS를 블로킹하지 말고 continuation을 yield하라"로 바뀌었다. 그래서 *애플리케이션 코드는 그대로 동기 블로킹 스타일*인데도, 실제로는 캐리어를 놓아준다. 언마운트되면 캐리어 스택은 비고, 힙에는 T의 스택만 남으므로 수만 개의 대기 중 가상 스레드가 소수의 캐리어를 공유할 수 있다.

### 왜 스택을 "힙"에 두는가 (메모리 레이아웃)

플랫폼 스레드는 고정 크기 스택(리눅스 기본 ~1MB)을 OS가 예약한다 — 수만 개면 수십 GB. 가상 스레드의 스택은 힙의 stack chunk 객체이고, **실제 사용한 깊이만큼만** 차지하며 GC 대상이다. 깊이가 커지면 chunk를 늘리고, 얕아지면 회수한다. 이 "쓴 만큼만"이 경량성의 실체다.

### Pinning: 언마운트가 불가능한 경우

`Continuation.yield()`는 현재 캐리어 스택을 통째로 힙으로 옮기는 연산이다. 그런데 스택 프레임 중에 **네이티브 프레임과 얽힌 상태**가 있으면 그대로 옮길 수 없다. 대표적으로:

1. **`synchronized` 모니터를 잡은 채 블로킹** — 모니터(monitor)는 특정 OS 스레드에 귀속된 상태라, 가상 스레드가 캐리어를 바꾸면 모니터 소유권이 깨진다. 그래서 JDK 21에서는 언마운트를 포기하고 T를 캐리어에 **pin**한다.
2. **네이티브 메서드(JNI)나 foreign function 호출 스택 안에서 블로킹** — C 스택 프레임은 힙으로 접을 수 없다.

pinning이 일어나면 그 캐리어는 T가 블로킹을 끝낼 때까지 **다른 가상 스레드를 못 돌린다**. 대기 중인 가상 스레드가 많고 캐리어가 전부 pin되면 처리량이 급락한다(캐리어 기아). JDK는 이를 감지하려고 `-Djdk.tracePinnedThreads=full|short`로 pin 스택을 덤프할 수 있게 해준다.

> 참고: JEP 491(JDK 24)에서 `synchronized` 블로킹 시에도 언마운트가 가능하도록 모니터 구현이 개선되어, `synchronized`에 의한 pinning은 사실상 사라진다고 알려져 있다. 아래 "잘못 알고 있던 것"은 그 이전(JDK 21) 기준이다.

### 상태 전이로 본 한 사이클

가상 스레드는 내부적으로 몇 개의 상태를 오간다(`VirtualThread` 소스의 state 상수 기준, 단순화):

```
 NEW → STARTED →┌─────────────┐
                │   RUNNING   │  캐리어에 mount 되어 실행 중
                └──────┬──────┘
       블로킹 진입     │  yield()
                       ▼
                  PARKING ──(freeze 성공)──▶ PARKED   ← 언마운트됨, 캐리어 자유
                       │
                (freeze 불가: monitor/native)
                       ▼
                    PINNED   ← 캐리어 붙잡은 채 OS 블로킹
       깨어남(unpark) → RUNNABLE → (스케줄러가 캐리어에 다시 mount) → RUNNING
```

`PARKED`는 "스택이 힙에 안전하게 접혔고 캐리어는 남을 위해 반납된" 이상적 경로, `PINNED`는 "접지 못해 캐리어를 붙든 채 OS 수준에서 블로킹된" 예외 경로다. 두 상태의 차이가 곧 확장성의 차이다.

### 스케줄러는 시분할(preemption)을 안 한다

기본 스케줄러 FJPool은 가상 스레드를 **협조적(cooperative)** 으로만 전환한다 — 오직 블로킹 지점(yield 지점)에서만 캐리어를 양보한다. CPU 바운드 무한 루프는 yield 지점이 없어 캐리어를 계속 점유한다. 즉 가상 스레드는 "많은 블로킹 I/O"에 최적화된 것이지 CPU 병렬성을 늘리는 도구가 아니다.

## 검증

JDK 21+에서 pinning을 직접 관찰하는 흐름:

```java
// -Djdk.tracePinnedThreads=short 로 실행
var lock = new Object();
Thread.ofVirtual().start(() -> {
    synchronized (lock) {          // 모니터 획득
        try { Thread.sleep(100); } // 이 블로킹에서 언마운트 시도 → pin 발생
        catch (InterruptedException e) {}
    }
}).join();
// stderr 에 "VirtualThread[...] ... <== monitors:1" 형태의 pin 스택이 찍힌다.
```

`Thread.sleep()`은 가상 스레드에서 continuation yield로 구현되므로 평소엔 캐리어를 놓아주지만, `synchronized` 안이라 언마운트가 거부되고 캐리어에 고정됨을 스택 덤프로 확인할 수 있다. 같은 코드를 `ReentrantLock`으로 바꾸면(락은 캐리어가 아닌 가상 스레드에 귀속) pin 로그가 사라진다 — 이것이 "Loom 시대엔 `synchronized` 대신 `ReentrantLock`" 권고의 근거다.

## 잘못 알고 있던 것

- **"가상 스레드는 OS 스레드보다 그냥 빠르다"** → 아니다. 단일 작업의 실행 속도는 동일하다(결국 같은 캐리어 위에서 돈다). 빨라지는 건 *개수*다 — 블로킹 대기 중인 스레드가 OS 스레드를 붙잡지 않으므로, 같은 하드웨어로 훨씬 많은 동시 블로킹 작업을 수용한다.
- **"`synchronized`든 `ReentrantLock`이든 동기화는 다 똑같다"** → 가상 스레드 관점에선 다르다(JDK 21 기준). `synchronized` 블로킹은 캐리어 pinning을 유발하지만 `ReentrantLock`은 정상 언마운트된다. 락은 가상 스레드에 귀속되고 continuation과 함께 이동하기 때문이다.
- **"가상 스레드를 풀(pool)에 담아 재사용해야 한다"** → 반대다. 생성 비용이 거의 없으므로 작업당 하나씩 만들고 버리는 게 정석이다. 풀링은 오히려 ThreadLocal 오염 등 문제를 만든다.

## 더 파고들 만한 것

- `Continuation`/`StackChunk`의 freeze·thaw가 GC(특히 stack chunk의 barrier)와 어떻게 상호작용하는가.
- JEP 491에서 `synchronized` pinning을 없앤 모니터 재구현의 실제 메커니즘.

## 참고

- JEP 444: Virtual Threads (Final) — [openjdk.org/jeps/444](https://openjdk.org/jeps/444)
- JEP 491: Synchronize Virtual Threads without Pinning
- OpenJDK 소스: `java.lang.VirtualThread`, `jdk.internal.vm.Continuation`
