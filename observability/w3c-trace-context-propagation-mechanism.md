# W3C Trace Context 전파 메커니즘

> **Primary source:** W3C Trace Context Recommendation - `traceparent`, `tracestate`
> **Secondary:** OpenTelemetry Context propagation 개념 문서
> **Date:** 2026-06-14
> **Status:** draft

## 왜 봤나

- 분산 트레이싱에서 "trace id를 헤더로 넘긴다" 정도로 이해했는데, 실제 전파 규칙은 `trace-id` 유지, `parent-id` 교체, `tracestate` 순서 갱신이라는 꽤 엄격한 상태 전이에 가깝다.

## 핵심 한 문장

> W3C Trace Context는 서비스 경계를 넘을 때 같은 `trace-id`로 하나의 trace를 이어 붙이고, 각 hop마다 새 `parent-id`를 발급하며, 벤더별 상태는 왼쪽 우선순위의 `tracestate` 리스트로 보존하는 전파 규약이다.

## 내부 동작

W3C Trace Context는 HTTP 같은 프로토콜 경계에서 trace 식별 정보를 표준 헤더로 주고받기 위한 규약이다. 공식 스펙에 따르면 핵심 헤더는 `traceparent`와 `tracestate`다. `traceparent`는 모든 구현이 공통으로 해석해야 하는 최소 식별자이고, `tracestate`는 tracing vendor나 플랫폼이 추가 상태를 담을 수 있는 확장 영역이다.

`traceparent` version `00`의 자료구조는 네 개 필드로 볼 수 있다.

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             vv -------------------------------- ss-------------- ff
             |  trace-id                         parent-id        trace-flags
             version
```

공식 스펙 기준으로 `trace-id`는 16바이트 배열을 32개 lowercase hex 문자로 표현하고, 전체가 0이면 invalid다. `parent-id`는 8바이트 배열을 16개 lowercase hex 문자로 표현하며, 역시 전체 0은 invalid다. `trace-flags`는 8비트 플래그이고 현재는 least significant bit가 sampled 여부로 쓰인다. 따라서 `traceparent`는 문자열처럼 보이지만 실제로는 고정 길이 binary 식별자를 hex encoding한 레코드에 가깝다.

전파 알고리즘을 상태 전이로 쓰면 다음과 같다.

```text
incoming request
  |
  | parse traceparent
  v
valid context? ---- no ----> start new trace
  |
 yes
  v
create local span
  trace-id   = incoming.trace-id
  parent     = incoming.parent-id
  span-id    = new 8-byte id
  sampled    = incoming trace-flags bit 0, unless local policy overrides
  |
  | inject outbound headers
  v
outgoing traceparent
  trace-id   = same trace-id
  parent-id  = local span-id
  flags      = current trace flags
```

여기서 중요한 점은 `parent-id`라는 이름이 "나의 부모 span id"로 저장된다는 점이다. 수신 서비스 입장에서 incoming `parent-id`는 upstream span의 id다. 하지만 그 서비스가 downstream으로 요청을 보낼 때는 자기 span id를 새 outbound `parent-id`로 넣어야 한다. 공식 문서가 `traceparent`를 incoming request를 식별하는 헤더라고 설명하는 이유도 이 방향성 때문이다.

예를 들어 A -> B -> C 호출에서 `trace-id`는 계속 유지되고, `parent-id`는 hop마다 바뀐다.

```text
A span aaaa1111bbbb2222
  outbound to B:
  traceparent: 00-TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT-aaaa1111bbbb2222-01

B receives parent-id=aaaa1111bbbb2222
B span bbbb3333cccc4444
  outbound to C:
  traceparent: 00-TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT-bbbb3333cccc4444-01

C receives parent-id=bbbb3333cccc4444
```

이 구조 덕분에 collector나 backend는 같은 `trace-id`를 가진 span들을 모으고, 각 span의 parent 관계를 따라 tree 또는 DAG에 가까운 호출 그래프를 복원할 수 있다. Trace Context 자체가 모든 span을 저장하는 것은 아니다. 헤더는 다음 hop이 어떤 trace에 붙어야 하는지만 전달하고, span의 시작/종료 시간, attribute, event 같은 telemetry payload는 OpenTelemetry exporter 같은 별도 경로로 나간다.

`traceparent` 수신 상태는 대략 네 가지로 나눌 수 있다.

```text
missing       -> root span으로 새 trace 시작
valid         -> 같은 trace-id로 child span 생성
invalid       -> 기존 헤더 무시, 새 trace 시작 또는 non-recording 처리
future version-> 스펙의 version 처리 규칙에 맞춰 가능한 한 forward
```

공식 스펙에 따르면 invalid `trace-id`를 받은 vendor는 `traceparent`를 무시해야 한다. 이 규칙은 부분적으로 깨진 값을 억지로 이어 붙였을 때 서로 다른 요청이 한 trace로 합쳐지는 문제를 막는다. 특히 all-zero trace id나 parent id는 금지되어 있으므로, "없음"을 0으로 표현하는 구현은 전파 경계에서 버려질 수 있다.

`trace-flags`의 sampled bit는 전역 명령이라기보다 caller가 남긴 sampling decision이다. 공식 스펙은 현재 한 비트만 사용한다고 설명한다. downstream은 이 비트를 참고해 recording/export 여부를 맞출 수 있지만, 로컬 정책이 always-on, parent-based, tail sampling 같은 방식이면 실제 저장 여부는 시스템마다 달라질 수 있다. 따라서 `01`은 "반드시 모든 backend에 저장된다"보다 "이 컨텍스트는 sampled로 표시되어 전파된다"에 가깝게 보는 편이 안전하다.

`tracestate`는 더 미묘하다. 스펙은 `tracestate`를 list 형태로 정의하고, 왼쪽 항목이 `traceparent`를 쓴 tracing system과 대응된다고 설명한다. 어떤 서비스가 자기 vendor 상태를 갱신하면 자기 key를 왼쪽으로 옮기고, 다른 vendor의 항목은 오른쪽으로 밀어 보존한다.

```text
incoming:
  traceparent: 00-TTTT...-upstreamspan0001-01
  tracestate:  rojo=00f067aa0ba902b7,congo=t61rcWkgMzE

