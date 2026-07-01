# ThreadLocal 내부 구조와 메모리 누수: WeakReference 키가 막지 못하는 것

> **Primary source:** OpenJDK `java.lang.ThreadLocal` / `ThreadLocal.ThreadLocalMap` 소스 (JDK 17), `java.lang.Thread#threadLocals`
> **Secondary:** Java API docs (`ThreadLocal`), Effective Java 3rd Item 6 (주변 논의)
> **Date:** 2026-07-01
> **Status:** draft

## 왜 봤나

- 스레드 풀 환경에서 `ThreadLocal`을 쓰다가 `remove()`를 빠뜨리면 메모리 누수가 난다는 경고는 자주 듣는다. 그런데 "키가 `WeakReference`라 GC가 알아서 치워준다"는 설명과 "누수가 난다"는 설명이 동시에 돌아다닌다. 둘 다 맞는데, **어느 절반이 참인지**가 핵심이다.
- 사전에 나는 `ThreadLocal`이 스레드별로 값을 담는 `Map<Thread, T>` 같은 것이라고 막연히 생각했다. 실제 저장 구조는 정반대에 가깝다.

## 핵심 한 문장

> 값은 `ThreadLocal` 객체가 아니라 **각 `Thread` 안의 `ThreadLocalMap`** 에 들어가고, 그 맵의 Entry는 키(=`ThreadLocal`)만 약참조로 잡고 값은 강참조로 잡기 때문에, 스레드가 오래 사는 풀에서는 키가 GC돼도 값이 살아남아 누수가 된다.

## 내부 동작

### 저장 위치: 맵은 ThreadLocal이 아니라 Thread가 가진다

`ThreadLocal.set(v)`는 값을 자기 안에 넣지 않는다. **현재 스레드**를 찾아 그 스레드의 맵에 넣는다.

```java
public void set(T value) {
    Thread t = Thread.currentThread();
    ThreadLocalMap map = getMap(t);   // t.threadLocals 반환
    if (map != null) map.set(this, value);   // 키 = this(ThreadLocal), 값 = value
    else createMap(t, value);
}
// ThreadLocal.getMap:
ThreadLocalMap getMap(Thread t) { return t.threadLocals; }
```

즉 저장 구조를 그림으로 보면:

```
Thread A ──▶ ThreadLocalMap ──▶ Entry[]  ─ [tlX → "a"] [tlY → 3] ...
Thread B ──▶ ThreadLocalMap ──▶ Entry[]  ─ [tlX → "b"] ...
                                    ▲
        같은 ThreadLocal tlX 라도 스레드마다 다른 슬롯/다른 값
```

`Map<Thread, Value>`가 아니라 `Thread → Map<ThreadLocal, Value>`다. 그래서 스레드가 죽으면 그 스레드의 맵 전체가 함께 사라진다 — **여기서 "스레드 끝나면 알아서 정리된다"는 절반의 진실**이 나온다.

### 자료구조: 체이닝이 아니라 오픈 어드레싱(선형 탐사)

`ThreadLocalMap`은 `HashMap`과 다르다. 버킷 + 연결 리스트가 아니라 **`Entry[]` 하나에 선형 탐사(open addressing)** 로 충돌을 푼다.

```java
static class Entry extends WeakReference<ThreadLocal<?>> {
    Object value;                       // 값은 강참조 필드
    Entry(ThreadLocal<?> k, Object v) {
        super(k);                       // 키만 약참조로 보관
        value = v;
    }
}
private Entry[] table;                  // 길이는 항상 2의 거듭제곱
```

인덱스는 `key.threadLocalHashCode & (len-1)`. 이 해시코드는 새 `ThreadLocal`이 생길 때마다 원자적으로 상수를 더해 만든다.

```java
private static final int HASH_INCREMENT = 0x61c88647;  // 2^32 / φ 근사(황금비)
private static AtomicInteger nextHashCode = new AtomicInteger();
private final int threadLocalHashCode = nextHashCode.getAndAdd(HASH_INCREMENT);
```

`0x61c88647`을 연속으로 더하면 2의 거듭제곱 크기 배열에서 값이 **거의 균등하게** 흩뿌려진다(피보나치 해싱). 그래서 선형 탐사인데도 클러스터링이 잘 안 생긴다. 충돌 시엔 다음 슬롯으로:

```java
private static int nextIndex(int i, int len) { return (i + 1 < len) ? i + 1 : 0; }
```

### 누수가 생기는 지점: 키는 약참조, 값은 강참조

Entry는 `WeakReference<ThreadLocal<?>>`를 상속하므로 **키(ThreadLocal)** 는 약하게 잡힌다. 하지만 `value` 필드는 평범한 강참조다. 참조 사슬을 보면:

```
Thread(살아있음) → threadLocals(ThreadLocalMap) → Entry[] → Entry
                                                        │(약참조) │(강참조)
                                                        ▼        ▼
                                                  ThreadLocal   value 객체
                                                  (외부 강참조   (계속 강하게
                                                   사라지면 GC)   매달려 있음)
```

