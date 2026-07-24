# JVM TLAB(Thread-Local Allocation Buffer): 객체 할당이 락 없이 포인터 하나 올리는 일이 되는 법

> **Primary source:** OpenJDK HotSpot 소스 `gc/shared/threadLocalAllocBuffer.{hpp,cpp}` · `gc/shared/collectedHeap.inline.hpp`(mem_allocate/allocate_from_tlab) · `runtime/globals.hpp`(TLAB 플래그)
> **Secondary:** Oracle "HotSpot GC Tuning" TLAB 절 · Aleksey Shipilëv "JVM Anatomy Quark #4: TLAB allocation"
> **Date:** 2026-07-24
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/jvm-tlab-allocation

## 왜 봤나

"객체 할당은 비싸다"는 통념과, 실측하면 대부분의 할당이 거의 공짜인 현실이 안 맞았다. GC가 압축(compaction)으로 eden을 항상 연속 빈 공간으로 유지한다는 건 알았는데, 그러면 멀티스레드가 그 하나의 top 포인터를 어떻게 경합 없이 나눠 쓰는지가 빠져 있었다. 그 빈칸이 TLAB였다.

## 핵심 한 문장

> TLAB은 각 스레드가 eden에서 미리 잘라 받은 사유 구획으로, 그 안에서의 할당은 CAS 없이 `top += size` 한 번(bump-the-pointer)이면 끝나고, 구획이 차면 그때만 공유 eden에 대한 원자적 연산으로 새 구획을 떼어 온다.

## 내부 동작

### 1. 두 겹의 bump-the-pointer

압축형(또는 복사형) 컬렉터의 eden은 항상 "연속 free 영역 + 경계 포인터"로 유지된다. 할당의 본질은 `top` 포인터를 객체 크기만큼 밀고 이전 값을 반환하는 것뿐이다.

문제는 공유. N개 스레드가 같은 eden `top`을 밀면 매 할당이 CAS 경합이 된다. HotSpot은 이를 **2단계**로 쪼갠다.

```
eden:  [ ###사용### | T0 TLAB | T1 TLAB | ... |  free  ]
                              ^_start  ^_top   ^_end
                                     (스레드 T1 사유)
공유 경합: eden의 free에서 TLAB 한 덩이 떼기 = CAS 1회 (드묾)
무경합  : TLAB 내부 top 밀기 = 그냥 store   (거의 항상)
```

- **fast path (TLAB 내부):** `if (top + size <= end) { obj = top; top += size; }` — 스레드 사유 메모리라 원자성 불필요. JIT가 인라인해서 몇 개 명령으로 컴파일한다.
- **slow path (TLAB 초과):** eden free에서 새 TLAB를 CAS로 확보(공유 경합은 여기서만 발생).

### 2. slow path의 갈림: refill이냐, TLAB 밖 할당이냐

TLAB이 꽉 찼다고 무조건 새로 받으면, 현재 TLAB에 남은 꼬리 공간이 통째로 버려진다(**internal fragmentation**). HotSpot은 남은 공간과 임계값을 비교해 결정한다(소스 `ThreadLocalAllocBuffer`, `allocate_from_tlab_slow`):

- 남은 free가 `refill_waste_limit`보다 **크면** → 지금 TLAB은 그대로 두고(버리기 아까움) 이 객체만 **공유 eden에 직접** 할당.
- 남은 free가 임계값보다 **작으면** → 현재 TLAB를 retire(폐기)하고 새 TLAB로 교체(refill).

여기엔 굶주림 방지 장치가 있다. 매번 "밖에서 할당"만 택하면 영원히 refill을 안 해 fast path를 못 타므로, 밖에서 할당할 때마다 `refill_waste_limit`을 조금씩 **올린다**. 결국 임계값이 남은 공간을 넘어서면 refill이 강제된다.

큰 객체(fresh TLAB에도 안 들어갈 크기)는 아예 TLAB 대상이 아니라 곧장 공유 힙/eden에 간다.

### 3. retire = 힙을 파스 가능하게 유지하기 (dummy filler)

GC와 힙 워킹은 eden을 **선형으로 훑으며** "여기부터 객체, 그 klass로 크기 계산, 다음 객체..."를 반복한다. 그런데 retire되는 TLAB의 남은 꼬리는 아무 객체도 없는 구멍이라, 그대로 두면 워커가 그 바이트를 klass 포인터로 오해한다.

그래서 HotSpot은 retire 시 남은 공간을 **filler 객체**(보통 `int[]`, 아주 작으면 filler 인스턴스)로 채운다(`CollectedHeap::fill_with_object`). 즉 버려지는 공간에도 "여기는 그냥 죽은 배열"이라는 파스 가능한 헤더가 박힌다. 이게 TLAB 낭비가 **CPU가 아니라 메모리**로 나타나는 이유다.

retire는 TLAB이 꽉 차서 교체될 때만이 아니라 **GC 직전에도** 일어난다. 컬렉터가 eden을 훑기 전에 모든 스레드의 현재 TLAB을 filler로 마감(`make_parsable`)해야 힙 전체가 선형 워킹 가능해지기 때문이다. TLAB의 낭비 카운터는 그래서 세 갈래로 집계된다.

