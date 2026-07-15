# HikariCP ConcurrentBag: 커넥션을 락 없이 빌려주는 3단계 대여 알고리즘

> **Primary source:** HikariCP 소스 `com.zaxxer.hikari.util.ConcurrentBag` (dev 브랜치)
> **Secondary:** HikariCP Wiki "Down the Rabbit Hole" (설계 노트)
> **Date:** 2026-07-15
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/hikaricp-concurrentbag-connection-lending

## 왜 봤나

- Spring Boot 기본 커넥션 풀이 HikariCP인데, "빠르다"는 말만 알았지 *왜* 빠른지 몰랐다.
- 막연히 "풀에서 커넥션 꺼낼 때 `synchronized`로 락 잡고 리스트에서 하나 빼는 것" 정도로 알고 있었다. 실제 `borrow()`는 흔한 경로에서 락을 아예 안 잡는다.

## 핵심 한 문장

> ConcurrentBag은 커넥션 하나하나를 원자 상태값(0/1)으로 관리해서, 대여를 "리스트 조작"이 아니라 **상태에 대한 CAS 한 번**으로 바꾸고, 방금 쓴 커넥션은 **스레드-로컬 캐시**로 되빌리게 해 공유 자료구조 경합 자체를 줄인다.

## 내부 동작

### 자료구조 (필드)

```java
private final CopyOnWriteArrayList<T> sharedList;      // 모든 엔트리의 진짜 원장
private final ThreadLocal<List<Object>> threadList;    // 스레드별 최근 사용 캐시
private final SynchronousQueue<T> handoffQueue;        // 대기자에게 직접 건네는 통로
private final AtomicInteger waiters;                    // 지금 borrow에서 블록된 스레드 수
```

- `sharedList`가 **CopyOnWriteArrayList**인 게 핵심이다. 읽기(순회)는 스냅샷 기반이라 **락 없이** 진행되고, 실제 mutation(커넥션 추가/제거)은 대여/반납에 비해 드물다. 그래서 뜨거운 경로인 순회가 락 경합을 안 받는다.
- `threadList`는 `List<Object>`다. `T` 그대로가 아니라 `Object`인 이유는 커스텀 클래스로더 환경에서 `WeakReference<T>`로 감싸 넣기 때문(뒤 참조).

### 엔트리 상태 머신

각 엔트리(`IConcurrentBagEntry`)는 `AtomicInteger` 하나로 상태를 갖는다:

```
STATE_NOT_IN_USE =  0   // 대여 가능
STATE_IN_USE     =  1   // 대여됨
STATE_REMOVED    = -1   // 풀에서 제거됨(폐기 진행)
STATE_RESERVED   = -2   // 하우스키핑이 선점(maxLifetime/idle 정리 등)
```

대여의 본질은 이 한 줄이다:

```java
if (entry.compareAndSet(STATE_NOT_IN_USE, STATE_IN_USE)) { return entry; }
```

`0 → 1` CAS가 성공한 스레드가 그 커넥션을 가져간다. 두 스레드가 같은 커넥션을 노려도 CAS는 하나만 이긴다 — **락도, 큐에서 pop도 없다.**

### borrow() 3단계

```
borrow(timeout)
 ┌─────────────────────────────────────────────────────────┐
 │ 1) ThreadLocal 스캔 (뒤에서 앞으로)                        │
 │    내 threadList의 최근 항목부터 CAS(0→1) 시도            │
 │    → 성공하면 즉시 반환 (공유자료구조 접근 0회)           │
 ├─────────────────────────────────────────────────────────┤
 │ 2) sharedList 스캔                                        │
 │    waiters++  →  sharedList 전체를 CAS(0→1)로 훑음        │
 │    → 성공 시 (필요하면 대기자에게 양보 신호) 반환         │
 ├─────────────────────────────────────────────────────────┤
 │ 3) handoffQueue.poll(남은 timeout)                        │
 │    반납/추가되는 커넥션을 SynchronousQueue로 직접 수령    │
 │    타임아웃까지 남은 시간을 깎아가며 반복 poll            │
 │    → 끝내 못 받으면 SQLTransientConnectionException       │
 └─────────────────────────────────────────────────────────┘
```

1단계가 이 설계의 정체성이다. 방금 이 스레드가 반납한 커넥션이 `threadList`에 캐시돼 있으므로, 다음 쿼리에서 **같은 커넥션을 아무 공유 상태 접근 없이** 되빌린다(연결 affinity). `sharedList`를 뒤에서부터 훑는 것도 방금 반납된(=끝에 가까운) 엔트리를 먼저 노려 캐시 지역성을 살리려는 것으로 알려져 있다.

2단계에서 `waiters`를 먼저 올리는 순서도 의미가 있다. 스캔 도중 커넥션을 하나 잡았는데 아직 다른 대기자가 남아 있으면, 이 스레드는 자기가 필요한 것보다 더 훑다가 발견한 여분을 `handoffQueue.offer()`로 대기자에게 넘기도록 협조한다(구현상 borrow가 여유 엔트리를 만나면 양보 신호를 보냄). `waiters`가 반납 경로(requite)의 분기 조건이기도 해서, "지금 누가 기다리는가"라는 단일 카운터가 대여·반납 양쪽의 handoff 여부를 함께 결정한다.