외부에서 `ThreadLocal` 변수 참조가 사라지면 GC가 키를 회수한다. 그 순간 Entry는 `key == null`인 **stale entry**가 된다. 문제는 그래도 `Entry` 자체와 `value`는 살아있는 `Thread`에서 `table[]`로 강하게 도달 가능하다는 점이다. 스레드가 죽지 않는 한(=풀 스레드) `value`는 회수되지 않는다.

### 스스로 청소하는 메커니즘: expunge

JDK는 이 stale entry를 기회주의적으로 치운다. `set/get/remove`가 슬롯을 훑다가 `key == null`인 Entry를 만나면:

- `expungeStaleEntry(i)`: 해당 슬롯의 `value=null`, Entry `null` 처리 후, 다음 `null` 슬롯까지의 구간을 **rehash**(선형 탐사로 밀려있던 것들을 제자리로 당김).
- `cleanSomeSlots(...)`: 로그 스케일(`log2(n)`)로 일부 슬롯만 훑어 stale을 정리 — 매번 전체를 스캔하면 비싸므로 분할 상환.
- `replaceStaleEntry(...)`: `set` 도중 stale 슬롯을 재활용.

핵심은 **이 청소가 "그 ThreadLocal에 다시 접근할 때"에만 일어난다**는 것이다. 키가 GC된 ThreadLocal은 두 번 다시 접근되지 않으므로, 그 stale entry의 `value`를 확실히 없앨 유일한 안전장치는 **접근 중인 다른 set/get이 우연히 그 슬롯을 지나가는 것뿐**이다. 그래서 명시적 `remove()`가 필요하다.

```java
public void remove() {
    ThreadLocalMap m = getMap(Thread.currentThread());
    if (m != null) m.remove(this);   // 해당 Entry.value 즉시 끊고 expunge
}
```

## 검증

OpenJDK 소스(`java.lang.ThreadLocal`)를 직접 따라가 확인한 흐름:

1. `Entry extends WeakReference<ThreadLocal<?>>`이고 `value`는 별도 강참조 필드다 → 키/값의 참조 강도가 비대칭임을 소스에서 확인.
2. `getMap`이 `t.threadLocals`를 돌려주므로 저장소는 스레드 소유임을 확인.
3. `expungeStaleEntry`가 `tab[staleSlot].value = null; tab[staleSlot] = null`로 값 참조를 끊고 이후 구간을 rehash함을 확인.

개념 재현(스레드 풀에서 remove 누락 시 값이 남는 상황):

```java
ExecutorService pool = Executors.newFixedThreadPool(1);
ThreadLocal<byte[]> tl = new ThreadLocal<>();
pool.submit(() -> tl.set(new byte[10_000_000]));  // 풀 스레드 맵에 10MB 강참조로 박힘
// 여기서 tl 변수 참조를 버려도(키는 GC 대상) 풀 스레드가 살아있으면
// Entry.value(10MB)는 그 스레드가 다음에 tl류를 건드리기 전까지 회수되지 않는다.
// 올바른 처리: 작업 끝에서 반드시 tl.remove();  (보통 finally 블록)
```

## 잘못 알고 있던 것

- **"키가 WeakReference라 ThreadLocal 안 쓰면 GC가 값까지 정리한다"** — 약참조는 **키에만** 걸려 있다. 값은 강참조라, 키가 회수돼도 값은 살아있는 스레드에서 도달 가능해 남는다. 약참조 키의 진짜 목적은 "값 자동 회수"가 아니라 "stale entry를 감지해 청소할 표식을 만드는 것"에 가깝다.
- **"ThreadLocal은 Map<Thread, Value>다"** — 반대다. `Thread`가 `ThreadLocalMap`을 소유하고, 그 맵의 키가 `ThreadLocal`이다. 그래서 스레드가 죽으면 맵 전체가 사라진다(짧은 스레드에서 누수가 잘 안 보이는 이유). 문제는 스레드를 재사용하는 **풀**이다.
- **"HashMap처럼 체이닝으로 충돌 처리한다"** — `ThreadLocalMap`은 오픈 어드레싱(선형 탐사)이라 Node 연결 리스트가 없다. 그래서 stale entry가 중간에 끼면 뒤 슬롯들의 탐사 경로가 흐트러져 rehash가 필요하다.

## 더 파고들 만한 것

- `InheritableThreadLocal`이 자식 스레드로 값을 복제하는 시점(`Thread` 생성자의 `inheritableThreadLocals` 처리)과 풀에서 왜 위험한가.
- `expungeStaleEntry`의 rehash가 선형 탐사 클러스터를 어떻게 재배치하는지 슬롯 단위 추적.

## 참고

- OpenJDK `java.lang.ThreadLocal`, `ThreadLocal.ThreadLocalMap`, `java.lang.Thread#threadLocals` (JDK 17 소스)
- Java Platform SE API docs — `ThreadLocal`
