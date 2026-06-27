# False Sharing와 @Contended: 캐시 라인이 만드는 보이지 않는 경합

> **Primary source:** JEP 142 (Reduce Cache Contention on Specified Fields) / OpenJDK `jdk.internal.vm.annotation.Contended` 소스 / JVM 플래그 `-XX:ContendedPaddingWidth`, `-XX:RestrictContended`
> **Secondary:** Intel 64 and IA-32 Architectures Optimization Reference Manual(캐시 라인·MESI), `java.util.concurrent.atomic.LongAdder` / `Striped64.Cell` 소스
> **Date:** 2026-06-27
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/false-sharing-and-contended

## 왜 봤나

- `LongAdder`가 `AtomicLong`보다 경합 상황에서 왜 빠른지 소스를 따라가다, `Striped64.Cell`에 붙은 `@jdk.internal.vm.annotation.Contended`를 만났다. 이게 무엇을 막는 건지 끝까지 보고 싶었다.
- 사전 오해: "두 스레드가 **서로 다른 변수**를 건드리면 동시성 비용이 없다"고 생각했다. 실제로는 변수가 **같은 캐시 라인**에 있으면 락 없이도 성능이 무너진다.

## 핵심 한 문장

> False sharing은 논리적으로 독립인 두 변수가 **같은 캐시 라인(보통 64바이트)** 에 얹혀 있어, 한쪽을 쓰면 캐시 일관성 프로토콜이 다른 쪽 캐시 라인까지 무효화시켜 서로 코어 간 라인을 핑퐁(ping-pong)하게 만드는 현상이다 — 락도 공유 변수도 없는데 발생하는 "가짜 공유".

## 내부 동작

### 1. 캐시는 변수가 아니라 "라인" 단위로 움직인다

CPU 캐시는 바이트 단위가 아니라 **캐시 라인(cache line)** 단위로 메모리를 읽고 쓴다. x86-64에서 라인 크기는 통상 64바이트다. 즉 8바이트 `long` 하나를 읽어도 그 변수가 속한 64바이트 블록 전체가 L1으로 올라온다.

문제는 **인접한 필드들이 한 라인에 같이 실린다는 점**이다.

```
한 객체의 필드 a, b가 메모리상 인접 → 같은 64B 라인에 적재

cache line (64 bytes)
┌───────────────────────────────────────────────┐
│  long a (8B) │ long b (8B) │ ... 나머지 48B ... │
└───────────────────────────────────────────────┘
        ↑ Core0이 갱신          ↑ Core1이 갱신
        둘은 독립 변수지만 같은 라인 → 운명 공동체
```

### 2. MESI: 왜 "남의 변수"가 내 캐시를 무효화하는가

캐시 일관성은 보통 MESI 프로토콜(또는 그 변형 MESIF/MOESI)로 유지된다. 각 캐시 라인은 코어별로 다음 4상태 중 하나를 가진다.

| 상태 | 의미 |
| --- | --- |
| **M**odified | 이 코어만 가진 수정본. 메모리와 불일치(dirty). |
| **E**xclusive | 이 코어만 가졌고 메모리와 동일(clean). |
| **S**hared | 여러 코어가 같은 라인을 읽기 공유 중. |
| **I**nvalid | 무효. 다시 읽어와야 함. |

핵심 규칙: **어떤 코어가 라인을 쓰려면(Modified로 전이) 그 라인을 가진 다른 모든 코어의 사본을 Invalid로 만들어야 한다.** 이게 RFO(Request For Ownership)다.

false sharing의 상태 전이 시나리오(변수 `a`는 Core0, `b`는 Core1이 갱신, 둘은 같은 라인 L):

```
초기:  Core0[L]=S    Core1[L]=S        (둘 다 읽기 공유)

Core0이 a 쓰기:
   Core0 → RFO 브로드캐스트
   Core1[L] → I     (b는 안 건드렸는데 무효화됨!)
   Core0[L] → M

Core1이 b 쓰기:
   Core1[L]=I 이므로 먼저 라인을 다시 읽어와야 함
   Core1 → RFO
   Core0[L] → I     (a도 안 건드렸는데 무효화됨!)
   Core1[L] → M     (Core0의 M 라인을 write-back 후 가져옴)

Core0이 다시 a 쓰기 → 또 RFO → Core1 무효화 → ...
```

