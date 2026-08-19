# OpenTelemetry TraceIdRatioBased 샘플러: trace ID 하위 64비트로 만드는 결정론적 확률 샘플링

> **Primary source:** OpenTelemetry Specification — Trace SDK, Sampling (https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling)
> **Secondary:** opentelemetry-java 소스 `sdk/trace/.../samplers/TraceIdRatioBasedSampler.java`
> **Date:** 2026-08-19
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/otel-traceidratio-sampler-monotonicity

## 왜 봤나

- 분산 트레이싱에서 모든 span을 다 수집하면 저장·전송 비용이 트래픽에 선형으로 붙기 때문에 샘플링은 거의 필수다. 마이크로서비스 환경에서는 한 트레이스에 서비스마다 각자 샘플러가 붙는데, 서비스 A는 샘플링하고 B는 하지 않으면 트레이스가 중간에 뜯긴 채로 백엔드에 도착한다.
- 흔히 "샘플링 = 매 span마다 동전을 던지는 무작위 결정"으로 생각하기 쉽지만, 그렇다면 서비스마다 결과가 달라지는 게 당연해진다. `TraceIdRatioBased` 샘플러는 "무작위성의 소스를 트레이스 ID 자체로 고정"해 이 문제를 푼다 — 이 설계가 왜 필요하고, "샘플링 비율을 낮춰도 이미 샘플링되던 집합은 유지된다"는 성질(monotonicity)을 어떻게 보장하는지가 이 노트의 핵심이다.

## 핵심 한 문장

> `TraceIdRatioBased` 샘플러는 매 호출마다 새 난수를 뽑는 게 아니라 **trace ID의 하위 64비트를 난수원(random source)으로 재사용**해 `ratio × Long.MAX_VALUE`로 계산한 임계값과 비교하는 순수 함수이며, 이 덕분에 같은 트레이스는 어떤 서비스·어떤 언어의 SDK에서 판단해도 항상 같은 결론이 나오고, 비율을 낮춰도 기존에 뽑히던 집합의 부분집합만 남는다.

## 내부 동작

### 1. IsRecording과 Sampled flag는 별개의 축이다

스펙은 두 속성을 분리한다.

- **IsRecording**: false면 해당 span은 속성·이벤트·상태 등 모든 트레이싱 데이터를 그냥 버린다(discard). 이 값이 true인 span만 Span Processor로 넘어간다.
- **Sampled flag**: `SpanContext`의 `TraceFlags`에 들어 있는 비트로, 자식 span에 그대로 전파(propagate)되며 "이 span은 exporter로 내보내진다"는 뜻이다.

`Sampler.ShouldSample()`은 이 두 축을 조합한 3가지 `Decision` 중 하나를 반환한다.

| Decision | IsRecording | Sampled flag |
| --- | --- | --- |
| `DROP` | false | (설정 안 함) |
| `RECORD_ONLY` | true | 설정 안 함 |
| `RECORD_AND_SAMPLE` | true | 설정함 |

스펙은 "`Sampled=true`인데 `IsRecording=false`인 조합은 금지"한다고 명시한다 — 자식은 부모의 Sampled flag를 보고 "이 트레이스는 기록되는 중"이라 믿고 자기도 기록하는데, 부모가 실제로 기록하지 않았다면 분산 트레이스 중간에 구멍(gap)이 남기 때문이다.

### 2. TraceIdRatioBased: 해싱이 아니라 "이미 있는 난수" 재사용

trace ID는 128비트 랜덤 값으로 생성된다(W3C Trace Context 레벨 2 요구사항을 만족하면 SDK가 `TraceFlags`에 Random 비트를 세팅하도록 스펙이 권고한다). `TraceIdRatioBased` 샘플러는 이 중 **하위 64비트만** 떼어내 부호 있는 `long`으로 해석해 임계값과 비교한다.

opentelemetry-java 구현(`TraceIdRatioBasedSampler.java`)에서 확인한 실제 로직:

