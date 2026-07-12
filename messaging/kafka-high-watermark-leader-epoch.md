# Kafka High Watermark와 Leader Epoch: 커밋 경계는 어떻게 정해지고, 리더가 바뀔 때 로그는 어떻게 잘리나

> **Primary source:** Apache Kafka Documentation (Replication / Design) · KIP-101 (Leader Epochs and truncation) · KIP-279 (fix stale-follower divergence) · Kafka 소스 `ReplicaManager`·`Partition`·`LeaderEpochFileCache`
> **Secondary:** Confluent 블로그 "Hardening Kafka Replication", Jason Gustafson 발표 자료
> **Date:** 2026-07-12
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/kafka-high-watermark-leader-epoch

## 왜 봤나

- `acks=all`이면 데이터가 안 없어진다고만 알고 있었는데, "컨슈머가 어디까지 읽을 수 있나"를 정하는 High Watermark(HW)와 acks의 관계가 흐릿했다.
- 예전 Kafka에서 리더가 바뀔 때 로그가 **잘못 잘려서(truncate)** 복제본끼리 내용이 달라지는 버그가 있었다고 들었는데, Leader Epoch가 그걸 어떻게 고쳤는지 원리를 몰랐다.

## 핵심 한 문장

> HW는 "모든 ISR이 복제를 마친 오프셋 경계"라 컨슈머의 가시성을 정하고, Leader Epoch는 "이 로그의 각 구간을 어느 세대 리더가 썼는가"를 기록해 리더 교체 시 HW만 보고 자르던 방식의 오차(데이터 손실·분기)를 없앤다.

## 내부 동작

### 로그 오프셋 세 가지: LEO / HW / (log start)

각 복제본(replica)은 자기 로그에 대해 **LEO(Log End Offset)** 를 가진다 — 다음에 append될 오프셋, 즉 마지막 레코드 + 1.

- **리더의 LEO**: 프로듀서가 보낸 레코드를 append하면 즉시 증가.
- **팔로워의 LEO**: 팔로워가 리더에서 fetch해 자기 로그에 쓴 만큼 증가.

**High Watermark(HW)** 는 리더가 관리하는 값으로, **현재 ISR(In-Sync Replicas)에 속한 모든 복제본이 복제를 마친 최소 오프셋**이다. 정확히는:

```
HW = min(LEO of all replicas in ISR)
```

컨슈머는 **HW 미만까지만** 읽을 수 있다. HW 이상은 "아직 모든 ISR에 안 퍼진, 유실 가능성이 있는" 구간이라 노출하지 않는다(= committed 여부의 경계).

```
리더 로그:   [0][1][2][3][4][5]      LEO=6
팔로워B:     [0][1][2][3]            LEO=4
팔로워C:     [0][1][2][3][4]         LEO=5
ISR={L,B,C}  →  HW = min(6,4,5) = 4
                컨슈머는 오프셋 0~3까지만 볼 수 있음
```

### HW는 어떻게 앞으로 나아가나 (fetch 기반 전파)

팔로워는 리더에게 `Fetch` 요청을 보낼 때 **자기 LEO를 fetch offset으로 실어 보낸다**. 이게 곧 "나는 여기까지 받았다"는 ACK 역할을 한다.

1. 팔로워B가 `Fetch(offset=4)` 를 보냄 → 리더는 "B의 LEO=4" 로 기록.
2. 리더는 ISR 전체의 LEO 중 최소값으로 HW를 다시 계산해 갱신.
3. 리더는 응답에 **자신의 최신 HW를 함께 실어** 보냄.
4. 팔로워는 응답의 HW를 받아 자기 HW를 갱신.

여기서 중요한 비대칭이 있다: **팔로워의 HW는 리더보다 항상 한 라운드 늦다.** 팔로워는 다음 fetch 응답을 받아야 방금 올라간 HW를 안다. 이 "HW 전파 지연"이 뒤에 나올 truncation 문제의 씨앗이다.

### acks=all 과 HW의 관계

