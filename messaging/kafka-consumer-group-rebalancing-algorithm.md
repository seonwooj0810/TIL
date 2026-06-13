# Kafka 컨슈머 그룹 리밸런싱 알고리즘

> **Primary source:** Apache Kafka Docs - Consumer Rebalance Protocol, Consumer Configs, `ConsumerRebalanceListener` Javadoc
> **Secondary:** KIP-429 Incremental Cooperative Rebalancing, KIP-848 The Next Generation of the Consumer Rebalance Protocol
> **Date:** 2026-06-13
> **Status:** draft

## 왜 봤나

- 리밸런싱을 "컨슈머 수가 바뀌면 파티션을 다시 나누는 일" 정도로 이해했는데, 실제 장애 시간은 assignor보다 group membership protocol과 revoke/assign 순서에서 많이 나온다.

## 핵심 한 문장

> Kafka 컨슈머 그룹 리밸런싱은 group coordinator가 멤버십 세대를 관리하고, assignor가 `TopicPartition -> member` 매핑을 계산한 뒤, eager/cooperative/consumer protocol 중 어떤 동기화 모델을 쓰느냐에 따라 파티션 소유권 이전 비용을 다르게 치르는 절차다.

## 내부 동작

컨슈머 그룹은 같은 `group.id`를 가진 consumer들이 topic partition을 나눠 읽는 단위다. 공식 `ConsumerRebalanceListener` Javadoc에 따르면 Kafka가 group membership을 관리할 때 멤버 변화, subscription 변화, 프로세스 장애/복귀, topic partition 수 변경이 partition re-assignment를 트리거한다. 따라서 리밸런싱은 단순한 load balancing 함수가 아니라, "현재 세대의 멤버는 누구인가"와 "각 파티션의 단일 소유자는 누구인가"를 다시 정하는 상태 전이다.

classic consumer group은 안정 상태, join, sync, stable의 반복으로 볼 수 있다.

```
Stable generation N: C1 owns P0,P1 / C2 owns P2,P3
        |
        | C3 join, C2 timeout, subscription change, partition count change
        v
Preparing rebalance: members detect change and revoke all or some partitions
        |
        v
Completing rebalance: coordinator collects joins, assignment is computed/distributed
        |
        v
Stable generation N+1
```

group coordinator는 group id 기준으로 선택되는 브로커의 역할이다. classic protocol에서는 각 멤버가 subscription과 지원 assignor 정보를 보내고, group leader로 선출된 client가 assignment를 계산한 뒤 coordinator가 결과를 배포하는 구조로 알려져 있다. Kafka 4.0부터 GA가 된 새 consumer rebalance protocol에서는 공식 문서 기준으로 assignment strategy가 서버에서 제어된다.

assignor가 푸는 문제는 자료구조로 쓰면 단순하다.

```text
input: members, subscriptions, partitions, previousAssignment?
output: map<MemberId, set<TopicPartition>>
```

Range, round-robin, sticky, cooperative sticky 같은 assignor는 서로 다른 최적화 기준을 적용한다. range는 topic별 partition 순서와 consumer 순서에 따라 연속 구간을 나누는 쪽에 가깝고, round-robin은 구독 가능한 파티션을 멤버에 순환 배치하는 쪽으로 이해할 수 있다. sticky 계열은 균형만 보지 않고 `previousAssignment`를 비용 함수에 넣는다. 리밸런싱 비용은 이동한 파티션 수와 state restore 비용에 가까우므로, stateful consumer나 Kafka Streams에서는 기존 소유권을 보존하는 성질이 중요하다.

문제는 배정 결과를 언제 적용하느냐다. eager rebalancing에서는 리밸런스가 시작될 때 멤버들이 보유 파티션을 모두 내려놓는 모델로 설명된다. 공식 Javadoc도 eager rebalancing에서 `onPartitionsRevoked`가 리밸런스 시작 시 항상 호출된다고 설명한다. 이 방식은 단순하지만, 변하지 않을 파티션까지 잠시 소유자가 없어져 stop-the-world 성격의 공백이 생긴다.

```text
before: C1 owns P0,P1 / C2 owns P2,P3
target: C1->P0, C2->P2, C3->P1,P3
eager:  C1 revokes P0,P1 and C2 revokes P2,P3 before assignment
```

위 예에서 P0와 P2는 최종 주인이 그대로인데도 한 번 revoke된다. 캐시 flush, offset commit, local state close가 revoke callback에 묶여 있다면 실제로 이동하지 않는 파티션까지 처리 중단 비용을 낸다.

cooperative rebalancing은 이 지점을 바꾼다. KIP-429의 방향은 전체 소유권을 한 번에 비우는 대신 충돌이 나는 파티션만 점진적으로 반납시키는 것이다. 공식 Javadoc도 cooperative rebalancing에서는 revoke/lost callback이 해당 멤버에서 실제로 revoke 또는 lost되는 non-empty partition 집합이 있을 때만 트리거된다고 설명한다.

```text
before: C1 owns P0,P1 / C2 owns P2,P3
target: C1->P0, C2->P2, C3->P1,P3
round1: C1 keeps P0 and revokes P1; C2 keeps P2 and revokes P3
round2: C3 receives P1,P3
```

