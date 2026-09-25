# Kafka 프로듀서 Uniform Sticky 파티셔너: "새 배치마다 전환"에서 "batch.size 바이트마다 전환"으로, 그리고 큐 길이 역가중 적응형 선택

> **Primary source:** Apache Kafka 소스 `clients/.../producer/internals/BuiltInPartitioner.java`, `RecordAccumulator.java`, `KafkaProducer#partition`, `Sender.java`, `ProducerConfig.java` (apache/kafka trunk) / KIP-794: Strictly Uniform Sticky Partitioner
> **Secondary:** KIP-480: Sticky Partitioner
> **Date:** 2026-09-25
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/kafka-uniform-sticky-partitioner

## 왜 봤나

- 키 없는 레코드는 "라운드로빈으로 고르게 퍼진다"는 설명이 여전히 흔하다. 실제로는 KIP-480 sticky(새 배치 생성 시 전환)를 거쳐 KIP-794 uniform sticky(바이트 기준 전환 + 적응형 가중)로 바뀌었고, 후자는 **느린 브로커가 오히려 더 많은 데이터를 받는** 되먹임 버그를 고치려는 것이었다.
- "무엇을 기준으로 끊느냐"(배치 생성 vs 바이트)가 부하 분포를 어떻게 바꾸는지 소스로 따라가 본다.

## 핵심 한 문장

> 키 없는 레코드는 한 파티션에 `batch.size` 바이트만큼 붙어 있다가(sticky) 다음 파티션으로 넘어가며, 다음 파티션은 각 파티션 배치 큐 길이를 `(max+1 − 길이)`로 뒤집은 누적 빈도표에서 가중 랜덤으로 뽑혀 **밀린 브로커일수록 덜 선택된다.**

## 내부 동작

### 1. 파티션 결정 순서 (`KafkaProducer#partition`)

```
record.partition() != null         → 그대로 사용
partitioner.class 가 설정됨         → 커스텀 파티셔너 결과 (음수면 IllegalArgumentException)
key != null && !partitioner.ignore.keys
                                   → toPositive(murmur2(keyBytes)) % numPartitions
그 외                               → UNKNOWN_PARTITION  (결정을 RecordAccumulator에 미룸)
```

KIP-794 이후 `partitioner.class` 기본값은 `null`이다. 즉 **키 없는 레코드의 파티션은 `send()` 시점이 아니라 accumulator에 append하는 순간** `BuiltInPartitioner`가 정한다. 이 지연 결정이 바이트 카운팅과 큐 길이 정보를 쓸 수 있게 만드는 전제다.

### 2. KIP-480이 불균등했던 이유 — 전환 트리거가 브로커 지연의 역수

KIP-480 sticky는 "새 배치가 만들어질 때" 파티션을 바꿨다. KIP-794 Motivation의 분석을 인과 사슬로 정리하면:

```
브로커 B 잠깐 느려짐
  → B 파티션 배치가 전송되지 못하고 큐에 쌓임
  → 쌓인 배치는 전송 대기 중 가득 참 (새 배치가 늦게 생성됨)
  → "새 배치 생성" 이벤트가 늦게 옴 = B 에 머무는 sticky 시간이 김
  → B 가 더 많은 레코드를 받음 → 더 느려짐 → (runaway)
반면 빠른 브로커(linger.ms=0): 레코드 1개만 담긴 배치도 즉시 전송
  → 바로 새 배치 → 즉시 전환 → 적게 받음
```

KIP에 실린 실측(1시간, 3파티션)에서 배치 **개수**는 세 파티션이 거의 같았지만(1683/1713/1711), 느린 파티션 0의 배치당 바이트는 약 15.4KB, 나머지는 약 4.5KB였다. "배치 개수 균등 ≠ 바이트 균등"이 핵심이다. KIP는 이를 "neither uniform nor sufficiently sticky"라고 요약한다.

### 3. 전환 기준을 바이트로 — `StickyPartitionInfo`와 `updatePartitionInfo`

