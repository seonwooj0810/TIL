# Kafka exactly-once semantics 내부 메커니즘

> **Primary source:** Apache Kafka KIP-98 - Exactly Once Delivery and Transactional Messaging
> **Secondary:** Kafka protocol/producer transaction API 문서, Kafka Streams exactly-once 설명
> **Date:** 2026-06-12
> **Status:** draft

## 왜 봤나

- "Kafka exactly-once"를 단순히 컨슈머가 메시지를 한 번만 읽게 해 주는 기능처럼 받아들이기 쉬운데, 실제 보장은 producer retry 중복 제거와 consume-transform-produce 결과의 원자적 공개에 더 가깝다.

## 핵심 한 문장

> KIP-98의 exactly-once는 PID/epoch/sequence로 재시도 중복을 거르고, transaction coordinator와 commit/abort marker로 여러 파티션의 결과 레코드와 소비 오프셋을 하나의 원자적 결과처럼 공개하는 메커니즘이다.

## 내부 동작

KIP-98은 두 층을 분리해서 설계한다. 첫 번째는 idempotent producer다. producer가 브로커 응답을 받지 못해 재시도해도 같은 레코드가 로그에 두 번 materialize되지 않도록 한다. 두 번째는 transactional producer다. 여러 TopicPartition에 쓴 출력 레코드와 `__consumer_offsets`의 입력 오프셋을 하나의 commit/abort 단위로 묶는다.

idempotent producer의 핵심 자료구조는 broker가 파티션별로 기억하는 `PID -> next expected sequence` 계열 상태라고 볼 수 있다. KIP-98의 message set format에는 `PID`, `ProducerEpoch`, `FirstSequence`가 batch 단위로 들어간다. batch의 레코드마다 PID를 반복해서 쓰지 않고 batch header에 둔 이유는, 공식 proposal에 따르면 같은 producer가 만든 batch 내부에서는 PID와 epoch가 바뀌지 않기 때문이다. broker는 특정 PID/epoch에서 다음에 와야 할 sequence를 알고 있고, producer retry로 같은 sequence가 다시 오면 duplicate로 판단할 수 있다.

간단히 쓰면 상태 전이는 다음에 가깝다.

```
producer send batch
  (PID=P, epoch=E, firstSeq=S, count=N)
        |
        v
partition leader checks state[P]
  expected == S        -> append, expected = S + N
  expected > S         -> duplicate retry, already appended
  expected < S         -> invalid/out-of-order sequence
  epoch mismatch/stale -> fenced producer
```

여기서 epoch는 fencing 역할을 한다. 같은 `transactional.id`를 가진 새 producer instance가 `initTransactions()`를 호출하면 transaction coordinator가 PID와 epoch를 할당하거나 epoch를 증가시킨다. KIP-98의 producer API 설명에 따르면 이 과정은 이전 instance가 시작해 둔 transaction을 완료 또는 abort하도록 만들고, 이후 transactional message에 사용할 producer id와 epoch를 얻는다. 따라서 장애 후 재시작한 새 instance가 같은 `transactional.id`를 사용하면 이전 instance는 stale epoch가 되어 `ProducerFencedException` 계열 오류를 받는 구조로 알려져 있다.

transactional producer는 `beginTransaction()` 이후 출력 topic에 record를 쓰고, consume-transform-produce 패턴이라면 `sendOffsetsToTransaction()`으로 입력 offset도 transaction에 포함한다. 그 다음 `commitTransaction()` 또는 `abortTransaction()`을 호출한다.

```
Producer
  | initTransactions(transactional.id)
  v
Transaction Coordinator
  | assign PID/epoch, track transactional.id
  v
Producer -- beginTransaction ----------------------+
  |                                                |
  | Produce(topic A, P0, transactional batch)      |
  | Produce(topic B, P3, transactional batch)      |
  | AddOffsetsToTxn + offset commit batch          |
  |                                                |
  +-- EndTxn(commit or abort) -------------------->+
                                                   |
Transaction Coordinator                            |
  | PREPARE_COMMIT / PREPARE_ABORT to transaction log
  | WriteTxnMarker to each touched partition
  | COMMITTED / ABORTED to transaction log
  v
User logs contain data batches plus COMMIT/ABORT control markers
```

여기서 transaction log는 transaction state를 추적하는 내부 로그다. KIP-98은 coordinator가 `EndTxnRequest`를 받으면 transaction log에 `PREPARE_COMMIT` 또는 `PREPARE_ABORT`를 쓰고, 각 TopicPartition leader에게 `WriteTxnMarkerRequest`를 보내 `COMMIT(PID)` 또는 `ABORT(PID)` control message를 쓰게 한 뒤, 마지막으로 transaction log에 `COMMITTED` 또는 `ABORTED`를 기록한다고 설명한다. 이 순서는 장애 복구 때문에 중요하다.

로그에는 abort된 transaction의 data batch도 물리적으로 남을 수 있다. "abort는 로그에서 즉시 삭제"가 아니라, downstream consumer에게 공개하지 않도록 marker와 isolation level로 처리하는 쪽에 가깝다. KIP-98은 commit marker가 있으면 해당 PID의 메시지를 전달하고 abort marker가 있으면 버린다고 설명한다. 그래서 consumer는 `isolation.level=read_committed`일 때 commit/abort 여부를 알 때까지 기다리거나, fetch response에 포함된 aborted transaction 정보를 보고 해당 구간을 건너뛴다.