상태 전이 관점에서 cooperative protocol은 partition별 소유권을 `owned -> revoking -> unowned -> assigned`로 이동시킨다. 한 파티션을 동시에 두 멤버가 읽으면 offset commit, local state, side effect가 꼬일 수 있으므로 새 owner가 읽기 전에 old owner의 revoke가 먼저 관측되어야 한다. Javadoc은 정상 조건에서 어떤 파티션이 한 consumer에서 다른 consumer로 재배정될 때 old consumer의 `onPartitionsRevoked`가 new consumer의 `onPartitionsAssigned`보다 먼저 호출된다고 설명한다.

callback의 의미도 여기서 갈린다. `onPartitionsRevoked`는 정상적인 소유권 반납 지점이므로 offset commit이나 state flush를 둘 수 있다. 반면 `onPartitionsLost`는 이미 다른 멤버가 소유했을 수 있는 exceptional path다. Javadoc은 session timeout 같은 경우 graceful revoke 기회 없이 partition이 재배정될 수 있고, 이때 lost callback에서는 offset commit이 불가능할 수 있다고 설명한다.

Kafka 4.0부터 공식 문서가 설명하는 next generation consumer rebalance protocol은 이 흐름을 더 서버 중심으로 옮긴다. Kafka 4.1 문서에 따르면 새 protocol은 fully incremental design이며 global synchronization barrier에 더 이상 의존하지 않아 rebalance time을 줄인다. heartbeat interval과 session timeout도 `group.consumer.heartbeat.interval.ms`, `group.consumer.session.timeout.ms` 같은 server config로 제어된다. consumer는 `group.protocol=consumer`로 새 protocol을 활성화해야 한다.

이 변화의 의미는 책임 경계가 바뀐다는 점이다. classic에서는 모든 멤버가 join barrier에 모이고, client-side leader가 assignment를 계산하고, sync barrier를 지난다. 새 consumer protocol에서는 문서상 서버가 assignor를 제어하므로, 큰 그룹에서 전역 장벽 비용을 낮추는 방향으로 이해할 수 있다. 다만 공식 문서는 client-side assignor 미지원 같은 limitation도 함께 둔다.

리밸런싱을 장애 시간으로 체감하는 이유는 poll loop와 heartbeat 제약 때문이다. 애플리케이션이 `poll()` 이후 처리를 너무 오래 하면 heartbeat/session 또는 `max.poll.interval.ms` 경계에 걸려 멤버가 group에서 빠질 수 있다. 따라서 "리밸런싱이 자주 난다"는 증상은 assignor보다 처리 시간, poll 주기, static membership, graceful shutdown, revoke callback의 commit 전략을 같이 봐야 한다.

eager는 transfer 층에서 모든 파티션을 한 번 비우므로 단순하지만 멈춤이 크다. cooperative는 실제 이동해야 하는 파티션만 단계적으로 비우므로 멈춤을 줄일 수 있다. 새 consumer protocol은 assignment와 membership 관리를 서버 쪽으로 옮기고 incremental design을 적용해, 큰 consumer group에서 전역 동기화 비용을 낮추는 방향으로 이해할 수 있다.

## 검증

이번 노트는 코드 실험 대신 Kafka 공식 문서와 Javadoc의 흐름을 따라 검증했다.

```text
C3 joins
  eager       -> all members revoke all partitions, then receive full assignment
  cooperative -> only moving partitions are revoked; kept partitions continue
  consumer    -> server-side protocol controls heartbeat/session/assignor path
```

`ConsumerRebalanceListener` Javadoc의 callback 설명과도 맞다. eager에서는 리밸런스 시작 시 revoke가 항상 호출되고, cooperative에서는 실제 revoke/lost partition이 있을 때만 callback이 호출된다. 정상적인 재배정에서는 old owner의 revoke가 new owner의 assign보다 먼저 호출되므로, offset commit과 state handoff 위치를 `onPartitionsRevoked`에 두는 이유가 설명된다.

## 잘못 알고 있던 것

- 리밸런싱 비용을 assignor의 균등 분배 문제로만 보면 부족하다. 실제 중단 시간은 revoke 범위, state flush, offset commit, barrier, timeout이 함께 만든다.
- cooperative rebalance는 "리밸런싱이 안 일어난다"가 아니다. 리밸런싱은 일어나지만, 변하지 않는 파티션 소유권을 유지하고 이동할 파티션만 점진적으로 넘기는 방식이다.
- `onPartitionsLost`를 `onPartitionsRevoked`와 같은 commit 지점으로 보면 위험하다. 공식 Javadoc 기준으로 lost는 이미 다른 멤버가 소유했을 수 있는 exceptional path다.

## 더 파고들 만한 것

- Kafka Streams의 task migration과 cooperative rebalance가 local state restore 시간을 어떻게 줄이는지 보기.
- `group.instance.id` 기반 static membership이 rolling deploy 중 리밸런싱 빈도를 어떻게 줄이는지 공식 config와 함께 정리하기.

## 참고

- Apache Kafka Docs - Consumer Rebalance Protocol: https://kafka.apache.org/41/operations/consumer-rebalance-protocol/
- Apache Kafka Javadoc - `ConsumerRebalanceListener`: https://kafka.apache.org/41/javadoc/org/apache/kafka/clients/consumer/ConsumerRebalanceListener.html
- Apache Kafka KIP-429 - Kafka Consumer Incremental Rebalance Protocol: https://cwiki.apache.org/confluence/display/KAFKA/KIP-429%3A+Kafka+Consumer+Incremental+Rebalance+Protocol
- Apache Kafka KIP-848 - The Next Generation of the Consumer Rebalance Protocol: https://cwiki.apache.org/confluence/display/KAFKA/KIP-848%3A+The+Next+Generation+of+the+Consumer+Rebalance+Protocol

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