| 낭비 종류 | 언제 | 의미 |
| --- | --- | --- |
| fast waste | refill로 retire할 때 꼬리 | 정상 운영 중 버려진 꼬리 |
| slow waste | TLAB 밖 할당(§2) | refill을 미룬 대가 |
| gc waste | GC 직전 make_parsable | 아직 안 찬 TLAB의 미사용분 |

### 4. 크기는 고정이 아니라 적응형(EMA)

TLAB이 너무 크면 스레드당 eden을 선점해 GC가 잦아지고, 너무 작으면 refill(=공유 경합)이 잦아진다. HotSpot은 스레드별 할당 이력의 지수이동평균(EMA)으로 다음 epoch(대개 GC 사이)의 목표 크기를 다시 계산한다. 대략의 목표는:

```
desired_tlab_size ≈ eden_free / (n_threads × target_refills_per_epoch)
```

- 스레드 수가 늘면 각 TLAB은 작아진다(공평 분배).
- `-XX:TLABWasteTargetPercent`(기본 1로 알려져 있음): 낭비 목표 비율. `refill_waste_limit`은 `tlab_size / TLABRefillWasteFraction`(기본 64)에서 출발한다 — 두 축이 위 §2의 임계값을 조율한다.
- `-XX:-UseTLAB`로 끄면 모든 할당이 공유 경합 경로로 떨어져 멀티스레드에서 급격히 느려진다. `-XX:+PrintTLAB`(또는 gc+tlab 로깅)로 refill 횟수·slow_allocations·waste를 볼 수 있다.

### 5. allocation prefetch

bump 할당은 순차적이라 다음 할당 주소가 예측된다. HotSpot은 `-XX:AllocatePrefetchStyle/Distance/Lines`로 `top` 앞쪽 캐시 라인을 미리 prefetch해, 새 객체를 zero-init하고 채울 때 캐시 미스를 줄인다.

## 검증

소스의 결정 흐름(`threadLocalAllocBuffer.cpp`의 `allocate_from_tlab_slow`, `collectedHeap.inline.hpp`의 `allocate_from_tlab`)을 따라가면 위 §2 갈림이 그대로 나온다. 동작을 확인하는 사고 실험:

```java
// 32B짜리 객체를 대량 할당. TLAB=... 라고 가정.
for (int i = 0; i < 100_000_000; i++) { new byte[16]; } // 헤더+16 ≈ 32B
```
- 거의 모든 반복이 fast path(`top += 32`)라 스레드가 늘어도 선형 확장된다.
- `-XX:+UseTLAB`(기본)와 `-XX:-UseTLAB`를 비교하면 후자가 코어 수 늘수록 CAS 경합으로 급락.
- `-Xlog:gc+tlab=trace`(또는 `-XX:+PrintTLAB`)에서 스레드별 `refills`, `slow allocs`, `waste`(gc/slow/fast 낭비) 카운터를 확인하면, refill이 드물고 waste가 TLABWasteTargetPercent 근처로 수렴함을 볼 수 있다.

## 잘못 알고 있던 것

- **"객체 할당은 malloc처럼 free list를 뒤져 빈 칸을 찾는다."** 아니다. 압축형 힙에서 fast path 할당은 free list 탐색이 전혀 없고 포인터 증가 한 번이다. 빈 칸 관리는 할당이 아니라 GC(compaction)가 몰아서 한다.
- **"TLAB이 크면 항상 좋다(경합이 줄어드니까)."** 크면 refill 경합은 줄지만 스레드가 eden을 선점해 GC 빈도가 오르고, retire 시 filler로 버려지는 꼬리 낭비도 커진다. 그래서 고정이 아니라 EMA로 조율한다.
- **"TLAB에 남는 공간은 그냥 비어 있다."** 비어 있으면 힙이 파스 불가능해진다. retire된 꼬리는 dummy `int[]` filler로 채워져 GC가 선형 워킹할 수 있게 된다.
- **"큰 객체도 TLAB에서 나온다."** fresh TLAB에도 안 들어가는 크기는 처음부터 공유 힙 경로로 간다(§2).

## 더 파고들 만한 것

- Eden→Survivor 복사(scavenge)에서 각 GC 스레드가 쓰는 **PLAB(Promotion/Parallel LAB)** — TLAB의 GC 버전.
- G1의 region 기반 할당에서 TLAB이 region 경계와 만나는 지점, humongous 객체 처리.
- `-XX:+ZeroTLAB`, allocation prefetch 튜닝이 실제 워크로드에서 주는 차이.

## 참고

- OpenJDK HotSpot: `src/hotspot/share/gc/shared/threadLocalAllocBuffer.{hpp,cpp}`, `collectedHeap.inline.hpp`, `runtime/globals.hpp`
- Oracle, "HotSpot Virtual Machine Garbage Collection Tuning Guide" — TLAB 절
- Aleksey Shipilëv, "JVM Anatomy Quark #4: TLAB allocation"
