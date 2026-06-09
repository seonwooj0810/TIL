# Saga 패턴: Choreography vs Orchestration

> **Primary source:** Microservices Patterns (Chris Richardson) Ch.4 — Managing transactions with sagas, Choreography-based sagas, Orchestration-based sagas
> **Secondary:** Eventuate Tram examples, Azure Architecture Center — Saga distributed transactions pattern
> **Date:** 2026-06-09
> **Status:** draft

## 왜 봤나

- "Saga는 분산 트랜잭션의 대체재"라고만 외웠는데, 실제로는 **ACID 원자성 대신 보상 트랜잭션과 상태 흐름을 설계하는 패턴**이라는 점을 정리하고 싶었다.
- Choreography와 Orchestration을 "이벤트 기반 vs 중앙 제어" 정도로만 구분했는데, 실패 처리와 결합 방향이 헷갈렸다.

## 핵심 한 문장

> Saga는 하나의 비즈니스 트랜잭션을 여러 서비스의 로컬 트랜잭션과 보상 트랜잭션으로 나눈 상태 머신이며, Choreography는 각 서비스가 이벤트를 보고 다음 단계를 자율 실행하고, Orchestration은 오케스트레이터가 명령과 응답으로 전체 진행 상태를 명시적으로 관리한다.

## 내부 동작

### 1. Saga가 풀려는 문제

마이크로서비스에서는 `Order`, `Customer`, `Payment`가 서로 다른 DB를 가진다. 주문 생성 시 고객 한도 확인과 결제 승인이 모두 성공해야 해도 한 DB 트랜잭션으로 묶을 수 없다. Richardson은 이런 상황에서 2PC 대신 Saga를 사용한다고 설명한다. Saga는 각 단계를 **로컬 트랜잭션**으로 커밋하고, 뒤 단계가 실패하면 **보상 트랜잭션**을 실행한다.

예를 들어 주문 생성 Saga는 대략 이렇게 쪼개진다.

```text
T1  OrderService:    createOrder(PENDING)
T2  CustomerService: reserveCredit(orderId, amount)
T3  PaymentService:  authorizePayment(orderId)
T4  OrderService:    approveOrder(orderId)

C3  PaymentService:  voidAuthorization(orderId)
C2  CustomerService: releaseCredit(orderId)
C1  OrderService:    rejectOrder(orderId)
```

중요한 점은 `T1`이 커밋된 뒤 `T3`에서 실패해도 `T1` 자체를 롤백하지 않는다는 것이다. 공식 패턴 설명에 따르면 Saga는 커밋된 로컬 트랜잭션을 보상 액션으로 의미상 취소한다. Saga의 원자성은 DB의 atomic rollback이 아니라 **비즈니스 의미의 최종 수렴**에 가깝다.

### 2. 상태 전이로 보면 Saga는 작은 상태 머신이다

주문 Saga를 상태 전이로 표현하면 구현이 더 선명해진다.

```text
              reserve ok          authorize ok
START ──▶ ORDER_CREATED ──▶ CREDIT_RESERVED ──▶ PAYMENT_AUTHORIZED ──▶ APPROVED
             │                    │
             │ reserve fail        │ authorize fail
             ▼                    ▼
          REJECTED ◀──── CREDIT_RELEASED ◀──── COMPENSATING
```

각 노드는 "어느 로컬 트랜잭션까지 성공했는가"를 나타낸다. 실패 간선은 보상 트랜잭션으로 연결된다. 이 관점에서 Saga 구현의 핵심 자료구조는 현재 단계와 재시도 횟수를 담는 **Saga instance state**와 다음 메시지를 함께 기록하는 **outbox**다.

Outbox가 함께 필요한 이유는 Saga 단계의 로컬 상태 변경과 "다음 메시지 발행"도 dual write가 되기 때문이다. `CustomerService`가 신용 한도를 예약한 뒤 `CreditReserved` 이벤트 발행 전에 죽으면 Saga가 멈춘다.

