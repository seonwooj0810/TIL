# Kafka producer acks=all / min.insync.replicas

> **Primary source:** Apache Kafka Docs - Producer Configs `acks`, Topic Configs `min.insync.replicas`, Design - Replication
> **Secondary:** Kafka replication design 문서의 ISR 설명
> **Date:** 2026-06-12
> **Status:** draft

## 왜 봤나

- `acks=all`이면 replication factor 전체에 기록된 뒤 성공하는 것으로 막연히 이해하고 있었는데, 공식 문서의 표현은 "all current in-sync replicas"에 더 가깝다.
- `min.insync.replicas`는 `acks=all`의 동의어가 아니라, ISR이 너무 작아졌을 때 쓰기를 실패시키는 가용성/내구성 경계다.

## 핵심 한 문장

> `acks=all`은 현재 ISR에 속한 replica들의 append 확인을 기다리고, `min.insync.replicas`는 그 ISR 집합이 너무 작아졌을 때 성공 ack 자체를 막아 단일 replica 성공을 내구성으로 착각하지 않게 하는 설정이다.

## 내부 동작

Kafka의 producer write는 leader replica를 중심으로 진행된다. producer는 topic partition의 leader broker에게 produce request를 보내고, leader는 자신의 log에 record batch를 append한다. follower replica들은 leader에서 fetch해 자기 log를 따라잡는다. 공식 Kafka design 문서에 따르면 in-sync replica, 즉 ISR은 leader를 따라잡고 있는 replica들의 집합이며, leader도 이 집합에 포함된다.

`acks=all`의 "all"은 이 지점에서 해석해야 한다. 공식 producer config 문서에 따르면 `acks=all` 또는 `acks=-1`은 full set of in-sync replicas가 record를 acknowledge하기를 기다린다. 이것은 topic에 할당된 전체 replica 수와 항상 같지 않다.

쓰기 흐름을 단순화하면 다음과 같다.

```
Producer(acks=all)
  |
  | ProduceRequest(topic=T, partition=0, records=B)
  v
Leader replica
  | 1. local log append
  | 2. wait until every current ISR replica has B
  | 3. also check ISR size >= min.insync.replicas
  v
ProduceResponse(success or NotEnoughReplicas*)

Follower replicas
  ^ fetch from leader
  | append same batch and advance replica position
```

상태 전이로 보면 핵심은 ISR 크기와 append 완료 집합이다.

| 상태 | 조건 | `acks=all` 결과 |
| --- | --- | --- |
| 정상 | `ISR={leader,f1,f2}`, `min.insync.replicas=2` | 현재 ISR 3개가 append하면 성공 |
| follower 1개 이탈 | `ISR={leader,f1}`, `min.insync.replicas=2` | 2개가 append하면 성공 |
| follower 2개 이탈 | `ISR={leader}`, `min.insync.replicas=2` | 성공 불가, producer 예외 |
| `acks=1` | leader append 성공 | `min.insync.replicas`로 내구성 경계를 강제하지 못함 |

공식 topic config 문서에 따르면 `min.insync.replicas`는 producer가 `acks=all`을 사용할 때 write 성공에 필요한 최소 in-sync replica 수를 지정한다. 이 최소치를 만족하지 못하면 producer는 `NotEnoughReplicas` 또는 `NotEnoughReplicasAfterAppend` 예외를 받는다. 이름 때문에 "최소 개수만 ack하면 성공"으로 읽기 쉽지만, `acks=all`인 경우 write가 성공하려면 every in-sync replica가 acknowledge해야 하며, `min.insync.replicas`는 현재 ISR 크기가 이보다 작은지 검사하는 하한선이다.

예를 들어 replication factor 3, `min.insync.replicas=2`, `acks=all`인 topic을 생각해 본다.

```
case A: ISR = [A, B, C]
  leader A append
  follower B append
  follower C append
  -> producer success

case B: ISR = [A, B]       (C is out of ISR)
  leader A append
  follower B append
  -> producer success

case C: ISR = [A]          (B, C are out of ISR)
  leader A append만 가능
  -> producer failure because ISR size < 2
```

case B가 중요하다. `min.insync.replicas=2`라고 해서 B만 ack하면 되고 C는 무시한다는 뜻이 아니다. C가 ISR에 있다면 C도 append해야 `acks=all` 성공이다. C가 이미 ISR에서 빠진 상태라면 "현재 in-sync로 간주되는 집합"이 A, B뿐이므로 그 둘이 성공 조건이 된다. 따라서 `min.insync.replicas`는 quorum commit 알고리즘처럼 매 요청마다 전체 replica 중 과반만 골라 성공시키는 규칙이라기보다, Kafka의 ISR membership 위에서 동작하는 write admission rule에 가깝다.

자료구조 관점에서 leader는 각 follower가 어디까지 따라왔는지를 알아야 한다. 구현 세부 클래스명은 버전에 따라 바뀔 수 있지만, 복제 모델상 leader는 partition별 replica state를 보고 "이 follower가 아직 ISR에 남아도 되는가", "이 batch가 모든 ISR replica에 도달했는가"를 판단한다. follower가 충분히 따라오지 못하면 ISR에서 제외될 수 있고, 나중에 따라잡으면 다시 들어올 수 있다. 이 membership 변화 때문에 같은 `acks=all` 요청이라도 어느 순간의 ISR인지에 따라 성공 조건이 달라진다.