### FastList — 순회 자료구조까지 깎아낸 이유

`threadList`와 내부 순회에 표준 `ArrayList` 대신 HikariCP 자체 `FastList`를 쓴다. `ArrayList.get(int)`는 매 호출마다 범위 검사(`rangeCheck`)를 하고 `remove(Object)`는 앞에서부터 선형 탐색하는데, 커넥션 대여/반납은 **초당 수십만 번** 일어나는 뜨거운 경로다. `FastList.get()`은 범위 검사를 생략하고, `remove(Object)`는 방금 쓴 항목이 리스트 **끝**에 있을 가능성이 높다는 특성을 노려 **뒤에서부터** 탐색한다. JIT가 bounds-check를 못 지우는 상황에서 나노초 단위 오버헤드를 걷어내려는 미시 최적화로, "상태 CAS로 락을 없앤다"는 큰 그림과 같은 방향의 선택이다.

### requite() — 반납

```java
entry.setState(STATE_NOT_IN_USE);
// 대기자가 있으면 그냥 리스트에 두지 않고 직접 건넨다
for (int i = 0; waiters.get() > 0; i++) {
    if (entry.getState() != STATE_NOT_IN_USE || handoffQueue.offer(entry)) return;
    // 짧게 양보(yield) 후 재시도
}
// 대기자가 없으면 threadList에 캐시로 push하고 끝
```

`SynchronousQueue`는 용량이 0이다. `offer()`는 **지금 누군가 `poll()`로 받고 있을 때만** 성공한다. 즉 대기 중인 스레드가 있으면 반납 커넥션은 sharedList를 거치지 않고 대기자에게 곧장 전달된다(불필요한 순회 제거). 대기자가 없으면 상태만 `0`으로 되돌리고 스레드-로컬에 넣는다.

### add() — 새 커넥션 편입

새 커넥션을 만들면 먼저 `sharedList`에 넣고, 곧바로 `waiters`가 있으면 `handoffQueue.offer()`로 대기자에게 밀어준다(엔트리가 아직 `NOT_IN_USE`인 동안). 풀 생성/확장 시 대기하던 스레드가 바로 받아가게 하는 것.

### weakThreadLocals

`getClass().getClassLoader() != ClassLoader.getSystemClassLoader()`이면 `threadList`에 `WeakReference<T>`로 감싸 넣는다. 톰캣 같은 컨테이너에서 앱 클래스로더가 언로드될 때, 요청 스레드(컨테이너 소유, 오래 삶)의 ThreadLocal이 커넥션을 **강참조**로 붙들어 클래스로더 누수를 일으키는 걸 막기 위해서다. 그래서 필드 타입이 `List<Object>`인 것.

## 검증

소스의 상태 상수와 대여 CAS를 따라가며 확인했다. 대여의 핵심 불변식: **엔트리 상태가 `0→1`로 CAS 성공한 스레드만 소유권을 얻는다.** 이걸로 두 시나리오를 짚어 보면:

```java
// 시나리오: 스레드 A가 반납해 A.threadList에 캐시된 커넥션 c를, B가 borrow
// c.state == 0 (NOT_IN_USE)
// B: sharedList 스캔 중 c 발견 → c.compareAndSet(0,1) 성공 → B가 c 소유
// A: 다음 borrow에서 자기 threadList의 c에 compareAndSet(0,1) 시도 → 이미 1 → 실패 → 건너뜀
```

→ threadList에 남아 있어도 CAS로 판정하므로 "이미 남이 가져간 커넥션"은 자연히 걸러진다. 이중 대여가 구조적으로 불가능.

## 잘못 알고 있던 것

- **"풀에서 커넥션 꺼낼 땐 락을 잡는다."** → 흔한 경로(1·2단계)는 `compareAndSet` 하나뿐이고, `sharedList`도 CopyOnWriteArrayList라 순회에 락이 없다. 블로킹은 풀이 고갈돼 3단계(`handoffQueue.poll`)까지 갔을 때만 발생한다.
- **"ThreadLocal에 캐시된 커넥션은 그 스레드 전용이다."** → 아니다. 캐시돼 있어도 `sharedList`에는 그대로 등록돼 있어, 다른 스레드가 CAS로 먼저 채갈 수 있다. threadList는 **소유권이 아니라 지역성 힌트**일 뿐이고, 그래서 스캔할 때도 반드시 CAS로 확인한다.
- **"반납은 그냥 리스트에 도로 넣는 것."** → 대기자(`waiters>0`)가 있으면 `SynchronousQueue`로 **직접 handoff**해서 sharedList를 아예 거치지 않는다. 대기자 유무에 따라 반납 경로가 갈린다.

## 더 파고들 만한 것

- `HikariPool`의 하우스키핑 스레드가 `STATE_RESERVED`로 엔트리를 선점해 maxLifetime/idleTimeout 커넥션을 안전하게 폐기하는 흐름.
- `getConnection()` 타임아웃(`connectionTimeout`)이 3단계 poll의 남은 시간으로 어떻게 환산되는지, 고갈 시 예외 메시지의 스레드/활성/대기 통계.

## 참고

- HikariCP 소스 `util/ConcurrentBag.java`, `util/FastList.java`
- HikariCP Wiki — "Down the Rabbit Hole" (설계 배경)