결과적으로 라인 L이 두 코어의 L1 사이를 계속 왕복한다. 매 접근이 L1 히트(수 사이클)가 아니라 **다른 코어 캐시/L3에서 라인을 끌어오는 비용(수십~수백 사이클)** 으로 바뀐다. 락도 없고 데이터 경합(같은 변수 동시 수정)도 없지만, **하드웨어 레벨의 경합**이 생긴다. 이름이 "false" sharing인 이유다 — 소프트웨어는 공유한 적 없는데 하드웨어가 공유로 취급한다.

### 3. 해법: 같은 라인에 안 얹히게 패딩(padding)한다

고전적 수동 해법은 핫 필드 주위에 더미 필드를 채워 라인을 통째로 점유시키는 것이다.

```java
// 수동 패딩 (Java 7 시절 관용구) — value 하나가 라인 하나를 독점
class PaddedLong {
    public volatile long value;        // 8B
    public long p1, p2, p3, p4, p5, p6, p7;  // 56B 더미 → 합 64B
}
```

문제: (1) JIT/JVM이 "사용되지 않는 필드"라며 제거하거나 재배치할 수 있고, (2) 라인 크기·프리페치 정책이 하드웨어마다 달라 56B가 항상 맞지 않는다.

### 4. @Contended: JVM이 직접 패딩을 보장 (JEP 142)

Java 8의 JEP 142가 이 패턴을 언어/런타임 차원에서 표준화했다. 필드(또는 클래스)에 애너테이션을 붙이면 **객체 레이아웃 단계에서 JVM이 그 필드 앞뒤로 패딩 바이트를 삽입**해 다른 필드와 라인을 공유하지 않게 만든다.

- Java 8: `sun.misc.Contended`
- Java 9+: 모듈 캡슐화로 `jdk.internal.vm.annotation.Contended`로 이동(내부 API).

```java
import jdk.internal.vm.annotation.Contended;

class Counter {
    @Contended volatile long a;   // a는 자기 라인을 독점
    @Contended volatile long b;   // b도 별도 라인
}
```

패딩 폭은 플래그 `-XX:ContendedPaddingWidth`로 정해지며, 공식 문서에 따르면 **기본값은 128바이트**다(0~8192, 8의 배수). 64B 라인인데 128B를 쓰는 이유는 **인접 라인 프리페처(adjacent-line prefetcher)** 때문이다 — 하드웨어가 라인을 가져올 때 다음 라인까지 미리 끌어오는 경우가 있어, 두 라인 폭(128B)을 비워야 프리페치로 인한 false sharing까지 막힌다고 알려져 있다.

중요한 함정: **`@Contended`는 기본적으로 부트클래스패스(JDK 내부)에서만 동작한다.** 애플리케이션 코드(유저 클래스패스)에서 효과를 보려면 `-XX:-RestrictContended`로 제한을 풀어야 한다(`RestrictContended`는 기본 enabled). 그래서 일반 애플리케이션 필드에 무심코 붙여놓고 "패딩됐겠지" 단정하면 안 된다.

### 5. 실전 사례: LongAdder는 false sharing을 설계로 회피한다

`AtomicLong`은 단일 `value`에 모든 스레드가 CAS를 건다 → 고경합 시 그 한 라인이 코어 사이를 계속 핑퐁. `LongAdder`(`Striped64` 기반)는 값을 여러 `Cell`로 **striping**하고, 각 `Cell`을 `@Contended`로 분리한다.

```java
// java.util.concurrent.atomic.Striped64 (요지)
@jdk.internal.vm.annotation.Contended
static final class Cell {
    volatile long value;
    // ... CAS 메서드
}
```

