# JVM Memory Layout: Heap / Metaspace / Stack

> **Primary source:** Java Virtual Machine Specification (Java SE 17) §2.5 "Run-Time Data Areas", Oracle HotSpot VM Garbage Collection Tuning Guide (Java 17)
> **Secondary:** OpenJDK HotSpot 소스 (`src/hotspot/share/memory/`), JEP 122 (Remove the Permanent Generation)
> **Date:** 2026-05-27
> **Status:** draft

## 왜 봤나

- "Heap 크면 OOM 안 나는 거 아닌가?" 같은 질문에 명확히 답하려면 영역별 분리를 다시 정리해야 한다고 느꼈다.
- Metaspace가 Java 8에서 PermGen을 대체했다는 사실은 알지만, **왜 native memory로 옮겼는지**, **그래서 어떤 OOM이 사라지고 어떤 OOM이 새로 등장했는지**를 출처로 정리해두고 싶었다.

## 핵심 한 문장

> JVM의 런타임 메모리는 JVM Specification §2.5에 정의된 **스레드 공유 영역(Heap, Method Area)** 과 **스레드별 영역(PC Register, JVM Stack, Native Method Stack)** 으로 나뉘며, HotSpot은 이를 Heap(Young/Old)·Metaspace·Stack·Code Cache 등으로 구현한다.

## 내부 동작

### 1. JVM Specification이 정의한 런타임 영역

JVM Specification §2.5에 따르면 런타임 데이터 영역은 **스레드 공유 영역(Heap §2.5.3, Method Area §2.5.4)** 과 **스레드별 영역(PC Register §2.5.1, JVM Stack §2.5.2, Native Method Stack §2.5.6)** 으로 나뉜다. Run-Time Constant Pool(§2.5.5)은 Method Area 내부.

스펙은 **"Heap을 어떻게 잘게 나누는지", "GC 알고리즘이 무엇인지"는 구현체에 위임**한다. HotSpot은 이를 Young/Old generational heap, Metaspace, Code Cache 등으로 구현한 것이다.

### 2. HotSpot의 실제 메모리 레이아웃 (ASCII)

```
+--------------------------------------------------+
|              JVM Process (RSS)                   |
|  +--------------------------------------------+  |
|  |               Java Heap (-Xmx)             |  |
|  |  +-----------------------+  +-----------+  |  |
|  |  | Young: Eden | S0 | S1 |  |  Old Gen  |  |  |
|  |  +-----------------------+  +-----------+  |  |
|  +--------------------------------------------+  |
|                                                  |
|  +----------------+  +-------------------------+ |
|  |  Metaspace     |  |  Code Cache (JIT)       | |
|  |  (native heap) |  |  non/profiled nmethods  | |
|  +----------------+  +-------------------------+ |
|                                                  |
|  +----------------+  +-------------------------+ |
|  | Thread Stacks  |  | Direct Memory (NIO)     | |
|  | (per-thread)   |  | + GC meta, JNI handles  | |
|  +----------------+  +-------------------------+ |
+--------------------------------------------------+
```

### 3. Heap: Young / Old 의 자료구조와 할당 경로

HotSpot Garbage Collection Tuning Guide에 따르면 대부분의 GC(Serial, Parallel, G1)는 **세대 가설(weak generational hypothesis: 대부분의 객체는 짧게 산다)** 에 기반한 generational heap을 유지한다.

- **Young Generation**: Eden + Survivor 0/1 (To/From)
  - 새 객체는 기본적으로 Eden에 할당.
  - **TLAB(Thread Local Allocation Buffer)**: 각 스레드는 Eden 안에 자기 전용 chunk를 받아 bump-the-pointer로 할당 → 락 없이 빠르게.
    - HotSpot 소스 `share/gc/shared/threadLocalAllocBuffer.cpp` 참고.
  - Minor GC(Young GC)는 Eden + 한쪽 Survivor의 live object를 다른 Survivor로 copy.
- **Old Generation (Tenured)**: Young에서 일정 횟수 살아남은 객체가 promotion되어 옮겨오는 영역.
  - 임계치는 `-XX:MaxTenuringThreshold` (기본값은 GC와 버전에 따라 다름).
- **G1 GC**는 위 세대 구분을 유지하되, **Region 단위(보통 1~32MB)**로 heap을 쪼개고 Region마다 Eden/Survivor/Old/Humongous 역할을 부여하는 점이 Parallel/Serial과 다르다.

### 4. Metaspace: PermGen이 사라진 이유

JEP 122에 따르면 Java 8에서 **PermGen이 제거되고 Metaspace로 대체**되었다. 주요 변경점:

| 항목 | PermGen (Java 7-) | Metaspace (Java 8+) |
| --- | --- | --- |
| 위치 | Java Heap 내부의 고정 영역 | **Native memory** (프로세스 일반 heap) |
| 기본 크기 제한 | `-XX:MaxPermSize` (보통 64-82MB) | 무제한 (단 `-XX:MaxMetaspaceSize`로 상한 설정 가능) |
| 저장 내용 | Class metadata, interned String, static field | Class metadata만 (Interned String/static은 Java Heap으로 이동) |
| OOM 메시지 | `java.lang.OutOfMemoryError: PermGen space` | `java.lang.OutOfMemoryError: Metaspace` |