```java
// BuiltInPartitioner (발췌, 주석은 필자)
public static class StickyPartitionInfo {
    private final int index;                                   // 현재 sticky 파티션
    private final AtomicInteger producedBytes = new AtomicInteger();
}
private final AtomicReference<StickyPartitionInfo> stickyPartitionInfo;

void updatePartitionInfo(StickyPartitionInfo info, int appendedBytes,
                         Cluster cluster, boolean enableSwitch) {
    int producedBytes = info.producedBytes.addAndGet(appendedBytes);
    if (producedBytes >= stickyBatchSize && enableSwitch
            || producedBytes >= stickyBatchSize * 2) {         // 2배면 강제 전환
        stickyPartitionInfo.set(new StickyPartitionInfo(nextPartition(cluster)));
    }
}
```

- `stickyBatchSize`는 `KafkaProducer`가 `max(1, batch.size)`로 넘긴다(기본 `batch.size`=16384).
- 이제 전환은 **파티션에 실제로 쓴 바이트 수**로만 일어난다. 브로커가 느려도 빨라도 한 번 머물 때 받는 양은 ~`batch.size`로 같다 → 지연과 분배량의 되먹임이 끊긴다.
- `enableSwitch`는 `RecordAccumulator#updatePartitionInfoOnAppend`에서 `allBatchesFull(dq)`로 계산된다. 큐에 **덜 찬 배치가 남아 있으면 전환을 미룬다** — 방금 붙은 파티션에 반쯤 찬 배치를 남기고 떠나면 작은 배치가 늘어나기 때문이다. 대신 `2 × batch.size`에 도달하면 무조건 전환해 한 파티션에 무한정 머무는 것을 막는다.
- 전환이 보류됐던 경우는 다음 append의 `partitionChanged()`에서 `allBatchesFull`이면 `appendedBytes=0`으로 다시 `updatePartitionInfo`를 호출해 "밀린 전환"을 완료한다.

동시성: `peekCurrentPartitionInfo`는 락 없이 현재 객체를 읽고(없으면 CAS로 생성), 실제 append는 파티션 deque 락 안에서 한다. 락을 잡은 뒤 `isPartitionChanged`로 **객체 identity**가 바뀌었는지 확인하고, 바뀌었으면 다른 스레드가 이미 전환한 것이므로 재시도한다. 파티션 번호가 아니라 객체 참조를 비교하기 때문에 우연히 같은 파티션이 다시 뽑혀도 "전환 발생"을 구분할 수 있다.

### 4. 다음 파티션 고르기 — 큐 길이 역가중 누적 빈도표

`RecordAccumulator#ready()`가 돌 때마다 토픽별로 각 파티션 deque 길이(`queueSizes`)를 모아 `updatePartitionLoadStats`에 넘긴다. 그 안에서:

1. 모든 큐 길이가 같고 전부 available이면 → stats를 `null`로 (균등 랜덤)
2. 아니면 `invertAndFoldQueueSizeArray`로 **제자리에서** 뒤집고 누적:

```
CFT[0] = (max+1) − q[0]
CFT[i] = (max+1) − q[i] + CFT[i−1]
```

`nextPartition`은 `r = random % CFT[last]`를 뽑고 `Arrays.binarySearch` 결과를 `abs(result + 1)`로 바꿔 **CFT[i] > r 인 첫 i**를 고른다.

```
파티션      p0   p1   p2
큐 길이      1    5    2      max=5 → max+1=6
가중치 6−q   5    1    4
CFT          5    6   10      r ∈ [0,10)
r 구간     [0,5) [5,6) [6,10)
선택 확률   50%  10%  40%     ← 밀린 p1은 가장 덜 뽑힌다
```

`+1` 덕분에 가장 밀린 파티션도 가중치가 최소 1이라 굶지 않는다. 큐 길이는 drain 지연의 대리지표이므로, KIP-480의 양의 되먹임을 음의 되먹임으로 뒤집은 셈이다. `partitioner.adaptive.partitioning.enable=false`면 이 가중을 쓰지 않고 균등 랜덤이다(기본 `true`).

### 5. 가용성 배제 — `partitioner.availability.timeout.ms`