`acks=all`은 프로듀서 응답 조건이다: 리더가 **`min.insync.replicas` 개수 이상의 ISR에 복제될 때까지** 프로듀서에게 ack를 안 준다. 즉 프로듀서 ack가 나가는 시점은 대략 HW가 그 레코드 위로 올라간 시점과 맞물린다. 그래서 `acks=all` + `min.insync.replicas>=2`면 "컨슈머가 볼 수 있는 데이터(HW 미만)는 최소 2벌 존재"가 보장된다.

### 리더가 바뀌면: HW 기반 truncation의 함정

리더가 죽고 팔로워 중 하나가 새 리더가 되면, 옛 데이터가 서로 어긋날 수 있다. 과거 Kafka(0.11 이전)의 규칙은 단순했다: **새 리더로 붙는 팔로워는 자기 HW까지 로그를 자르고 그 뒤를 리더에서 다시 받는다.** 문제는 위에서 본 "HW 전파 지연" 때문에 팔로워의 HW가 실제보다 낮게 기억될 수 있다는 점이다.

시나리오(데이터 손실):

```
① L(리더) LEO=2, HW=1 / F(팔로워) LEO=2, HW=1 이 되기 직전
   L은 오프셋1을 복제받아 HW=2로 올렸지만, F는 아직 HW=1로 알고 있음
② L 다운. F가 새 리더로 승격 (F의 LEO=2)
③ 옛 L이 살아나 F에 붙음. 옛 L은 자기 HW(=1)까지 truncate → 오프셋1 버림
④ 이제 F(신 리더)에서 다시 fetch. 만약 이 사이 F가 오프셋1을 다른 내용으로 덮었다면
   두 로그는 조용히 분기(divergence)하거나, 커밋됐던 레코드가 사라짐
```

핵심 원인: **HW라는 "높이(offset)" 정보만으로는 "그 오프셋을 어느 리더가 썼는지"를 구분 못 한다.** 오프셋 1이 옛 리더가 쓴 1인지 새 리더가 쓴 1인지 알 수 없으니, 잘라야 할지 유지할지 안전하게 판단할 수 없다.

### Leader Epoch: 오프셋에 "세대"를 붙이다 (KIP-101)

Leader Epoch는 **단조 증가하는 정수**로, 리더가 새로 선출될 때마다 +1 된다(컨트롤러가 부여). 각 복제본은 로그와 별도로 `leader-epoch-checkpoint` 파일에 **(epoch, 그 epoch가 시작된 첫 오프셋)** 쌍의 목록을 유지한다.

```
leader-epoch-checkpoint (예)
epoch=5  startOffset=0
epoch=6  startOffset=2      # epoch 6 리더가 오프셋 2부터 쓰기 시작
epoch=7  startOffset=5
```

이제 리더 교체 후 팔로워는 HW로 자르지 않고 **OffsetsForLeaderEpoch** 요청으로 자른다:

1. 팔로워는 자기 로그의 **마지막 epoch**를 새 리더에게 물어본다: "epoch=6의 끝은 어디냐?"
2. 리더는 "epoch=6은 offset 5에서 끝난다(= 그다음 epoch가 5에서 시작)"처럼 **epoch의 끝 오프셋**을 답한다.
3. 팔로워는 자기 LEO와 그 답 중 **작은 값까지만** truncate. 즉 "내가 이 epoch에서 리더보다 더 썼다면, 그 초과분만 잘라낸다."

이러면 HW의 지연과 무관하게, **같은 epoch에서 리더와 팔로워가 공유하는 지점까지는 보존**되고 분기 지점만 정확히 잘린다. 오프셋 높이가 아니라 "세대 경계"로 자르기 때문이다.

```
분기 예: 팔로워가 epoch=6에서 offset 5,6,7을 더 갖고 있는데
새 리더의 epoch=6 끝이 offset 5라면 → 팔로워는 offset 5까지 유지, 6,7만 truncate
그 위는 새 리더의 새 epoch 레코드로 채워짐 → 분기 제거
```

### KIP-279: 리더끼리 엇갈릴 때의 구멍 메우기

