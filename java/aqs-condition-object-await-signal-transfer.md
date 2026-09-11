# AQS Condition: await/signal은 스레드를 깨우지 않고 대기열만 옮긴다

> **Primary source:** `java.util.concurrent.locks.AbstractQueuedSynchronizer` 소스 — `openjdk/jdk`(master) 및 `openjdk/jdk21u` 브랜치에서 `ConditionObject`/`Node`/`acquire`/`release` 구현을 직접 확인
> **Secondary:** Doug Lea, "The java.util.concurrent Synchronizer Framework" (PODC 2004); 본 저장소 [`synchronized-vs-reentrantlock.md`](./synchronized-vs-reentrantlock.md) (구버전 CLH/waitStatus 모델 설명)
> **Date:** 2026-09-11
> **Status:** draft

## 왜 봤나

- `Condition.await()`/`signal()`은 흔히 "`Object.wait()`/`notify()`의 다중 조건 지원판" 정도로만 알려져 있고, `signal()` 호출 즉시 대기 스레드가 실행을 재개한다고 오해하기 쉽다. 이 오해는 `while(!조건) await();` 관용구가 왜 필수인지를 흐릿하게 만든다.
- 부수적으로: 온라인에 퍼진 AQS 설명 대다수는 `waitStatus`(SIGNAL/CANCELLED/CONDITION/PROPAGATE) 필드 기반의 예전 구현을 다룬다. 현재 OpenJDK 소스가 그 모델과 같은지도 확인 대상이었다.

## 핵심 한 문장

> `Condition.await()`는 스레드를 **sync queue에서 빼서 condition queue(단일 연결 리스트)로 옮기고 락을 반납한 뒤 park**하는 것이고, `signal()`은 그 스레드를 **직접 깨우는 게 아니라 condition queue 맨 앞 노드를 sync queue 꼬리로 전학(enqueue)시킬 뿐**이다 — 실제 unpark는 그 노드가 sync queue에서 signal 대상이 될 때 일어난다.

## 내부 동작

### 두 개의 큐, 두 개의 연결 방식

AQS 내부에는 성격이 다른 큐가 두 개 있다.

```
sync queue (lock 자체의 대기자 — CLH 변형, 양방향 연결)
  +------+  prev  +-------+  prev  +------+
  | head | <----- | node2 | <----- | tail |
  +------+  next  +-------+  next  +------+
  (head/tail volatile, CAS로 tail 삽입, 상태는 Node.status)

condition queue (특정 Condition 인스턴스의 대기자 — 단일 연결, ConditionObject 소유)
  firstWaiter -> [C1] -> [C2] -> [C3] <- lastWaiter
                (nextWaiter 로만 연결, exclusive 보유 중에만 접근하므로 CAS 불필요)
```

`Node.status`는 3개의 비트 값으로 노드 상태를 나타낸다 (`AbstractQueuedSynchronizer` 소스 상단 상수):

```java
static final int WAITING   = 1;          // 언파크 필요(대기 중) 표시
static final int CANCELLED = 0x80000000; // 취소됨 (반드시 음수)
static final int COND      = 2;          // condition queue에서 대기 중
```

`ConditionNode`는 `Node`를 확장하면서 `nextWaiter`(조건 큐 연결용) 필드를 추가로 갖고, 동시에 `ForkJoinPool.ManagedBlocker`를 구현한다.

### `await()` 절차 — sync queue를 떠나 condition queue로

`ConditionObject.await()`가 실제로 하는 일(소스 순서 그대로):