`Sender`는 노드마다 `NodeLatencyStats{readyTimeMs, drainTimeMs}`를 갱신한다. 배치는 준비됐는데 `client.ready(node)`가 false면 `readyTimeMs`만, 보낼 수 있으면 둘 다 갱신한다. 따라서 `readyTimeMs − drainTimeMs`는 "데이터가 이 노드를 기다린 시간"이다. 이 값이 `partitioner.availability.timeout.ms`(기본 0=비활성)를 넘으면 `ready()`가 `--queueSizesIndex`로 그 파티션을 CFT 후보에서 뺀다.

rack-aware(`partitioner.rack.aware`, 기본 false)면 같은 rack 리더 파티션만으로 별도 CFT(`inThisRack`)를 만들어 우선 사용한다.

## 검증

(a) 소스 추적: `BuiltInPartitioner`의 `updatePartitionInfo`·`invertAndFoldQueueSizeArray`·`nextPartition`, `RecordAccumulator`의 `updatePartitionInfoOnAppend`(`allBatchesFull`은 deque 마지막 배치만 `isFull()` 검사)와 `ready()` 말미의 `updatePartitionLoadStats(..., queueSizesIndex + 1)`.

(b) 직접 재현(JShell): 위 표를 코드로 확인한다.

```java
int[] q = {1, 5, 2};
int maxPlus1 = java.util.Arrays.stream(q).max().getAsInt() + 1;
int[] cft = new int[q.length];
cft[0] = maxPlus1 - q[0];
for (int i = 1; i < q.length; i++) cft[i] = maxPlus1 - q[i] + cft[i - 1];
int[] hit = new int[q.length];
for (int r = 0; r < cft[q.length - 1]; r++) {
    int idx = Math.abs(java.util.Arrays.binarySearch(cft, 0, q.length, r) + 1);
    hit[idx]++;
}
System.out.println(java.util.Arrays.toString(cft) + " " + java.util.Arrays.toString(hit));
// 기대: [5, 6, 10] [5, 1, 4]
```

(c) 실제 프로듀서: 로그 레벨을 `org.apache.kafka.clients.producer.internals.BuiltInPartitioner=TRACE`로 두면 `Switching to partition ...`, `Partition load stats for topic ...: CFT=...` 로그로 전환 시점과 CFT를 관찰할 수 있다. 한 브로커에 `tc qdisc`로 지연을 주면 그 리더 파티션의 CFT 가중이 줄어드는지 볼 수 있다.

## 잘못 알고 있던 것

- **"키 없는 레코드는 라운드로빈"** → 현재 기본은 라운드로빈도 KIP-480 sticky도 아니다. `batch.size` 바이트 단위로 붙어 있다가, 큐 길이 역가중 랜덤으로 다음 파티션을 고른다. `RoundRobinPartitioner`는 명시적으로 `partitioner.class`에 지정해야 쓰인다.
- **"sticky 전환 기준 = 새 배치 생성"** → 그게 KIP-480의 버그 원인이었다. 배치 생성 빈도는 브로커 drain 속도에 비례하므로 느린 브로커가 sticky 시간을 더 가져갔다. 지금은 바이트 기준이며, 덜 찬 배치가 있으면 전환을 미루되 `2 × batch.size`에서 강제 전환한다.
- **"UniformStickyPartitioner를 설정하면 최신 동작"** → deprecated다. `partitioner.class`를 비우고 `partitioner.ignore.keys=true`를 준다(KIP-794 권고).

## 더 파고들 만한 것

- `RecordAccumulator#ready`의 `batchReady` 판정(linger 만료·full·exhausted·backoff)과 `drain`의 노드별 라운드 순회 — 파티셔너가 만든 큐 길이가 어떻게 줄어드는지.
- `BufferPool`의 `batch.size` 단위 free list와 `max.block.ms` 블로킹 — 적응형 선택이 메모리 압박과 어떻게 상호작용하는지.

## 참고

- KIP-794: Strictly Uniform Sticky Partitioner (Motivation의 3파티션 실측 표·새 설정 정의)
- KIP-480: Sticky Partitioner
- `ProducerConfig.java` (위 설정들의 기본값 정의)