### 3. Choreography-based Saga

Choreography에서는 중앙 지휘자가 없다. 각 서비스가 자기 로컬 트랜잭션을 커밋하고 도메인 이벤트를 발행한다. 다른 서비스는 그 이벤트를 구독하다가 다음 로컬 트랜잭션을 실행한다.

```text
OrderService       CustomerService       PaymentService       OrderService
    │                    │                    │                    │
    │ OrderCreated       │                    │                    │
    ├───────────────────▶│                    │                    │
    │                    │ CreditReserved     │                    │
    │                    ├───────────────────▶│                    │
    │                    │                    │ PaymentAuthorized  │
    │                    │                    ├───────────────────▶│
    │                    │                    │                    │ approve
```

알고리즘은 단순한 이벤트 반응 규칙들의 합이다.

```text
on OrderCreated:
  reserveCredit()
  publish CreditReserved or CreditLimitExceeded

on CreditReserved:
  authorizePayment()
  publish PaymentAuthorized or PaymentAuthorizationFailed

on PaymentAuthorizationFailed:
  releaseCredit()
  publish CreditReleased
```

장점은 낮은 진입 비용이다. 별도 오케스트레이터 없이 기존 이벤트 발행/구독으로 흐름을 붙일 수 있다. 단점은 상태가 흩어진다는 점이다. "주문 123의 Saga가 어디까지 갔는가"를 보려면 여러 서비스의 이벤트 로그를 이어 붙여야 한다. 또한 이벤트 구독자가 늘수록 이벤트 스키마가 암묵적 계약이 된다. 공식 문서나 패턴 설명에서 흔히 말하는 위험은 **cyclic dependency**다. A 이벤트가 B를 움직이고, B 이벤트가 C를 움직이고, C 이벤트가 다시 A를 움직이면 전체 흐름이 코드 한 곳에 드러나지 않는다.

### 4. Orchestration-based Saga

Orchestration에서는 Saga 오케스트레이터가 전체 상태를 가진다. 오케스트레이터는 각 참여자에게 command를 보내고, 참여자는 reply를 돌려준다. 다음 단계 선택과 보상 순서는 오케스트레이터가 결정한다.

상태 전이 규칙은 오케스트레이터 내부에 들어간다. 예를 들어 `RESERVING_CREDIT + CreditReserved -> AUTHORIZING_PAYMENT + AuthorizePayment command`, `AUTHORIZING_PAYMENT + PaymentFailed -> COMPENSATING + ReleaseCredit command` 같은 식이다. 자료구조 관점에서는 오케스트레이터가 `saga_instance` 테이블을 가진다.

```text
saga_instance(
  saga_id,
  saga_type,
  current_state,
  payload_json,
  last_message_id,
  retry_count,
  updated_at
)
```

오케스트레이터는 메시지를 받을 때 `last_message_id`나 command id로 중복을 걸러야 한다. 메시징은 보통 at-least-once이기 때문이다. 같은 reply가 두 번 와도 command가 두 번 나가면 안 된다. 따라서 상태 전이 함수는 멱등이어야 한다.

Orchestration의 장점은 가시성이다. Saga instance의 현재 상태, 실패 단계, 보상 진행 여부가 한 곳에 남는다. 복잡한 분기, 타임아웃, 재시도 정책도 중앙 상태 머신으로 관리하기 쉽다. 단점은 오케스트레이터가 참여자 command API를 알게 되므로 중앙 결합점이 생긴다는 점이다.

### 5. 실패 처리의 실제 순서

Saga 실패 처리는 "마지막 성공 단계부터 역순으로 보상"하는 스택처럼 생각할 수 있다. `T1 -> push C1`, `T2 -> push C2`, `T3 fail`이면 `C2`, `C1` 순서로 실행한다.

