# CAP 정리와 PACELC

> **Primary source:** Designing Data-Intensive Applications Ch.9 — Consistency and Consensus
> **Secondary:** Gilbert & Lynch, Brewer's conjecture and the feasibility of consistent, available, partition-tolerant web services; Abadi, Consistency Tradeoffs in Modern Distributed Database System Design: CAP is Only Part of the Story
> **Date:** 2026-06-11
> **Status:** draft

## 왜 봤나

- CAP를 "Consistency, Availability, Partition tolerance 중 둘만 고른다"로 외웠는데, 이 표현은 네트워크 파티션이 실제로 발생했을 때의 선택을 너무 평시 설계 선택처럼 보이게 만든다.
- PACELC는 CAP의 대체라기보다, 파티션이 없을 때도 지연 시간과 일관성 사이의 선택이 계속 남는다는 보완 프레임으로 이해할 필요가 있었다.

## 핵심 한 문장

> CAP는 네트워크 파티션 중에는 선형화 가능한 일관성과 모든 요청에 대한 응답 가능성을 동시에 보장할 수 없다는 정리이고, PACELC는 그 파티션 상황(PA/PC)뿐 아니라 정상 상황(EL/EC)에서도 지연 시간과 일관성의 트레이드오프가 설계에 남는다고 보는 분류다.

## 내부 동작

### 1. CAP의 세 단어를 좁게 잡아야 한다

DDIA Ch.9에 따르면 CAP에서 말하는 consistency는 일반적인 "데이터가 대충 맞는다"가 아니라 **linearizability**에 가깝다. `write(x=1)`이 성공한 뒤 시작된 `read(x)`는 오래된 값 `0`을 보면 안 된다. 모든 연산이 전역 단일 순서에 놓인 것처럼 보이는 성질이다.

Availability도 "장애가 전혀 없다"가 아니라, 네트워크로 고립되지 않은 노드가 받은 모든 요청에 대해 오류가 아닌 응답을 결국 돌려준다는 의미로 알려져 있다. Partition tolerance는 메시지 지연·유실에도 명세된 성질을 유지하려는 요구다. 현실의 분산 시스템은 파티션을 선택지처럼 끌 수 없으므로, CAP의 실제 질문은 "파티션이 생겼을 때 C와 A 중 무엇을 희생할 것인가"에 가깝다.

```text
normal network:
  replicas can exchange messages -> many designs can be both fast enough and consistent enough

partitioned network:
  replica A  xxxxx network break xxxxx  replica B
  client 1 writes A                         client 2 reads/writes B
```

여기서 "P를 선택한다"는 말은 엄밀하지 않다. 메시지는 언제든 지연되거나 유실될 수 있다. 설계자가 고르는 것은 P가 아니라, **P가 발생했을 때 요청을 거절할지(CP), 오래된 상태라도 응답할지(AP)**다.

### 2. 파티션 중 선형화 가능성을 지키려면 일부 요청을 멈춰야 한다

두 복제본 `A`, `B`가 같은 키 `x`를 가진다고 하자. 초기값은 `0`이다. 파티션 중 클라이언트가 `A`에 `x=1` 쓰기를 보내고 성공 응답을 받았다면, 그 이후의 읽기는 `1`을 봐야 한다.

```text
t0: A.x = 0, B.x = 0
t1: network partition A | B
t2: client W -> A: write x = 1, A replies OK
t3: client R -> B: read x = ?
```

`B`가 availability를 지키려고 응답하면 `0`을 줄 수밖에 없다. 그러면 `t2` 이후 시작된 읽기가 옛 값을 보므로 linearizability가 깨진다. 반대로 linearizability를 지키려면 `B`는 최신 여부를 확인할 수 없으므로 요청을 실패시키거나 대기시켜야 한다. 이때 availability가 깨진다.

이것이 CAP의 상태 전이다.

```text
PARTITION_DETECTED
  ├─ prefer consistency -> reject/timeout minority-side operations -> CP behavior
  └─ prefer availability -> serve local state and reconcile later -> AP behavior
```

