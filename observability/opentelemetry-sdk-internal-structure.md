# OpenTelemetry SDK 내부 구조

> **Primary source:** OpenTelemetry Specification - Overview, Trace SDK, Metrics SDK, Logs SDK, Resource SDK, SDK configuration
> **Secondary:** OpenTelemetry Docs - Context propagation, Manual instrumentation examples
> **Date:** 2026-06-15
> **Status:** draft

## 왜 봤나

- OpenTelemetry를 "trace를 만들어 collector로 보내는 라이브러리" 정도로 이해했는데, 실제 SDK는 API, Context, Provider, Processor/Reader, Exporter, Resource가 분리된 파이프라인에 가깝다.

## 핵심 한 문장

> OpenTelemetry SDK는 애플리케이션 코드가 호출하는 안정적인 API 뒤에서 telemetry signal을 생성, 샘플링/집계, 큐잉, export하는 플러그형 런타임이며, 핵심은 Provider가 InstrumentationScope와 Resource를 붙여 signal별 처리 파이프라인으로 넘기는 구조다.

## 내부 동작

OpenTelemetry 공식 스펙은 API와 SDK의 책임을 분리한다. API는 instrumentation library가 의존하는 표면이다. 예를 들어 HTTP client instrumentation은 `Tracer`를 얻고 span을 시작하지만, 어떤 backend로 보낼지, batch 크기는 얼마인지, sampling은 어떻게 할지는 알지 못해야 한다. SDK는 이 API 뒤에 꽂히는 구현체다. 따라서 애플리케이션이 SDK를 설치하지 않으면 API는 대개 no-op 또는 기본 context 동작만 제공하고, SDK를 등록해야 실제 record/export 경로가 열린다.

큰 그림은 다음처럼 볼 수 있다.

```text
application / instrumentation library
        |
        | OpenTelemetry API
        v
TracerProvider / MeterProvider / LoggerProvider
        |
        | creates instrument bound to InstrumentationScope
        v
Span / Metric stream / LogRecord
        |
        | enrich with Context + Resource + attributes
        v
Processor / Reader / Aggregator
        |
        | batch, sample, aggregate, temporality conversion
        v
Exporter
        |
        v
Collector or backend
```

여기서 Provider는 signal별 factory이자 설정 루트다. 공식 Trace SDK 스펙에 따르면 `Tracer`는 `TracerProvider`를 통해 생성되어야 하고, 사용자가 넘긴 이름, 버전, schema URL 같은 값은 `InstrumentationScope`로 저장된다. 이 구조는 "어떤 라이브러리가 만든 telemetry인가"를 런타임 데이터와 분리해 보존하기 위한 자료구조다. 같은 프로세스의 `service.name`은 Resource에 들어가고, `io.opentelemetry.jdbc` 같은 instrumentation library 식별자는 Scope에 들어간다.

```text
Resource
  service.name=order-api
  host.name=ip-10-0-1-7
  container.id=...

InstrumentationScope
  name=io.opentelemetry.spring-webmvc
  version=1.32.0

Span
  name=GET /orders/{id}
  trace_id=...
  span_id=...
  attributes=http.method, http.route, ...
```

Resource는 telemetry를 만든 엔티티를 설명하는 immutable한 속성 묶음으로 보는 편이 안전하다. 공식 overview는 Resource가 telemetry가 기록되는 entity 정보를 담는다고 설명한다. SDK 초기화 시점에 environment detector, process detector, cloud detector 같은 구현이 resource를 합치고, 이후 각 span, metric, log record는 이 resource와 함께 export된다. 이 덕분에 instrumentation code가 매 span마다 `service.name`을 다시 붙이지 않아도 backend는 같은 service 인스턴스에서 온 데이터로 묶을 수 있다.

Trace SDK의 런타임 상태 전이는 비교적 명확하다. 요청이 들어오면 propagator가 carrier에서 parent context를 추출한다. `Tracer.startSpan`은 현재 Context를 읽어 parent를 정하고, sampler를 호출한 뒤, recording span 또는 non-recording span을 만든다. span이 종료되면 `SpanProcessor.onEnd` 경로로 넘어가고, processor는 exporter에 바로 넘기거나 batch queue에 넣는다.

```text
incoming carrier
  -> Propagator.extract
  -> Context(parent SpanContext)
  -> Tracer.startSpan
       -> IdGenerator
       -> Sampler.shouldSample
       -> SpanLimits check
  -> Span in current Context
  -> span.end()
  -> SpanProcessor.onEnd
  -> Exporter.export
```