1. **`newConditionNode()`**: `ConditionNode`를 생성한다. sync queue의 head가 아직 없으면 `tryInitializeHead()`로 더미 헤더를 만들어 둔다(OOME 대비 폴백 경로 포함).
2. **`enableWait(node)`**: `isHeldExclusively()`를 확인하고, `node.status = COND | WAITING`으로 설정한 뒤 `lastWaiter` 뒤에 매단다(condition queue 진입). 그다음 `release(savedState)`로 **락을 완전히 반납**하고 `savedState`(재획득 시 복원할 상태값)를 반환한다. 락을 들고 있지 않았다면 `IllegalMonitorStateException`.
3. **대기 루프**: `canReacquire(node)`가 true가 될 때까지(=sync queue에 다시 연결되어 재획득 가능해질 때까지) `node.status`에 `COND` 비트가 남아 있는 동안 `ForkJoinPool.managedBlock(node)`(또는 실패 시 `node.block()`, 둘 다 결국 `LockSupport.park()`)로 블로킹한다.
   - `ConditionNode.isReleasable()`은 `status <= 1 || Thread.currentThread().isInterrupted()`로 정의된다 — `COND`(2) 비트가 벗겨져 `status`가 0 또는 `WAITING`(1)이 되면 깨어날 자격이 생긴다는 뜻.
4. 깨어나면 `reacquire(node, savedState)`로 **일반 `acquire` 루프**를 다시 타서 락을 재획득한다.

### `signal()` — "깨움"이 아니라 "전학"

```java
private void doSignal(ConditionNode first, boolean all) {
    while (first != null) {
        ConditionNode next = first.nextWaiter;
        if ((firstWaiter = next) == null) lastWaiter = null;
        else first.nextWaiter = null;
        if ((first.getAndUnsetStatus(COND) & COND) != 0) {
            enqueue(first);          // ★ sync queue의 tail로 이동
            if (!all) break;
        }
        first = next;
    }
}
```

핵심은 `enqueue(first)`다 — `LockSupport.unpark`를 호출하지 않는다. `signal()`이 하는 일은 딱 여기까지: **condition queue에서 노드를 떼서 sync queue 꼬리에 붙이는 것**. 이 노드가 실제로 깨어나 실행을 재개하려면,

- sync queue에서 자기 차례(=`head`의 다음 노드)가 와야 하고,
- 그 시점에 앞 노드가 `release()`를 호출해 `signalNext(head)`가 실행되어야 한다:

```java
public final boolean release(int arg) {
    if (tryRelease(arg)) {
        signalNext(head);   // 여기서만 실제 LockSupport.unpark 발생
        return true;
    }
    return false;
}
```

즉 `signal()` 호출 스레드가 아직 락을 들고 있는 동안(그리고 나중에 `unlock()`할 때까지) 신호받은 스레드는 여전히 park 상태로 남아 있을 수 있다. 이건 **Mesa 모니터 시맨틱**(신호를 보내도 즉시 소유권이 넘어가지 않고, 신호는 힌트일 뿐 재검사가 필요하다)의 전형적인 형태이며, `while(!조건) await();`가 필요한 이유이기도 하다 — signal과 실제 깨어남 사이에 다른 스레드가 먼저 락을 잡아 조건을 다시 깨뜨릴 수 있다.

### 인터럽트와 신호의 경쟁을 상태 CAS로 해소

`await()`에서 인터럽트 처리 부분:

```java
if (interrupted |= Thread.interrupted()) {
    if (cancelled = (node.getAndUnsetStatus(COND) & COND) != 0)
        break;              // 신호보다 인터럽트가 먼저 도착 → 취소로 처리
    // COND가 이미 벗겨졌으면(=signal이 먼저 도착) 정상 재획득 경로로 계속
}
```

`getAndUnsetStatus(COND)`는 `Unsafe.getAndBitwiseAndInt` 기반의 **원자적 read-and-clear**다. "인터럽트가 signal보다 먼저 도착했는가"라는 경쟁을 락 없이 이 연산 하나로 판정한다 — 먼저 `COND` 비트를 벗기는 쪽이 이긴다.

## 검증

이 저장소엔 실행 환경이 없으므로, 독자가 직접 확인할 수 있는 두 경로:

