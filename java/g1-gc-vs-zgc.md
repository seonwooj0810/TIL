# G1 GC vs ZGC: 알고리즘 차이

> **Primary source:** Oracle HotSpot GC Tuning Guide (JDK 21) §6 (G1), §8 (ZGC); "Garbage-First Garbage Collection" — Detlefs, Flood, Heller, Printezis (ISMM 2004)
> **Secondary:** OpenJDK Wiki — ZGC, Generational ZGC (JEP 439); JEP 333 (ZGC), JEP 248 (G1 default)
> **Date:** 2026-05-28
> **Status:** draft

## 왜 봤나

- "G1은 throughput, ZGC는 latency"라는 한 줄짜리 요약으로 끝내고 있었다.
- 실제로 두 알고리즘이 **메모리를 어떻게 쪼개고, 객체 이동을 어떻게 추적하고, STW를 어떻게 줄이는지**를 보지 않은 상태였다.
- 특히 "ZGC가 어떻게 pause < 1ms를 보장하는가"의 핵심 트릭(컬러 포인터·로드 배리어)을 모호하게만 알고 있었다.

## 핵심 한 문장

> G1은 **region 기반 evacuating collector + 카드/리멤버드 셋으로 cross-region 참조를 추적**해 pause 목표를 맞추고, ZGC는 **컬러 포인터(metadata-in-pointer) + 로드 배리어**로 mark/relocate 단계 대부분을 **mutator와 동시에** 수행해 STW를 수 밀리초 이내로 압축한다.

## 내부 동작

### 1) 힙 레이아웃

두 GC 모두 region 기반이지만 region의 의미가 다르다.

```
G1 heap (Oracle GC Tuning Guide §6.2)
+----+----+----+----+----+----+----+----+
| E  | E  | S  | O  | O  | H  | -  | E  |   region size: 1~32MB (heap/2048 기준)
+----+----+----+----+----+----+----+----+
  E = Eden, S = Survivor, O = Old, H = Humongous(>region/2), - = Free

ZGC heap (HotSpot GC Tuning Guide §8.3)
+--------+--------+--------+----------------+
| small  | small  | medium |    large       |   small=2MB, medium=32MB,
+--------+--------+--------+----------------+   large=N*2MB (객체 1개 전용)
```

- G1에서는 region이 **세대 역할(Eden/Survivor/Old)을 동적으로 부여**받는다 (Oracle docs §6.2). 처음부터 고정 영역이 아니다.
- ZGC에서는 region(=ZPage) 크기 클래스가 **세 가지로 고정**되어 있다. 큰 객체는 자기 전용 large page를 할당받는다.
- Generational ZGC (JEP 439, JDK 21+)에서는 ZPage가 young/old 속성을 추가로 가진다.

### 2) cross-region 참조 추적

복사형(evacuating) GC의 핵심 문제: "이 region을 비울 때, 다른 region의 어떤 참조가 이 region을 가리키는지" 알아야 한다.

**G1 — Remembered Set + Card Table**

- 힙 전체를 512바이트 **card**로 나눈다 (G1 paper §2.2).
- 각 region은 자신을 가리키는 카드들의 집합 = **RSet**을 가진다.
- write barrier가 `obj.field = ref` 시 카드를 dirty로 마킹 → concurrent refinement 스레드가 그 카드를 스캔해 해당 region의 RSet에 추가.

```
Region A에 있는 객체가 Region B를 참조
  ┌─────────┐         ┌─────────┐
  │ Region A│ ──ref──▶│ Region B│
  └────┬────┘         └────▲────┘
       │                   │
       │ write barrier      │ RSet[B] = { card of A }
       ▼                   │
   dirty card ─── refinement thread ───┘
```

- B를 evacuate할 때 RSet[B]만 스캔하면 cross-region 참조를 빠짐없이 찾을 수 있다 → **전체 힙 스캔 없이 부분 GC 가능**.

**ZGC — RSet 없음 (콜드 패스: 컬러 포인터)**

- ZGC는 non-generational 시절 RSet을 두지 않았다 (HotSpot GC Tuning Guide §8.4): 모든 reachable 객체를 concurrent mark로 다시 찾는 방식.
- Generational ZGC(JEP 439)에서는 young↔old 참조용 **remembered set bitmap**이 들어왔지만, 여전히 write barrier가 비교적 가볍게 유지되도록 설계되었다고 JEP 439에 명시되어 있다.

### 3) 컬러 포인터와 로드 배리어 (ZGC 고유)

ZGC pause time 비밀의 핵심. 64-bit 가상주소의 **상위 비트에 GC 메타데이터를 박는다**.

```
ZGC reference layout (개념도; 실제 비트 위치는 JDK 버전에 따라 다름)
63                                  42  41              0
+----+----+----+----+----+ ... +----+--+------------------+
| 0  | M0 | M1 | Rmd| ...      |    |  | object address   |
+----+----+----+----+----+ ... +----+--+------------------+
       └── mark ──┘   └ remap ┘
```

- "이 reference가 현재 mark cycle을 통과했는가 / relocate 후 주소 갱신이 필요한가"가 포인터 자체에 인코딩된다.
- mutator가 reference를 **load할 때마다** load barrier가 끼어들어:
  1. metadata bits 검사
  2. 필요 시 객체를 새 위치로 옮기거나(=concurrent relocate), 포인터를 수정(=remap)
  3. 깨끗해진 포인터를 레지스터에 반환