여기서 자료구조 차이도 생긴다. CP 계열은 leader, quorum, term, commit index 같은 합의 상태를 둔다. AP 계열은 local log, vector clock, version vector, CRDT state 같은 병합 가능한 메타데이터를 보관한다. 그래서 CP/AP는 **파티션 중 요청 처리 알고리즘과 충돌 자료구조의 차이**로 드러난다.

### 3. CP 쪽 알고리즘: 다수파 확인 후 커밋

Raft나 Paxos 같은 합의 알고리즘을 단순화하면, 선형화 가능한 쓰기는 리더의 로컬 메모리에만 반영돼서는 안 된다. 리더는 로그 엔트리를 다수 노드에 복제하고, 다수의 확인을 받은 뒤 커밋으로 표시한다.

```text
client -> leader: put x=1
leader log append: [term=7, index=42, x=1]
leader -> followers: AppendEntries(index=42)
followers -> leader: ack
leader: if ack >= quorum, commitIndex = 42, reply OK
```

파티션으로 리더가 과반수와 통신하지 못하면 `ack >= quorum` 조건을 만족하지 못한다. 안전성은 유지되지만 요청은 성공하지 않는다. 이것이 CP 선택의 비용이다.

읽기도 마찬가지다. 리더 lease, read index, quorum read 같은 기법 없이 로컬 값만 읽으면 stale read가 될 수 있다. 읽기까지 선형화 가능하게 만들려면 현재 리더가 유효하다는 사실을 확인하거나 다수파와의 관계를 이용해야 한다.

### 4. AP 쪽 알고리즘: 로컬 수락 후 병합

AP 쪽은 파티션 중에도 각 replica가 요청을 받는다. 대신 나중에 서로 다른 쓰기가 만났을 때 병합해야 한다. 간단한 key-value store를 생각하면 각 값에 버전을 붙인다.

```text
value_record(
  key,
  value,
  version_vector, -- replica별 counter
  timestamp,
  tombstone
)
```

파티션 중 `A`가 `x=1`, `B`가 `x=2`를 각각 수락하면 두 버전은 인과적으로 비교되지 않을 수 있다. last-write-wins를 쓰면 하나를 버릴 수 있고, shopping cart 같은 도메인은 multi-value register나 CRDT set으로 병합할 수도 있다.

따라서 AP는 "아무렇게나 다 받아도 된다"가 아니다. local write를 수락했다면 anti-entropy, read repair, hinted handoff, conflict resolution 같은 복구 경로가 필요하다. eventual consistency의 "결국"을 만들려면 배경 동기화와 충돌 병합 규칙이 있어야 한다.

### 5. PACELC: 파티션이 없어도 비용은 남는다

CAP만 외우면 "장애 때만 고민하면 된다"처럼 보인다. Abadi가 제안한 PACELC는 이 빈틈을 찌른다.

```text
if Partition:
  choose Availability or Consistency  -> PA / PC
Else:
  choose Latency or Consistency       -> EL / EC
```

예를 들어 정상 상황에서도 모든 쓰기를 원격 리전 다수파에 동기 복제하면 더 강한 일관성을 얻지만 왕복 지연이 늘어난다. 반대로 로컬 리전에서 먼저 응답하고 비동기로 전파하면 지연은 낮아지지만 다른 리전의 읽기는 stale할 수 있다. 파티션이 없어도, 물리적 거리와 메시지 왕복 시간 때문에 consistency와 latency의 선택이 계속 나타난다.

```text
EC path:
  client -> Seoul leader -> Tokyo quorum -> commit -> reply

EL path:
  client -> Seoul replica -> local commit/reply -> async replicate Tokyo
```

DDIA Ch.9의 consensus와 linearizability 논의도 이 관점과 맞닿아 있다. 선형화 가능성을 강하게 요구할수록 coordination이 필요하고, coordination은 메시지 왕복과 실패 감지를 기다리게 만든다.

### 6. 분류보다 먼저 물어야 할 질문

시스템을 "CP DB" 또는 "AP DB"라고만 부르면 놓치는 것이 많다. 같은 제품도 옵션, operation, topology에 따라 다른 보장을 제공할 수 있다.