Sampler는 span 시작 시점의 게이트다. 공식 스펙 기준으로 sampling decision은 `RECORD_AND_SAMPLE`, `RECORD_ONLY`, `DROP` 같은 결과로 표현된다. `DROP`이면 downstream 전파를 위한 `SpanContext`는 존재할 수 있지만 attribute/event를 저장하는 recording span은 만들지 않는다. `ParentBased` sampler가 자주 쓰이는 이유는 이미 들어온 parent의 sampled flag를 우선 반영하면서 root span에는 별도 확률 또는 always-on 정책을 적용할 수 있기 때문이다. 따라서 "collector에서 안 보인다"는 현상은 exporter 실패뿐 아니라 SDK sampler에서 이미 record되지 않았을 가능성도 같이 봐야 한다.

BatchSpanProcessor는 내부 자료구조 관점에서 bounded queue와 worker loop로 이해할 수 있다. 공식 문서와 여러 SDK 구현은 세부 상수는 다를 수 있지만, 공통 흐름은 종료된 span을 큐에 넣고, 일정 주기 또는 batch size 도달 시 exporter를 호출하는 방식으로 알려져 있다.

```text
onEnd(span):
  if span is not sampled/recording:
    return
  if queue is full:
    drop or count dropped span
  else:
    enqueue ReadableSpan

worker loop:
  wait until schedule delay or batch threshold
  drain up to max export batch size
  exporter.export(batch)
  retry behavior is exporter/transport specific
```

이 설계는 애플리케이션 요청 스레드가 네트워크 export에 직접 묶이지 않도록 한다. 대신 queue overflow라는 backpressure 지점이 생긴다. 관측 데이터는 업무 데이터보다 낮은 우선순위로 다뤄지는 경우가 많으므로, SDK는 보통 요청을 멈추기보다 span을 drop하고 dropped count를 남기는 방향을 택한다. 반대로 `SimpleSpanProcessor`는 span 종료 시 exporter를 바로 호출하므로 테스트나 로컬 콘솔 출력에는 단순하지만, production 요청 경로에서는 latency와 exporter 장애 전파를 조심해야 한다.

Metric SDK는 trace보다 더 상태ful하다. Span은 시작과 종료가 있는 이벤트 레코드에 가깝지만, metric instrument는 값의 stream을 만들고 reader가 주기적으로 수집한다. 공식 Metrics SDK 스펙은 `MeterProvider`, `Meter`, instrument, aggregation, metric reader/exporter의 역할을 나눈다. Counter, Histogram, ObservableGauge 같은 instrument는 측정값을 직접 export하지 않고, SDK 내부 aggregator가 time series별 상태를 들고 있다가 collection 시점에 data point로 변환한다.

```text
record(value, attributes)
  -> select metric stream by instrument + view
  -> attribute set becomes time-series key
  -> aggregator state update

collect()
  -> reader locks/snapshots aggregator state
  -> temporality(delta/cumulative) applied
  -> exporter.export(ResourceMetrics)
```

여기서 자료구조의 핵심은 attribute set이 time series key가 된다는 점이다. 예를 들어 `http.server.duration` histogram에 `http.route`, `method`, `status_code`만 있으면 제한된 조합이지만, `user.id`를 넣으면 aggregator map의 key 수가 사용자 수만큼 늘어난다. trace attribute는 span 하나의 payload로 끝나지만 metric attribute는 장시간 유지되는 집계 상태를 만들 수 있다. 그래서 metric cardinality는 SDK 메모리 사용량과 collector/backend 비용에 직접 연결된다.

View는 Metric SDK의 중요한 제어점이다. 공식 스펙에서 View는 instrument가 생성하는 metric stream의 이름, 설명, attribute 필터, aggregation 등을 바꾸는 설정으로 정의된다. 즉 instrumentation library가 넓은 attribute를 기록하더라도, 애플리케이션 SDK 설정에서 고카디널리티 attribute를 제거하거나 histogram bucket을 조정할 수 있다. 이 책임 분리는 라이브러리 작성자와 운영자가 같은 결정을 공유하지 않아도 되게 한다.

Logs SDK는 trace와 비슷하게 `LoggerProvider`와 `LogRecordProcessor`, `LogRecordExporter`를 둔다. 다만 log record는 span처럼 lifecycle이 길게 유지되는 객체라기보다 한 번 emit되는 이벤트에 가깝다. 현재 context에 active span이 있으면 trace id와 span id가 붙을 수 있고, Resource와 Scope도 함께 export된다. 따라서 OpenTelemetry logs의 장점은 "로그를 대체한다"보다 trace, metric과 같은 Resource/Semantic Convention 축으로 상관관계를 만들 수 있다는 데 있다.

세 signal은 모두 Context를 공유하지만, Context와 Resource는 다르다. Context는 요청 흐름에 따라 변하는 실행 상태다. async boundary를 넘을 때 capture/restore가 필요하고, 현재 active span이나 baggage를 들고 다닌다. Resource는 프로세스나 배포 단위의 정적 설명에 가깝다. 이 둘을 섞어 생각하면 `service.name`을 context에 넣거나, 반대로 request id를 resource에 넣는 실수를 하게 된다.