```java
// 생성자에서 ratio -> 임계값(idUpperBound) 변환
if (ratio == 0.0) {
  idUpperBound = Long.MIN_VALUE;      // 아무것도 안 뽑힘
} else if (ratio == 1.0) {
  idUpperBound = Long.MAX_VALUE;      // 전부 뽑힘
} else {
  idUpperBound = (long) (ratio * Long.MAX_VALUE);
}

// trace ID의 하위 64비트(hex 문자열 뒤 16자)를 long으로 변환
private static long getTraceIdRandomPart(String traceId) {
  return OtelEncodingUtils.longFromBase16String(traceId, 16);
}

// shouldSample()의 판정
return Math.abs(getTraceIdRandomPart(traceId)) < idUpperBound
    ? POSITIVE_SAMPLING_RESULT
    : NEGATIVE_SAMPLING_RESULT;
```

32자리 hex trace ID를 앞 16자(상위 64비트, 미사용)와 뒤 16자(하위 64비트, `long`으로 해석)로 쪼개고, 뒤쪽 절댓값이 `ratio × Long.MAX_VALUE`보다 **작으면** 샘플링한다.

```
trace_id (32 hex chars)
[ 4bf92f3577b34da6 | a3ce929d0e0e4736 ]
   상위 64bit(미사용)   하위 64bit → long v
                        |v| <  t → SAMPLE
                        |v| >= t → DROP   (t = ratio * Long.MAX_VALUE)
```

`abs(v)`는 `[0, Long.MAX_VALUE]` 범위이고 임계값 `t = ratio * Long.MAX_VALUE`이므로, 결국 "`v`가 `[0, t]` 구간에 들어가는가"만 검사하는 것과 같다. 이게 바로 **monotonicity**(단조성)를 만든다. 스펙은 "낮은 확률의 `TraceIdRatioBased` 샘플러가 뽑는 트레이스는, 더 높은 확률의 샘플러가 뽑는 트레이스 집합의 부분집합이어야 한다"고 요구한다. `t`가 커질수록 구간이 순수하게 확장되기만 하므로 — `ratio=0.1`에서 뽑혔다면 `[0, t(0.1)] ⊂ [0, t(0.5)]`이니 `ratio=0.5`에서도 반드시 뽑힌다. 매번 새 난수를 굴리는 방식이었다면 이 포함 관계는 보장되지 않는다.

결정성(determinism)도 같은 구조에서 나온다: 입력이 `traceId`와 `ratio`뿐인 순수 함수라 같은 트레이스 ID면 어떤 언어의 SDK가 판정하든 같은 `t`, `v`, 같은 결과가 나온다. 스펙은 "결정론적 해시를 반드시 써야 한다"고 표현하지만, 실제 구현은 해시를 새로 계산하지 않고 "trace ID 자체가 이미 128비트 난수이니 그중 일부를 재사용"한다 — 생성 시점의 무작위성을 그대로 신뢰하는 설계다.

이 샘플러는 "부모의 `SampledFlag`를 무시해야 한다"고 스펙에 명시되어 있다 — 오직 `traceId`와 `ratio`만으로 판단하는 독립 샘플러이기 때문에, 부모 컨텍스트를 참고하는 로직은 별도 데코레이터(`ParentBased`)로 분리된다.

### 3. ParentBased: 부모 유무·종류에 따라 4갈래로 위임

`ParentBased`는 자체 알고리즘이 없는 "데코레이터"다. 필수 파라미터 `root` 하나와 선택 파라미터 4개로 구성된다.

| 상황 | 파라미터 | 기본값 |
| --- | --- | --- |
| 부모 없음(root span) | `root` | (필수, 기본값 없음) |
| remote 부모, Sampled=true | `remoteParentSampled` | AlwaysOn |
| remote 부모, Sampled=false | `remoteParentNotSampled` | AlwaysOff |
| local 부모, Sampled=true | `localParentSampled` | AlwaysOn |
| local 부모, Sampled=false | `localParentNotSampled` | AlwaysOff |

기본값 조합만 보면 "부모가 있으면 그 Sampled 값을 그대로 따른다"처럼 보이지만, 이는 기본값이 우연히 그렇게 짜여 있어서다 — 실제로는 5개의 독립된 delegate 슬롯이라 경로마다 다른 전략(예: remote 부모는 신뢰, local 부모는 재평가)을 끼울 수 있다.