> **왜 옮겼나** — Oracle 발표(JEP 122)는 (1) PermGen 사이즈 튜닝의 어려움, (2) interned String이 PermGen에 묶여 발생하는 OOM, (3) HotSpot/JRockit 통합을 이유로 들고 있다.

Metaspace 내부는 **chunk-based allocator**로 알려져 있다 (OpenJDK `share/memory/metaspace/` 참고). ClassLoader 단위로 metaspace chunk를 들고 있다가 ClassLoader가 unload되면 해당 chunk가 반환된다.

### 5. Stack: 프레임의 자료구조

JVM Specification §2.6에 따르면 각 메서드 호출마다 **stack frame**이 push된다. 한 프레임은 (1) **Local Variable Array** (this/인자/지역변수, long·double는 2칸 차지), (2) **Operand Stack** (바이트코드의 작업 공간), (3) **Frame Data** (constant pool ref, return address)로 구성된다.

- 프레임 크기는 **컴파일 시점에 결정**된다 (class file의 `max_locals`, `max_stack` 속성).
- Stack은 스레드별로 분리 → 지역변수는 본질적으로 스레드 안전.
- 깊은 재귀: `StackOverflowError`. 스레드 자체 생성 실패: `OutOfMemoryError: unable to create new native thread`.
- `-Xss`로 스택 크기 조정 (HotSpot 기본값은 OS/아키텍처에 따라 256KB~1MB로 알려져 있다).

### 6. 그 외: Code Cache / Direct Memory

- **Code Cache**: JIT이 만든 nmethod(native method) 코드를 보관. JEP 197(Segmented Code Cache, Java 9+)로 non-nmethods / profiled / non-profiled 세 segment로 나뉘었다.
- **Direct Memory**: `ByteBuffer.allocateDirect()`나 NIO가 사용하는 native buffer. Java Heap 밖이므로 `-Xmx`로 제한되지 않고 `-XX:MaxDirectMemorySize`로 제어된다.

## 검증

`jcmd <pid> VM.native_memory` (NMT) 또는 `jcmd <pid> GC.heap_info`로 영역별 크기를 직접 확인 가능. JMX `MemoryPoolMXBean`으로도 풀별 사용량을 읽을 수 있다.

```java
// examples/MemoryAreaInspect.java
MemoryMXBean bean = ManagementFactory.getMemoryMXBean();
System.out.println("Heap: " + bean.getHeapMemoryUsage());
System.out.println("Non-Heap: " + bean.getNonHeapMemoryUsage());
for (MemoryPoolMXBean pool : ManagementFactory.getMemoryPoolMXBeans()) {
    System.out.printf("%-25s type=%s usage=%s%n",
            pool.getName(), pool.getType(), pool.getUsage());
}
```

실행 시 다음과 같은 풀 이름이 나오는 것으로 알려져 있다(GC 종류에 따라 다름): `G1 Eden Space`, `G1 Survivor Space`, `G1 Old Gen`, `Metaspace`, `Compressed Class Space`, `CodeHeap 'profiled nmethods'` 등. `-Xlog:gc*` (Unified Logging)로 GC 발생 시점의 영역별 변화도 추적 가능.

## 잘못 알고 있던 것

- ❌ "Metaspace는 Heap의 일부다" → 실제로는 **native memory**다. `-Xmx`로 제한되지 않고, NMT의 "Class" 카테고리에 잡힌다.
- ❌ "Stack은 모든 스레드가 공유한다" → 정반대로 **스레드별 분리**. JVM Spec §2.5.2에 명시.
- ❌ "PermGen = Metaspace 이름만 바꾼 것" → 위치(heap→native), 저장 내용(interned String 제거), 크기 정책이 모두 다르다.

## 더 파고들 만한 것

- TLAB의 refill 알고리즘과 sizing(`-XX:+ResizeTLAB`, `-XX:TLABSize`)이 **할당 throughput**에 어떻게 영향을 주는지.
- G1 GC vs ZGC 알고리즘 차이 (다음 backlog 항목).
- Compressed Class Pointers / Compressed Oops가 Metaspace와 Heap 크기에 미치는 영향.

## 참고

- Java Virtual Machine Specification (Java SE 17), §2.5 / §2.6
- Oracle, "HotSpot Virtual Machine Garbage Collection Tuning Guide" (Java 17)
- JEP 122: Remove the Permanent Generation — https://openjdk.org/jeps/122
- JEP 197: Segmented Code Cache
- OpenJDK 소스: `src/hotspot/share/memory/metaspace/`, `src/hotspot/share/gc/shared/threadLocalAllocBuffer.cpp`

---

<!-- velog 글로 발전 후 -->
**velog 글:** _(미작성)_