KIP-101만으로도 대부분 해결됐지만, **연속으로 리더가 두 번 바뀌어** 팔로워가 물어본 epoch를 새 리더가 아예 모르는 경우(그 epoch를 건너뛴 경우)가 남았다. KIP-279는 리더가 "그 epoch를 모르면, **자기가 아는 그보다 작은 epoch의 시작 오프셋**을 돌려주게" 해서 팔로워가 더 아래로 안전하게 내려가 다시 맞추도록 했다. 결과적으로 어떤 리더 교체 시퀀스에서도 로그 분기가 수렴한다.

## 검증

Kafka 소스에서 흐름을 따라가면:

- `kafka.cluster.Partition#maybeIncrementLeaderHW` — ISR 각 복제본의 LEO를 모아 `min`을 취해 HW를 올린다. ISR에서 빠진(느린) 복제본은 계산에서 제외되므로, ISR 축소가 HW를 앞으로 나아가게 하는 것도 여기서 보인다.
- `kafka.server.ReplicaFetcherThread` → 팔로워가 truncate 전에 `OffsetsForLeaderEpoch`를 호출하는 경로.
- `LeaderEpochFileCache#endOffsetFor(epoch)` — 주어진 epoch의 끝(다음 epoch 시작) 오프셋을 반환. 여기가 KIP-101 truncation의 판단 지점.

개념 검증(로그로 확인 가능한 예상 동작):

```
# 3-broker 클러스터, RF=3, min.insync.replicas=2
# 팔로워 하나를 network partition으로 격리하면
#  → ISR에서 빠지고, HW는 남은 ISR의 min(LEO)로 계속 전진
#  → 격리 복제본이 복귀하면 OffsetsForLeaderEpoch로 자기 로그를 맞춘 뒤 ISR 재합류
kafka-log-dirs.sh --describe ...   # 각 replica의 LEO 확인
# __consumer_offsets / 대상 토픽 파티션의 leader-epoch-checkpoint 파일을 열면
# (epoch,startOffset) 목록이 쌓이는 것을 직접 볼 수 있다
```

## 잘못 알고 있던 것

- **"acks=all이면 컨슈머가 즉시 그 레코드를 본다"** — 아니다. 프로듀서 ack와 컨슈머 가시성은 둘 다 HW에 묶여 있지만, 팔로워의 HW는 리더보다 한 fetch 라운드 늦게 갱신된다. 컨슈머가 붙은 복제본(팔로워 fetch를 쓰는 경우)이나 타이밍에 따라 "커밋은 됐는데 아직 안 보이는" 짧은 창이 존재한다.
- **"리더 교체 때는 그냥 HW까지 잘라 맞추면 된다"** — 이게 정확히 데이터 손실·분기의 원인이었다. HW는 offset 높이일 뿐 세대 정보가 없어, 옛 리더가 쓴 오프셋과 새 리더가 쓴 오프셋을 구분 못 한다. 그래서 Leader Epoch(세대 경계)로 자르는 방식으로 바뀌었다.
- **"HW는 리더의 LEO와 같다"** — 리더 LEO ≥ HW다. 리더가 방금 append한 레코드는 아직 어떤 팔로워도 못 받았으니 HW 위에 있고, ISR 전체가 따라잡아야 HW가 그 위로 올라간다.

## 더 파고들 만한 것

- ISR 축소/확장 판정(`replica.lag.time.max.ms`)과 그것이 HW 전진·가용성에 주는 영향.
- `unclean.leader.election.enable=true`일 때 ISR 밖 복제본이 리더가 되며 커밋 데이터가 날아가는 경로 — Leader Epoch로도 못 막는, 의도적 가용성-내구성 트레이드오프.
- KRaft 모드에서 메타데이터(리더/epoch) 자체가 Raft 로그로 관리될 때 이 그림이 어떻게 바뀌는가.

## 참고

- Apache Kafka Documentation — Replication, Design (High Watermark, ISR)
- KIP-101: Alter Replication Protocol to use Leader Epoch rather than High Watermark for Truncation
- KIP-279: Fix log divergence between leader and follower after fast leader elections
- Kafka 소스: `core/src/main/scala/kafka/cluster/Partition.scala`, `ReplicaFetcherThread`, `LeaderEpochFileCache`