- 쓰기 성공 응답은 몇 개 replica의 어떤 확인 뒤에 나가는가?
- 읽기는 leader/quorum을 거치는가, local replica를 바로 읽는가?
- 파티션 중 minority side는 요청을 거절하는가, local state로 응답하는가?
- 충돌 버전이 생기면 자료구조가 보존하는가, LWW처럼 버리는가?
- 정상 상황에서 원격 리전 coordination을 기다리는가, 비동기로 넘기는가?

이 질문에 답하면 라벨보다 실제 장애 동작이 선명해진다.

## 검증

출처 흐름을 따라가며 확인한 내용:

1. DDIA Ch.9는 linearizability를 "시스템이 데이터 사본 하나만 있는 것처럼 보이게 하는" 강한 최신성 보장으로 설명하고, 네트워크 지연과 장애가 있을 때 이를 유지하려면 coordination이 필요하다고 설명한다.
2. Gilbert & Lynch 논문은 비동기 네트워크 모델에서 consistency, availability, partition tolerance를 동시에 만족할 수 없다는 Brewer 추측의 형식화를 제시한 것으로 알려져 있다. 위의 `A/B` 레지스터 예시는 그 핵심 직관을 단순화한 것이다.
3. DDIA의 consensus 설명을 따라가면 CP 쪽의 커밋 조건은 "리더가 혼자 결정"이 아니라 quorum 확인과 로그 순서에 의존한다. 이 때문에 파티션 중 과반수와 통신하지 못하면 진행을 멈춘다.
4. Abadi의 PACELC 논문은 CAP가 파티션 상황에 집중한다고 보고, 파티션이 없을 때도 latency와 consistency 사이의 선택이 존재한다고 정리한다.

작은 의사 코드로 파티션 중 분기를 표현하면 다음과 같다.

```java
Response handleWrite(Key key, Value value) {
    if (mode == CP) {
        if (!canReachQuorum()) return unavailable();
        LogEntry entry = appendLocalLog(key, value);
        replicateToQuorum(entry);
        markCommitted(entry);
        return ok();
    }

    VersionedValue local = applyLocal(key, value, nextVersion());
    enqueueAntiEntropy(local);
    return accepted(); // later reconciliation may expose conflict
}
```

이 코드는 실제 DB 구현이 아니라 선택 지점을 드러내기 위한 모델이다. 핵심은 CP는 커밋 전 coordination을 기다리고, AP는 로컬 수락 후 병합 책임을 뒤로 미룬다는 점이다.

## 잘못 알고 있던 것

- **"CAP는 C/A/P 중 둘을 고르는 공식이다"** → P는 현실에서 피하기 어렵다. 더 정확히는 파티션이 생겼을 때 선형화 가능한 일관성과 availability를 동시에 만족할 수 없다는 제약이다.
- **"Consistency는 그냥 데이터가 맞는다는 뜻이다"** → CAP 문맥의 C는 보통 linearizability로 좁게 봐야 한다. eventual consistency, read-your-writes, monotonic reads 같은 다른 일관성 모델과 섞으면 논의가 흐려진다.
- **"AP는 일관성을 포기한다"** → 선형화 가능성은 포기할 수 있지만, 수렴을 위한 충돌 메타데이터와 병합 규칙은 필요하다. 그렇지 않으면 available한 저장소가 아니라 손실을 숨기는 저장소가 된다.
- **"PACELC는 CAP의 반박이다"** → 반박이라기보다 확장이다. 파티션 중 선택은 CAP로, 정상 상황의 latency/consistency 선택은 ELC로 함께 보자는 프레임에 가깝다.

## 더 파고들 만한 것

- Raft의 `commitIndex`, leader lease, linearizable read path가 실제로 stale read를 어떻게 막는지.
- CRDT와 version vector가 AP 시스템의 충돌 병합을 어떤 자료구조로 모델링하는지.

## 참고

- Martin Kleppmann, Designing Data-Intensive Applications Ch.9 — Consistency and Consensus
- Seth Gilbert, Nancy Lynch, Brewer's conjecture and the feasibility of consistent, available, partition-tolerant web services
- Daniel J. Abadi, Consistency Tradeoffs in Modern Distributed Database System Design: CAP is Only Part of the Story