스레드들이 서로 다른 `Cell`에 흩어져 더하므로, 각 `Cell`이 별도 라인을 차지해 코어 간 라인 경합이 사라진다. `sum()`은 모든 `Cell`을 합산. JDK 내부 클래스라 `RestrictContended` 제약 없이 패딩이 적용된다 — `LongAdder`가 고경합에서 빠른 핵심 이유 중 하나다.

## 검증

출처(OpenJDK 소스/플래그 문서)를 따라가며 동작을 확인한 흐름:

1. `Striped64.Cell`이 `@Contended`로 선언된 것을 소스에서 확인 → 각 Cell이 독립 라인을 점유하도록 의도됨.
2. 인라인으로 false sharing 재현 구조를 그려보면, 같은 객체의 인접 두 `long`을 두 스레드가 각각 갱신할 때 라인 핑퐁이 발생:

```java
class Shared {            // 패딩 없음 → a, b 같은 64B 라인 가능성 큼
    volatile long a;
    volatile long b;
}
// Thread-0: 루프에서 s.a++  /  Thread-1: 루프에서 s.b++
// 기대: a, b는 독립 변수이므로 두 스레드가 거의 선형 스케일해야 정상
// 실제: 처리량이 단일 스레드보다 떨어지거나 정체 → false sharing 징후
```

패딩 적용 후(또는 `@Contended` + `-XX:-RestrictContended`) 두 스레드가 독립 라인을 쓰게 되면 핑퐁이 사라져 처리량이 회복된다. (이 repo엔 실행 환경이 없어 수치는 생략하고, "같은 라인 공유 → RFO 핑퐁 → 처리량 저하 → 라인 분리로 회복"이라는 인과만 명시한다.)

3. 패딩 폭이 라인(64B)이 아니라 128B 기준인 점은 `ContendedPaddingWidth` 기본값(공식 문서상 128)과 일치 → 프리페치 고려라는 설명과 부합.

## 잘못 알고 있던 것

- **(오해) "서로 다른 변수를 만지면 동시성 비용이 없다."**
  → 변수가 논리적으로 독립이어도 **물리적으로 같은 캐시 라인**에 있으면 MESI 무효화로 경합이 생긴다. 비용의 단위는 "변수"가 아니라 "캐시 라인"이다.
- **(오해) "false sharing은 `volatile`이나 락 때문이다."**
  → `volatile`은 가시성을 강제할 뿐, 근본 원인은 **데이터 레이아웃**이다. `volatile`이 아니어도 같은 라인을 양쪽이 쓰면 캐시 일관성 트래픽이 발생한다. `volatile`은 store가 다른 코어에 빨리 전파되게 만들어 증상을 더 잘 드러낼 뿐이다.
- **(오해) "필드에 `@Contended`만 붙이면 끝."**
  → 유저 클래스패스에서는 `-XX:-RestrictContended`가 없으면 무시된다(기본 제한 enabled). 또 무분별한 패딩은 객체 크기를 키워 캐시 점유·메모리를 늘리므로, **진짜 핫한 고경합 필드에만** 선택적으로 써야 한다.

## 더 파고들 만한 것

- `LongAdder` vs `AtomicLong`의 경합 곡선: striping이 언제부터 이득인지, 단일 스레드에선 왜 `AtomicLong`이 더 나은지.
- MESI의 확장인 MOESI/MESIF에서 Owner/Forward 상태가 라인 전송 비용을 어떻게 줄이는지.
- JOL(Java Object Layout)로 실제 객체의 필드 오프셋과 `@Contended` 패딩을 덤프해 레이아웃을 눈으로 확인하기.

## 참고

- JEP 142: Reduce Cache Contention on Specified Fields
- OpenJDK `jdk.internal.vm.annotation.Contended` 소스
- JVM 플래그: `-XX:ContendedPaddingWidth`(기본 128), `-XX:-RestrictContended`
- `java.util.concurrent.atomic.Striped64` / `LongAdder` 소스
- Intel 64/IA-32 Optimization Reference Manual (캐시 라인·MESI·프리페치)