`read_committed`에서 중요한 포인터가 LSO, 즉 Last Stable Offset이다. KIP-98의 FetchResponse에는 `HighwaterMarkOffset`과 함께 `LastStableOffset`, `AbortedTransactions`가 추가된다. high watermark는 복제 관점에서 읽을 수 있는 끝에 가깝지만, LSO는 아직 결과가 확정되지 않은 열린 transaction 앞에서 멈추는 경계로 이해하면 된다. 열린 transaction 뒤에 non-transactional record가 이미 append되어 있더라도 offset ordering을 지키려면 consumer가 그것을 먼저 공개하기 어렵다.

예를 들어 로그가 아래와 같다고 하자.

```
offset: 10  11  12  13  14  15
type:   T   T   N   N   C   N
txn:    X   X   -   -   X   -
              ^ open transaction X가 완료되기 전

T = transactional data, N = non-transactional data, C = commit marker
```

`read_uncommitted` consumer는 offset 순서대로 10, 11, 12, 13을 볼 수 있다. 반면 `read_committed` consumer는 X의 commit/abort marker를 보기 전까지 10, 11의 운명을 모른다. offset 12, 13이 transaction 밖 record여도, 10, 11을 건너뛰고 먼저 내보내면 offset 순서가 깨진다. 그래서 LSO가 열린 transaction 앞에 머무르면 lag 계산도 high watermark가 아니라 LSO 기준이 된다.

메시지 포맷 변화도 내부 동작과 연결된다. KIP-98은 batch/message set level에 `PID`, `ProducerEpoch`, `FirstSequence`, transactional bit, control bit를 추가한다. control bit가 켜진 batch는 애플리케이션 데이터가 아니라 transaction marker를 담는다. 자료구조 관점에서는 "일반 record stream" 안에 transaction outcome을 나타내는 control record를 함께 넣고, consumer protocol이 그것을 해석해 visibility를 계산한다. log 안에 marker가 들어가기 때문에 partition별 복제, 순서, 복구 모델을 그대로 재사용할 수 있다.

`__consumer_offsets`를 transaction에 포함하는 점도 중요하다. 출력 topic에는 결과를 썼지만 offset commit이 실패하면 입력 record를 다시 처리하며 중복 결과가 생길 수 있다. 반대로 offset을 먼저 commit하고 출력이 실패하면 결과 유실이 생긴다. KIP-98은 producer의 `sendOffsets` API를 추가해 input offset update를 transaction에 넣도록 제안한다.

다만 이 보장은 Kafka 안에서 transaction-aware하게 읽고 쓸 때의 보장이다. 외부 DB에 이미 쓴 side effect, 이메일 발송, HTTP 호출까지 자동으로 되돌리지는 않는다. 그런 시스템을 포함하려면 외부 시스템도 같은 transaction boundary에 참여하거나, outbox/idempotency key 같은 별도 설계가 필요하다고 보는 편이 안전하다.

## 검증

이번 노트에서는 코드를 실행하지 않고 KIP-98의 프로토콜 흐름을 따라 검증했다. `initTransactions()`는 PID/epoch를 얻고 이전 instance를 fence한다. `beginTransaction()` 뒤 `send()`로 쓴 output batch에는 PID/epoch/sequence와 transactional bit가 붙는다. `sendOffsetsToTransaction()`은 offset update를 같은 transaction에 넣고, `commitTransaction()`은 coordinator로 `EndTxnRequest`를 보내 transaction log의 prepare 상태와 각 user log의 commit marker를 통해 결과를 공개한다.

## 잘못 알고 있던 것

- "exactly-once면 consumer가 입력 메시지를 한 번만 poll한다"가 아니다. 장애나 timeout 때문에 입력 처리는 다시 시도될 수 있다. 중요한 것은 transaction-aware downstream consumer가 중복 output과 잘못 commit된 offset을 관측하지 않도록 만드는 것이다.
- abort를 "쓴 메시지를 물리적으로 지운다"로 이해하면 부정확하다. KIP-98의 구조에서는 control marker와 consumer isolation level로 visibility를 제어한다.
- `acks=all`과 retries만으로 exactly-once가 되는 것도 아니다. 그것은 내구성과 at-least-once 성격을 강화하지만, ack 손실 뒤 retry가 같은 batch를 다시 쓰는 문제는 PID/sequence 기반 idempotence가 있어야 막을 수 있다.

## 더 파고들 만한 것

- Kafka producer `acks=all`, `min.insync.replicas`, idempotence 설정이 어떻게 서로 맞물리는지 따로 정리하기.
- Kafka consumer group rebalance 중 transaction-aware offset commit과 processing timeout이 어떤 장애 시나리오를 만드는지 보기.

## 참고

- Apache Kafka KIP-98 - Exactly Once Delivery and Transactional Messaging: https://cwiki.apache.org/confluence/display/KAFKA/KIP-98+-+Exactly+Once+Delivery+and+Transactional+Messaging
- Apache Kafka Producer transaction API 문서
- Kafka Streams exactly-once semantics 관련 공식 문서

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