내구성과 가용성의 trade-off는 여기서 나온다. `acks=all`만 켜고 `min.insync.replicas`를 기본값 1로 두면, ISR이 leader 하나로 줄어든 순간에도 write가 성공할 수 있다. 공식 design 문서는 이 경우 남은 replica 하나까지 실패하면 그 write가 유실될 수 있다고 설명한다. 반대로 `min.insync.replicas=2`를 두면 follower들이 빠져 ISR이 1이 되는 순간 partition은 write를 받지 못한다. 메시지 손실 가능성을 낮추는 대신 장애 중 쓰기 가용성을 포기하는 셈이다.

```
replication.factor = 3
min.insync.replicas = 2

time  ISR            write availability       durability intuition
----  -------------  ----------------------   -------------------
t0    A,B,C          OK                       3 ISR ack 필요
t1    A,B            OK                       2 ISR ack 필요
t2    A              FAIL                     단일 replica write 차단
t3    A,B            OK                       follower 복구 후 재개
```

`acks=1`과 비교하면 차이가 더 분명하다. `acks=1`은 leader가 local log에 append한 뒤 응답할 수 있다. follower 복제 완료를 기다리지 않으므로 latency와 availability에는 유리하지만, leader가 응답 직후 죽고 아직 follower가 해당 batch를 받지 못했다면 새 leader 선출 뒤 record가 사라질 수 있다. 공식 producer config 문서는 `acks=all`을 가장 강한 available acknowledgment로 설명하지만, 동시에 `min.insync.replicas`와 함께 써야 더 강한 durability guarantee를 강제할 수 있다고 설명한다.

여기서 "visible to consumers"도 producer ack와 완전히 분리된 개념은 아니다. Kafka topic config 문서에는 `acks` 설정과 무관하게 메시지가 consumers에게 보이려면 모든 ISR에 복제되고 `min.insync.replicas` 조건을 만족해야 한다는 설명이 있다. high watermark는 ISR replica들이 공통으로 가진 로그 경계를 나타내며, consumer는 보통 이 경계 안의 committed record를 읽는다.

producer가 예외를 받았다고 해서 record가 물리적으로 절대 append되지 않았다는 뜻은 아니다. `NotEnoughReplicasAfterAppend`라는 이름이 암시하듯 leader append 이후 follower ack 조건을 만족하지 못하는 실패도 가능하다. producer 입장에서는 성공 여부가 불명확할 수 있으므로 retry 정책과 idempotent producer 설정이 함께 중요해진다.

운영 설정으로는 보통 replication factor 3, `min.insync.replicas=2`, producer `acks=all` 조합이 예시로 제시된다. 이 조합은 세 replica 중 두 replica 이상이 ISR에 남아 있어야 write가 성공한다. 다만 이것이 "절대 유실 없음"을 뜻하지는 않는다. unclean leader election, 디스크 flush 정책, 다중 장애 타이밍, 클라이언트 retry/timeout 해석이 모두 결과에 영향을 준다.

## 검증

이번 노트는 코드 실험 대신 공식 문서의 조건을 상태표로 따라가며 검증했다.

```text
replication.factor=3, min.insync.replicas=2, producer acks=all

ISR={A,B,C}
  -> A/B/C 모두 append해야 success

ISR={A,B}
  -> A/B 모두 append하면 success

ISR={A}
  -> ISR size가 2보다 작으므로 NotEnoughReplicas 계열 failure
```

공식 Kafka topic config 문서의 `min.insync.replicas` 설명은 이 흐름과 맞다. producer가 `acks=all`일 때 write 성공에 필요한 최소 ISR 수를 요구하고, 현재 ISR 수가 그보다 작으면 `NotEnoughReplicas` 또는 `NotEnoughReplicasAfterAppend` 예외가 발생한다. Kafka design 문서도 `acks=all`만으로는 ISR이 1개로 줄어든 상황의 손실 가능성을 제거하지 못하므로 minimum ISR size를 함께 설정해야 한다고 설명한다.

## 잘못 알고 있던 것

- `acks=all`의 all을 replication factor 전체로 이해하면 부정확하다. 공식 문서 기준으로는 현재 in-sync replica 집합이 기준이다.
- `min.insync.replicas=2`를 "2개만 ack하면 성공"으로 이해하는 것도 부정확하다. `acks=all`에서는 현재 ISR 전체가 ack해야 하고, `min.insync.replicas`는 현재 ISR 크기의 하한선을 강제한다.
- producer가 실패 응답을 받으면 아무것도 쓰이지 않았다고 단정하면 위험하다. append 이후 충분한 replica ack를 받지 못해 실패하는 경로가 있으므로 retry와 idempotence까지 같이 봐야 한다.

## 더 파고들 만한 것

- Kafka idempotent producer의 PID/epoch/sequence가 `acks=all` retry 중복을 어떻게 제거하는지 다시 연결해서 보기.
- ISR shrink/expand 조건과 high watermark advancement를 Kafka 소스의 partition state 갱신 흐름으로 따라가기.

## 참고

- Apache Kafka Docs - Producer Configs `acks`: https://kafka.apache.org/documentation/#producerconfigs_acks
- Apache Kafka Docs - Topic Configs `min.insync.replicas`: https://kafka.apache.org/documentation/#topicconfigs_min.insync.replicas
- Apache Kafka Docs - Design, Replication: https://kafka.apache.org/documentation/#design_replicatedlog
- Apache Kafka 4.1 Topic Configs `min.insync.replicas`: https://kafka.apache.org/41/configuration/topic-configs/

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
