# LongAdder는 처음부터 쪼개지 않는다 — Striped64의 base 우선·충돌 시 2배 확장·NCPU 상한과 probe 재해싱

> **Primary source:** OpenJDK 소스 `java.base/share/classes/java/util/concurrent/atomic/Striped64.java`, `LongAdder.java`, `java/util/concurrent/ThreadLocalRandom.java` (openjdk/jdk master 및 openjdk/jdk21u)
> **Secondary:** `java.util.concurrent.atomic.LongAdder` Javadoc
> **Date:** 2026-10-07
> **Status:** draft

## 왜 봤나

- `LongAdder`는 흔히 "스레드별 카운터를 두고 나중에 합친다"로만 설명된다. 이 설명으로는 테이블이 언제 생기는지, 왜 스레드 수만큼 커지지 않는지, `sum()`이 왜 부정확한지 답할 수 없다.
- 셀은 스레드에 고정 할당되지 않는다. "CAS 실패"라는 신호만으로 테이블을 키우고 해시를 다시 뽑는 적응형 알고리즘이다. 소스를 따라가면 이 사실이 가장 또렷하게 보인다.

## 핵심 한 문장

> LongAdder는 경합이 없으면 `base` 하나에만 CAS하고, CAS가 **실패했을 때만** `Cell[]`을 크기 2로 만든다. 같은 슬롯에서 충돌이 두 번 연속 나면 표를 2배로 키우되 `NCPU` 이상으로는 키우지 않으며, 그 뒤로는 스레드의 probe 해시를 xorshift로 바꿔 빈 슬롯을 찾는다.

## 내부 동작

### 1. 필드와 메모리 레이아웃

`Striped64`(package-private 추상 클래스)가 상태 전부를 들고 있다.

```
Striped64
 ├─ volatile long   base        // 무경합 경로, 테이블 초기화 경쟁 시 폴백
 ├─ volatile Cell[] cells       // null이거나 길이가 2의 거듭제곱
 └─ volatile int    cellsBusy   // 0→1 CAS 스핀락 (초기화·확장·슬롯 채우기 전용)

@Contended static final class Cell { volatile long value; }
```

`Cell`에 `@jdk.internal.vm.annotation.Contended`가 붙어 있다. 소스 주석은 이유를 이렇게 설명한다. 흩어져 있는 Atomic 객체에는 패딩이 과하지만, 배열에 담긴 Atomic 객체는 인접 배치되어 같은 캐시 라인을 공유하기 쉽다. 셀을 쪼개도 한 캐시 라인에 모여 있으면 false sharing 때문에 쪼갠 효과가 사라진다. 그래서 셀이 크고, 크기 때문에 **필요할 때까지 만들지 않는다**.

셀·base CAS는 모두 `weakCompareAndSetRelease`다. 가짜 실패가 나도 slow path로 넘어갈 뿐이라 정확성에는 문제가 없다.

### 2. fast path — `LongAdder.add(x)`

```java
if ((cs = cells) != null || !casBase(b = base, b + x)) {
    int index = getProbe();
    boolean uncontended = true;
    if (cs == null || (m = cs.length - 1) < 0 ||
        (c = cs[index & m]) == null ||
        !(uncontended = c.cas(v = c.value, v + x)))
        longAccumulate(x, null, uncontended, index);
}
```

1. `cells == null`이면 base CAS만 시도한다. 성공하면 끝이다. 경합이 없으면 이 경로가 AtomicLong과 사실상 같다.
2. 테이블이 이미 있거나 base CAS가 실패하면 스레드 probe로 `cs[probe & (n-1)]` 슬롯 하나를 골라 CAS한다.
3. 그것도 실패하면 slow path인 `longAccumulate`로 간다. 이때 `uncontended=false`를 함께 넘겨 "방금 셀 CAS가 실패했다"는 정보를 전달한다.

테이블이 생기면 이후 `add`는 **base를 건너뛴다**. base는 초기화 경쟁에서 진 스레드의 폴백으로만 남는다.

### 3. slow path — `longAccumulate` 상태 기계