service using congo creates local span:
  traceparent parent-id = congo local span id
  tracestate: congo=<new-state>,rojo=00f067aa0ba902b7
```

자료구조로는 `tracestate`를 ordered map 또는 linked list처럼 생각할 수 있다. key는 중복되면 안 되고, 갱신한 key는 head로 이동한다. 이 head 우선순위 때문에 여러 tracing system이 같은 요청을 거쳐도 "현재 `traceparent`를 해석할 때 가장 관련 있는 vendor 상태"를 왼쪽에서 찾을 수 있다. 반대로 단순 map처럼 정렬하거나 직렬화 순서를 잃어버리면 의미가 바뀔 수 있다.

전파 레이어에서 해야 하는 일은 보통 세 단계다.

```text
extract(carrier):
  header map에서 traceparent/tracestate 읽기
  ABNF와 invalid 값 검사
  Context 객체 생성

startSpan(context):
  parent context를 현재 실행 흐름에 attach
  local span-id 생성
  sampler 결정 반영

inject(carrier):
  현재 Context에서 traceparent 재구성
  tracestate 갱신 후 header map에 쓰기
```

이때 `carrier`는 HTTP header map일 수도 있고, message broker record header일 수도 있다. W3C 스펙은 HTTP 헤더 형식을 정의하지만, OpenTelemetry에서는 propagation API가 carrier getter/setter를 추상화한다. 그래서 같은 Context가 HTTP 서버, gRPC metadata, Kafka header 같은 다른 운반체로 옮겨질 수 있다. 단, 운반체가 대소문자, 중복 헤더, 최대 길이를 다르게 다루면 구현은 스펙의 파싱 규칙과 플랫폼 제약을 함께 봐야 한다.

메모리 관점에서는 trace context가 대용량 객체일 필요가 없다. 최소 상태는 `traceId[16]`, `spanId[8]`, `traceFlags[1]`, `traceState entries[]` 정도다. 문제는 이 값을 어디에 보관하느냐다. 동기 호출에서는 thread-local context로 충분해 보이지만, async/reactive 코드에서는 실행이 다른 thread로 넘어가므로 context capture/restore가 필요하다. Trace Context 스펙은 wire format을 정의하고, 실행 컨텍스트 전파는 각 SDK가 맡는 경계로 이해할 수 있다.

```text
HTTP header bytes
  -> parsed SpanContext
  -> current execution Context
  -> local Span
  -> outgoing HTTP header bytes
```

결국 W3C Trace Context의 핵심은 "헤더를 복사한다"가 아니다. 수신 시에는 유효성을 검사해 부모 컨텍스트를 만들고, 로컬 span을 만든 뒤, 송신 시에는 같은 trace id와 새 parent id로 헤더를 다시 쓴다. `tracestate`는 순서를 가진 vendor 상태로 다뤄야 한다. 이 세 규칙이 지켜져야 서비스가 서로 다른 SDK와 vendor를 쓰더라도 하나의 trace graph로 이어진다.

## 검증

이번 노트는 코드 실험 대신 W3C 스펙의 header format과 relationship 설명을 따라 흐름을 검증했다.

```text
1. traceparent version 00은 version, trace-id, parent-id, trace-flags로 구성된다.
2. trace-id와 parent-id는 all-zero 값이 invalid다.
3. 서비스가 outbound 요청을 만들 때 trace-id는 유지하고 parent-id는 local span id로 바꾼다.
4. tracestate는 갱신한 vendor entry를 왼쪽으로 두고 기존 entry를 보존한다.
```

이 흐름으로 보면 A -> B -> C에서 trace id가 같아지는 이유와 span parent 관계가 복원되는 이유가 분리된다. 같은 trace로 묶는 키는 `trace-id`이고, 직전 hop의 부모-자식 관계를 잇는 키는 매번 교체되는 `parent-id`다.

## 잘못 알고 있던 것

- `parent-id`를 요청 전체에서 유지되는 값으로 착각하기 쉽다. 실제로는 각 hop의 outbound 헤더에서 현재 span id로 교체되어야 한다.
- `tracestate`를 평범한 key-value map으로 보면 위험하다. 공식 스펙의 예시처럼 왼쪽 항목이 우선순위를 가지므로 순서가 의미다.
- sampled flag는 trace 저장을 절대 보장하는 스위치가 아니다. 전파되는 sampling decision이며, 실제 recording/export는 SDK와 backend 정책의 영향을 받는다.

## 더 파고들 만한 것

- OpenTelemetry propagator가 HTTP, gRPC, Kafka carrier에 같은 Context를 주입/추출하는 방식.
- tail sampling을 쓰는 collector 환경에서 `trace-flags` sampled bit와 최종 저장 결정이 어떻게 달라지는지.

## 참고

- W3C Trace Context Recommendation: https://www.w3.org/TR/trace-context/
- W3C Trace Context Level 2 Working Draft: https://www.w3.org/TR/trace-context-2/
- OpenTelemetry Docs - Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