```
ShouldSample() 호출
   │
   ├─ parent SpanContext 없음/invalid ──────────────→ root.ShouldSample()
   │
   ├─ parent가 remote
   │      ├─ parent.Sampled == true  ───────────────→ remoteParentSampled.ShouldSample()
   │      └─ parent.Sampled == false ───────────────→ remoteParentNotSampled.ShouldSample()
   │
   └─ parent가 local(같은 프로세스)
          ├─ parent.Sampled == true  ───────────────→ localParentSampled.ShouldSample()
          └─ parent.Sampled == false ───────────────→ localParentNotSampled.ShouldSample()
```

## 검증

순수 산술 함수라 로컬에서 그대로 재현할 수 있다. JShell에서 실행하면 위에서 설명한 두 성질(같은 trace ID → 항상 같은 결정, 낮은 ratio가 높은 ratio의 부분집합)을 직접 확인할 수 있다.

```java
// jshell> 에 그대로 붙여넣기
import java.math.BigInteger;

long idUpperBound(double ratio) {
  if (ratio == 0.0) return Long.MIN_VALUE;
  if (ratio == 1.0) return Long.MAX_VALUE;
  return (long) (ratio * (double) Long.MAX_VALUE);
}

boolean shouldSample(String traceIdHex, double ratio) {
  long v = new BigInteger(traceIdHex.substring(16), 16).longValue(); // 하위 64bit
  return Math.abs(v) < idUpperBound(ratio);
}

String tid = "4bf92f3577b34da6a3ce929d0e0e4736";
System.out.println(shouldSample(tid, 0.5)); // 재실행해도 항상 같은 결과

// monotonicity: prevAtLowRatio가 true인데 atHighRatio가 false인 경우는 절대 나오지 않아야 한다
boolean prevAtLowRatio = shouldSample(tid, 0.1);
boolean atHighRatio = shouldSample(tid, 0.9);
```

임의의 trace ID 여러 개로 `ratio`를 0.01 단위로 올려가며 스캔하면, "한 번 true였던 트레이스가 ratio를 더 올렸을 때 false가 되는" 사례는 이 구현에서 절대 나오지 않는다는 걸 확인할 수 있다.

## 잘못 알고 있던 것

- **오해: "샘플링은 span/trace마다 독립적으로 동전을 던지는 무작위 이벤트다."** 실제로는 무작위성의 소스가 trace ID 생성 시점에 한 번만 소비되고, 이후 판단은 그 값을 재사용하는 결정론적 비교다. 그래서 샘플러가 서비스마다 따로 있어도 같은 트레이스에 같은 결론을 낼 수 있다 — "매번 새로 굴리는 주사위"가 아니라 "이미 굴려진 주사위를 다시 읽는 것"이다.
- **오해: "샘플링 비율을 10% → 5%로 낮추면 완전히 다른 5%가 뽑힐 수 있다."** 구간 비교(`|v| < t`)와 monotonicity 요구사항 때문에, 비율을 낮추면 기존 집합의 부분집합만 남는다. 이 성질이 없으면 운영 중 비율을 실시간 조정할 때 트레이스 셋이 매번 요동쳐 비교·디버깅이 불가능해진다.
- **오해: "ParentBased는 그냥 부모의 결정을 상속한다."** 기본값 조합이 그렇게 보이게 만들 뿐, 실제로는 remote/local·sampled/not-sampled 4가지 조합마다 독립적인 delegate 슬롯이 있는 일반화된 데코레이터다.

## 더 파고들 만한 것

- **consistent probability sampling**: tracestate의 `ot` 키 `th` 필드로 threshold를 실어 tail-based·head-based 샘플러 간 일관성을 맞추는 최신 스펙 확장 — 여기서 다룬 단순 비율 비교가 tracestate 전파와 어떻게 합성되는지.
- W3C Trace Context의 `sampled` 플래그와 스펙의 "Random flag(레벨 2 요구사항)"의 관계 — trace ID 난수성 보장이 왜 별도 플래그로 명시돼야 하는지.

## 참고

- OpenTelemetry Specification, Trace SDK — Sampling: https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling
- opentelemetry-java 소스: `sdk/trace/src/main/java/io/opentelemetry/sdk/trace/samplers/TraceIdRatioBasedSampler.java`

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