```text
Resource: process/deployment identity
  service.name, service.version, host.name

Context: execution flow identity
  active span, baggage, propagation state

Scope: instrumentation library identity
  library name, version, schema url
```

SDK 설정은 이 부품들을 조립하는 단계다. OpenTelemetry SDK configuration 스펙은 tracer provider, meter provider, logger provider와 exporter, processor, reader를 구성 요소로 다룬다. 실제 언어별 SDK는 환경 변수와 코드 기반 builder를 함께 제공하는 경우가 많다. 운영 관점에서는 `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`, `OTEL_PROPAGATORS` 같은 설정이 Provider와 exporter pipeline의 기본값을 만든다고 이해하면 된다.

초기화 순서도 중요하다. 자동 instrumentation이나 library instrumentation은 전역 provider에서 tracer/meter/logger를 얻는다. 애플리케이션 시작 초기에 SDK를 등록하지 않으면, 먼저 초기화된 instrumentation이 no-op provider를 잡거나 나중에 provider 교체가 언어별 제약에 걸릴 수 있다. 공식 스펙은 전역 API와 SDK 구현의 경계를 정의하지만, 구체적인 lifecycle은 언어 SDK마다 차이가 있으므로 production에서는 해당 언어의 공식 문서를 같이 확인해야 한다.

정리하면 OpenTelemetry SDK는 단일 "전송 클라이언트"가 아니라 signal별 pipeline을 가진 런타임이다. Trace는 span lifecycle과 sampling, Metric은 time series 집계와 cardinality, Logs는 context-correlated event export가 중심이다. Resource와 Scope는 모든 signal에 붙는 메타데이터 축이고, Context는 요청 흐름을 이어 주는 상태 전파 축이다. 이 경계를 알고 보면 collector 설정 문제, SDK sampling 문제, metric cardinality 문제, context propagation 문제가 서로 다른 층의 문제라는 점이 보인다.

## 검증

이번 노트는 코드 실험 대신 OpenTelemetry 스펙의 컴포넌트 흐름을 따라 검증했다.

```text
1. Trace SDK 스펙은 Tracer가 TracerProvider를 통해 생성되고 InstrumentationScope를 저장한다고 설명한다.
2. Overview는 Resource를 telemetry가 기록되는 entity 정보로 둔다.
3. Context propagation 문서는 cross-cutting concern이 Context를 공유한다고 설명한다.
4. Metrics SDK는 instrument 측정값을 aggregation과 reader/exporter 경로로 분리한다.
5. SDK configuration은 Provider, Processor/Reader, Exporter를 조립 가능한 구성 요소로 다룬다.
```

이 흐름으로 보면 SDK 내부 구조는 다음 불변식으로 정리된다.

```text
API call does not decide backend.
Provider creates signal instruments.
Resource describes producer identity.
Scope describes instrumentation identity.
Processor/Reader decouples app thread from export path.
Exporter is the boundary to collector/backend.
```

## 잘못 알고 있던 것

- OpenTelemetry SDK를 exporter 설정과 거의 같은 것으로 생각했다. 실제로 exporter는 마지막 경계이고, 그 앞에 provider, sampler, processor, reader, aggregator, resource detection이 있다.
- Trace와 metric이 같은 방식으로 "이벤트를 보내는 것"이라고 생각하기 쉽다. trace span은 종료 후 batch export되는 레코드에 가깝고, metric은 attribute set별 집계 상태를 유지하다가 collection 시점에 data point가 된다.
- `service.name` 같은 값과 active span context를 같은 층으로 보면 안 된다. Resource는 producer identity이고, Context는 요청 실행 흐름의 상태다.

## 더 파고들 만한 것

- OpenTelemetry metric cardinality 폭발이 SDK aggregator와 backend 저장 비용에 어떤 영향을 주는지 보기.
- Java SDK의 `BatchSpanProcessor`, `SdkTracerProvider`, `PeriodicMetricReader` 소스에서 실제 queue와 collection loop 확인하기.

## 참고

- OpenTelemetry Specification - Overview: https://opentelemetry.io/docs/specs/otel/overview/
- OpenTelemetry Specification - Trace SDK: https://opentelemetry.io/docs/specs/otel/trace/sdk/
- OpenTelemetry Specification - Metrics SDK: https://opentelemetry.io/docs/specs/otel/metrics/sdk/
- OpenTelemetry Specification - Logs SDK: https://opentelemetry.io/docs/specs/otel/logs/sdk/
- OpenTelemetry Specification - Resource SDK: https://opentelemetry.io/docs/specs/otel/resource/sdk/
- OpenTelemetry Specification - SDK configuration: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/configuration/sdk.md
- OpenTelemetry Docs - Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