```
                 ┌──────────── probe == 0 ? → ThreadLocalRandom.current()로 초기화
                 ▼
 ┌─ cells 있음 ─────────────────────────────────────────────────┐
 │ slot == null  → cellsBusy==0이면 new Cell(x), 락 잡고 재확인 후 장착 → 끝 │
 │               → 실패 시 collide=false                        │
 │ !wasUncontended → true로 바꾸고 재해싱만 (같은 슬롯 즉시 재시도 금지) │
 │ slot CAS 성공 → 끝                                            │
 │ n >= NCPU 또는 cells 교체됨 → collide=false (더 키우지 않음)   │
 │ !collide → collide=true (첫 충돌: 확장 보류, 재해싱만)          │
 │ collide && 락 획득 → cells = copyOf(cs, n<<1) → 같은 probe로 재시도 │
 │ (확장하지 않은 모든 분기) → index = advanceProbe(index)        │
 └──────────────────────────────────────────────────────────────┘
 ┌─ cells 없음 & 락 획득 → new Cell[2], rs[index & 1] = new Cell(x) → 끝
 └─ 그 외 → base CAS로 폴백, 성공하면 끝
```

설계 포인트는 다음과 같다.

- **확장 조건은 충돌 두 번이다.** 첫 CAS 실패에서는 `collide=true`만 세우고 probe를 바꿔 다른 슬롯을 시도한다. 재해싱한 뒤에도 비어 있지 않은 슬롯에서 또 실패해야 `n << 1` 확장이 일어난다. 우연히 한 번 겹친 것만으로 메모리를 두 배로 쓰지 않으려는 히스테리시스다.
- **상한은 NCPU다.** `n >= NCPU`이면 확장 분기에 들어가지 않는다. 크기는 2부터 2배씩 커지므로 실제 최대 크기는 "NCPU 이상인 가장 작은 2의 거듭제곱"이다. 소스 주석도 그렇게 설명한다. 예를 들어 NCPU=6이면 2→4→8에서 멈춘다(4 < 6이라 한 번 더 확장된다). 상한을 둔 이유도 주석에 있다. 스레드가 CPU보다 많아도 실제로 동시에 도는 스레드는 CPU 수를 넘지 못하므로, 원리적으로는 충돌 없는 완전 해시가 존재한다. 그다음은 확장이 아니라 **충돌난 스레드의 해시를 무작위로 바꿔** 그 매핑을 찾는다.
- **스핀락은 블로킹하지 않는다.** `cellsBusy`를 못 잡으면 다른 슬롯이나 base로 우회한다. 셀은 락 밖에서 미리 만들고, 락 안에서는 슬롯이 아직 null인지 **재확인**한 뒤 대입만 한다.
- **셀은 줄어들지 않는다.** 스레드가 죽거나 확장 뒤 마스크가 바뀌어 아무도 매핑되지 않는 셀이 생겨도 회수하지 않는다. 주석의 가정은 "오래 사는 인스턴스라면 경합이 다시 올 것"이다.

### 4. 해시는 어디서 오나 — Thread의 `threadLocalRandomProbe`

셀 인덱스는 `Thread`의 `threadLocalRandomProbe` 필드다. `ThreadLocalRandom`과 공유한다.

- 초기값 0은 "미초기화"를 뜻한다. `longAccumulate`는 `index == 0`이면 `ThreadLocalRandom.current()`로 강제 초기화한다. 초기 probe는 전역 `probeGenerator`에 `PROBE_INCREMENT = 0x9e3779b9`(황금비 기반 상수)를 더해 만들며, 0이면 1로 건너뛴다.
- 재해싱은 Marsaglia xorshift다: `probe ^= probe << 13; probe ^= probe >>> 17; probe ^= probe << 5;`
- 마스크가 `n-1`이므로 **하위 비트만** 인덱스에 쓰인다. 테이블이 2배가 되면 같은 probe에 비트가 하나 더 쓰여 스레드들이 자연스럽게 두 그룹으로 갈라진다.

**버전 차이(가상 스레드):** jdk21u의 `Striped64.getProbe()`는 `Thread.currentThread()`의 probe를 읽는다. openjdk/jdk master에서는 `getProbe`/`advanceProbe`가 `JLA.currentCarrierThread()`의 probe를 읽고 쓴다. (`localInit` 주석: "if virtual, share probe with carrier"). 즉 가상 스레드는 **캐리어의 probe**로 셀을 고르며, 동시에 도는 주체가 캐리어(≈CPU)라는 점에서 NCPU 상한 논리와 맞는다. 변경이 들어간 정확한 릴리스는 확인하지 못했다.