1. **소스 확인**: `AbstractQueuedSynchronizer.java`의 내부 클래스 `ConditionObject`에서 `enableWait`, `doSignal`, `canReacquire`, `await()` 메서드를 순서대로 읽으면 위 흐름을 그대로 재현할 수 있다 (OpenJDK GitHub `src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java`).
2. **런타임 관찰**: 아래처럼 `ReentrantLock`+`Condition`으로 생산자/소비자를 만들고 소비자가 대기 중일 때 `jstack <pid>`를 떠 보면, 소비자 스레드가 `java.lang.Thread.State: WAITING (parking)`이며 스택 프레임에 `sun.misc.Unsafe.park` → `LockSupport.park` → `ConditionObject.await`가 보인다(모니터의 `WAIT`가 아니라 park 기반이라는 점이 드러남).

```java
final ReentrantLock lock = new ReentrantLock();
final Condition notEmpty = lock.newCondition();
final Deque<Integer> queue = new ArrayDeque<>();

void put(int v) {
    lock.lock();
    try {
        queue.addLast(v);
        notEmpty.signal();          // condition queue -> sync queue 전학만 수행
    } finally { lock.unlock(); }    // 여기서 signalNext(head) 발생, 실제 unpark
}

int take() throws InterruptedException {
    lock.lock();
    try {
        while (queue.isEmpty())     // Mesa 시맨틱: 재검사 필수
            notEmpty.await();
        return queue.removeFirst();
    } finally { lock.unlock(); }
}
```

## 잘못 알고 있던 것

- **"AQS 노드 상태는 `waitStatus` 필드에 `SIGNAL(-1)`/`CANCELLED(1)`/`CONDITION(-2)`/`PROPAGATE(-3)` 네 값으로 표현된다"** — 이는 오래전(대략 JDK 5~18 계열, `shouldParkAfterFailedAcquire` 기반) 구현을 설명한 것이고, 이번에 확인한 현재 소스(`openjdk/jdk` master, `openjdk/jdk21u` 모두 동일)는 `status` 필드에 `WAITING(1)`/`CANCELLED(0x80000000)`/`COND(2)` **비트 조합**으로 재설계되어 있다. 취소 노드 제거도 `cleanQueue()`의 Michael-Scott류 unsplice로 바뀌었다. 이 저장소의 다른 노트([`synchronized-vs-reentrantlock.md`](./synchronized-vs-reentrantlock.md))가 그리는 CLH 다이어그램은 이 예전 모델 기준이므로, 최신 JDK 소스와 대조할 때는 이 차이를 감안해야 한다.
- **"`signal()`을 호출하면 대기 스레드가 그 즉시 깨어나 실행을 재개한다"** — `signal()`은 노드를 condition queue에서 sync queue로 옮기는(enqueue) 것으로 끝난다. 실제 `unpark`는 그 노드가 sync queue의 signal 대상(head의 next)이 되고, 앞 노드가 `release()`를 호출하는 시점에 일어난다. 그 사이 다른 스레드가 락을 선점해 조건을 다시 거짓으로 만들 수 있으므로 `if`가 아니라 `while(!조건)`으로 재검사해야 한다.

## 더 파고들 만한 것

- `ConditionNode`가 `ForkJoinPool.ManagedBlocker`를 구현하는 이유: 공용 풀 안에서 조건 대기를 하더라도 풀이 임시로 워커를 보충해 고갈을 막는 메커니즘.
- `cleanQueue()`의 `(p, q, s)` 3중 포인터 순회 — Michael-Scott 큐 unsplice 기법과의 대응 관계.

## 참고

- OpenJDK GitHub: `openjdk/jdk`(master), `openjdk/jdk21u` — `java.util.concurrent.locks.AbstractQueuedSynchronizer`
- Doug Lea, "The java.util.concurrent Synchronizer Framework", PODC 2004
- 본 저장소: [`synchronized-vs-reentrantlock.md`](./synchronized-vs-reentrantlock.md) (구버전 CLH/waitStatus 모델)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