다만 모든 단계가 보상 가능한 것은 아니다. 이메일 발송처럼 이미 관측된 행위는 되돌릴 수 없다. 그래서 취소 어려운 작업은 가능한 뒤로 미루고, 앞 단계는 `PENDING`, `RESERVED` 같은 중간 상태를 사용한다. 또 Saga는 중간 커밋이 외부에 보이므로 isolation을 자동 제공하지 않는다. Richardson에 따르면 semantic lock 같은 countermeasure로 충돌을 피하도록 만들 수 있다.

### 6. Choreography vs Orchestration 비교

Choreography는 제어 흐름과 장애 대응이 이벤트 구독자들에게 분산되고, 결합은 이벤트 의미에 대한 암묵적 의존으로 생긴다. Orchestration은 제어 흐름이 오케스트레이터에 집중되고, 결합은 command API에 대한 명시적 의존으로 생긴다. 단계가 적고 이벤트 의미가 자연스럽게 드러나는 흐름은 Choreography가 충분할 수 있다. 반대로 분기와 보상, 타임아웃, 감사 추적이 중요하면 Orchestration이 더 읽히는 구조가 된다.

## 검증

출처 흐름을 따라가며 확인한 내용:

1. Microservices Patterns Ch.4의 Saga 정의는 "여러 로컬 트랜잭션의 시퀀스"와 "각 로컬 트랜잭션이 다음 단계를 트리거하는 메시지 발행"에 초점이 있다.
2. 같은 장에서 Choreography는 참여자들이 이벤트를 교환해 다음 단계를 결정하는 방식이고, Orchestration은 오케스트레이터가 command를 보내는 방식이다.
3. Eventuate Tram은 Saga command/reply와 saga instance 저장소를 제공한다. 이것은 Orchestration을 상태 머신 + 메시지 로그로 구현한다는 해석과 맞다.
4. Azure의 Saga 패턴 설명도 장기 실행 트랜잭션을 여러 작업과 보상 작업으로 나누며, 보상 작업이 항상 단순 역연산은 아니라고 설명한다.

간단한 의사 코드로 Orchestration의 핵심을 줄이면 다음과 같다.

```java
void handle(SagaId id, Message message) {
    SagaState state = repository.find(id);
    if (state.alreadyHandled(message.id())) return;

    Transition transition = stateMachine.next(state.current(), message);
    repository.save(state.apply(transition, message.id()));

    for (Command command : transition.commands()) {
        outbox.add(command); // saga state 저장과 같은 로컬 트랜잭션
    }
}
```

핵심은 `repository.save`와 `outbox.add`가 같은 로컬 트랜잭션이어야 한다는 점이다.

## 잘못 알고 있던 것

- **"Saga는 롤백을 제공한다"** → DB 트랜잭션처럼 이전 커밋을 원자적으로 되돌리는 rollback은 아니다. 이미 커밋된 로컬 트랜잭션을 별도 보상 트랜잭션으로 의미상 취소한다.
- **"Choreography는 결합이 없다"** → 직접 command 호출은 없지만 이벤트 이름과 payload 의미에 대한 결합은 있다. 소비자가 많아질수록 이벤트 스키마는 공유 계약이 된다.
- **"Orchestration은 무조건 나쁜 중앙집중"** → 단순 흐름에는 과할 수 있지만, 복잡한 보상과 타임아웃, 감사 추적이 필요한 Saga에서는 중앙 상태 머신이 오히려 장애 분석과 변경을 쉽게 만든다.

## 더 파고들 만한 것

- Saga isolation countermeasure: semantic lock, commutative update, reread value, version file의 실제 적용 사례.
- Orchestrator를 Temporal 같은 workflow engine으로 구현할 때 직접 구현한 saga table/outbox와 무엇이 달라지는지.

## 참고

- Microservices Patterns (Chris Richardson) Ch.4 — Managing transactions with sagas
- Eventuate Tram Sagas documentation and examples
- Azure Architecture Center — Saga distributed transactions pattern