> Oracle docs §8.2: "ZGC performs all expensive work concurrently, without stopping the execution of application threads for more than a few milliseconds."

이 덕분에 mark/relocate 작업을 **mutator와 동시에** 진행하면서도 일관성이 깨지지 않는다. G1은 동일한 일관성을 SATB(snapshot-at-the-beginning) + STW evacuation pause로 처리한다.

### 4) GC 사이클 상태 전이

```
G1 cycle (Oracle GC Tuning Guide §6.3)
[Young GC]* → ... → [Initial Mark(STW, piggyback)] → [Concurrent Mark]
   → [Remark(STW)] → [Cleanup(STW + concurrent)] → [Mixed GC(STW)]*

ZGC cycle (Oracle GC Tuning Guide §8.5)
[Mark Start(STW, ~µs)] → [Concurrent Mark/Remap] → [Mark End(STW, ~µs)]
   → [Concurrent Prepare for Relocate] → [Relocate Start(STW, ~µs)]
   → [Concurrent Relocate]
```

- G1의 STW pause = young/mixed evacuation 자체. region을 통째로 옮기는 copy 작업이 stop-the-world에서 수행된다. 그래서 region 수·RSet 크기가 pause를 좌우.
- ZGC의 STW pause = **각 스레드 스택 루트 스캔 + GC 단계 전환** 정도. 객체 복사는 전부 concurrent.

### 5) write barrier vs load barrier

| 항목 | G1 | ZGC |
|---|---|---|
| 배리어 종류 | write barrier (필드 저장 시) | load barrier (필드 로드 시) |
| 목적 | dirty card 마킹 + SATB pre-write | 컬러 포인터 검사·remap |
| 코드 크기 | 적음 | 상대적으로 큼 (load 경로마다 삽입) |
| pause 비용 | evacuation에 비례 | 거의 일정(스택 루트만) |

> Garbage-First 논문 §3.1: "The write barrier ... records the modification in a per-thread sequential store buffer."

## 검증

JDK 21에서 두 GC의 로그 포맷을 직접 떠 보면 차이가 즉시 보인다.

```bash
# G1 (default since JDK 9, JEP 248)
java -Xlog:gc*=info -Xmx2g -XX:+UseG1GC App
# 로그 예: "Pause Young (Normal) (G1 Evacuation Pause) ... 8.2ms"

# ZGC
java -Xlog:gc*=info -Xmx2g -XX:+UseZGC App
# 로그 예: "Pause Mark Start 0.421ms" / "Pause Mark End 0.198ms"
```

핵심 관찰:

- G1의 pause 한 줄에 "Evacuation"이 들어가고 수 ms ~ 수십 ms 단위.
- ZGC의 pause는 **Mark Start / Mark End / Relocate Start** 셋만 있고 각각 1ms 미만, "Concurrent Mark" 같은 줄은 pause가 아닌 concurrent 단계.

간단한 allocation pressure 비교 (의사 코드):

```java
public class GcPause {
    static volatile Object sink;
    public static void main(String[] a) {
        long end = System.nanoTime() + 30L * 1_000_000_000L;
        while (System.nanoTime() < end) {
            // 1MB 배열을 빠르게 할당 → young 영역 압박
            sink = new byte[1 << 20];
        }
    }
}
// -XX:+UseG1GC vs -XX:+UseZGC 로 두 번 돌리고
// -Xlog:safepoint 로 application stop time 합계를 비교.
```

같은 30초 동안 ZGC 쪽 safepoint 누적 시간이 G1보다 자릿수 단위로 작게 찍히는 게 일반적이다 (Oracle docs §8.1의 설계 목표와 일치).

## 잘못 알고 있던 것

- **"ZGC는 STW가 0이다"** — 아니다. Mark Start / Mark End / Relocate Start는 STW다. 다만 스택 루트 스캔 + 단계 전환만 하기 때문에 **힙 크기와 거의 무관**하게 ms 미만 (Oracle docs §8.2).
- **"G1은 항상 전체 힙을 본다"** — 아니다. RSet 덕분에 evacuating할 region 집합(=Collection Set)에 대한 cross-region 참조만 스캔한다.
- **"컬러 포인터 = 64-bit 주소를 마음대로 쓰는 트릭"** — 좀 더 정확히는, x86_64에서 실제로 의미 있는 가상주소가 48비트 정도임을 이용해 **상위 비트에 GC bits를 넣고, mmap의 multi-mapping으로 같은 물리 페이지를 여러 가상주소에 매핑**한다 (OpenJDK Wiki — ZGC).

## 더 파고들 만한 것

- Generational ZGC (JEP 439)의 young/old 분리와 write barrier 비용 변화.
- Shenandoah와 ZGC의 비교 — Shenandoah는 **Brooks forwarding pointer**, ZGC는 **컬러 포인터**.
- G1의 humongous allocation 경로와 그로 인한 fragmentation.

## 참고

- Oracle HotSpot GC Tuning Guide (JDK 21): https://docs.oracle.com/en/java/javase/21/gctuning/
- "Garbage-First Garbage Collection" (ISMM 2004), Detlefs et al.
- JEP 333: ZGC: A Scalable Low-Latency Garbage Collector
- JEP 439: Generational ZGC
- OpenJDK Wiki — Main / ZGC pages