### 5. 읽기 — `sum()`은 스냅숏이 아니다

```java
long sum = base;
for (Cell c : cs) if (c != null) sum += c.value;
```

락·재시도 없이 각 필드를 차례로 읽을 뿐이라, Javadoc은 이 값이 "*NOT* an atomic snapshot"이라고 명시한다. 이미 읽은 셀에 그 뒤 더해진 값은 빠진다. `sumThenReset()`은 각 필드를 `getAndSet(0)`으로 원자적으로 비워 **업데이트가 유실되지는 않는다**. 다만 반환값이 리셋 직전의 최종값이라는 보장은 없다. `reset()`은 동시 업데이트가 없을 때만 쓰라고 Javadoc이 경고한다.

## 검증

JShell에서 직접 확인할 수 있다. `cells`는 package-private이라 리플렉션 접근에 `--add-opens`가 필요하다.

```java
// jshell -R--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED
import java.util.concurrent.atomic.*; import java.lang.reflect.*;
Field f = Class.forName("java.util.concurrent.atomic.Striped64").getDeclaredField("cells");
f.setAccessible(true);

LongAdder a = new LongAdder();
for (int i = 0; i < 1_000_000; i++) a.increment();   // 단일 스레드
System.out.println(f.get(a));                         // null 기대: 경합 없으면 테이블 미생성

var ts = new Thread[32];
for (int t = 0; t < ts.length; t++) { ts[t] = new Thread(() -> { for (int i = 0; i < 1_000_000; i++) a.increment(); }); ts[t].start(); }
for (Thread t : ts) t.join();
Object[] cells = (Object[]) f.get(a);
System.out.println(cells.length + " / NCPU=" + Runtime.getRuntime().availableProcessors());
System.out.println(a.sum());                          // 33_000_000
```

- 첫 출력이 `null`이면 "경합 없으면 base만"을 확인한 것이다.
- 32개 스레드를 띄워도 `cells.length`는 32가 아니다. `NCPU` 이상인 가장 작은 2의 거듭제곱 이하에 머문다(경합 강도에 따라 그보다 작을 수 있다).
- `Cell`은 package-private 중첩 클래스라 타입 이름으로 받을 수 없으므로 `Object[]`로 캐스팅한다.
- `-R-XX:ActiveProcessorCount=2`를 붙이면 `NCPU=2`가 되어 테이블이 2를 넘지 않는다.
- (2026-10-07, OpenJDK 25 · 8코어에서 실행: `null` → `8 / NCPU=8` → `33000000`)

## 잘못 알고 있던 것

- **"LongAdder는 스레드마다 카운터를 하나씩 둔다."** → 아니다. 셀은 스레드 소유가 아니고 probe 해시로 매핑되는 공유 슬롯이다. 개수는 스레드 수가 아니라 `NCPU`가 상한이다. 스레드가 1000개여도 8코어면 셀은 최대 8개이고, 충돌은 해시를 바꿔 피한다.
- **"LongAdder는 항상 AtomicLong보다 무겁다/빠르다."** → 경합이 없으면 `cells == null`이라 base 하나에 CAS하는 AtomicLong과 같은 경로를 탄다(Javadoc: "Under low update contention, the two classes have similar characteristics"). 차이는 경합이 생긴 뒤에만 나고, 그 대가는 @Contended 셀의 공간과 비원자적 `sum()`이다. 그래서 정확한 시퀀스·CAS 기반 제어(`compareAndSet`, `incrementAndGet` 반환값)가 필요하면 LongAdder로는 대체할 수 없다.

## 더 파고들 만한 것

- `ConcurrentHashMap`의 `size()`/`addCount`가 쓰는 `CounterCell` — 같은 계열의 스트라이핑 카운터로 알려져 있다. 소스에서 Striped64와 무엇이 다른지 비교해 볼 만하다.
- `LongAccumulator`의 `fn`이 결합·교환법칙을 어길 때 생기는 문제.

## 참고

- OpenJDK `Striped64.java` 클래스 주석(구현 노트 전체가 들어 있다)
- `LongAdder` Javadoc — `sum()`의 비원자성, AtomicLong과의 비교
