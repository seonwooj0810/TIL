# Prometheus 히스토그램과 histogram_quantile: 누적 버킷과 선형 보간이 만드는 근사 분위수

> **Primary source:** Prometheus Docs — Metric Types(Histogram), `promql/quantile.go`의 `bucketQuantile` 구현
> **Secondary:** Prometheus best practices(Histograms and summaries), Prometheus native histograms 문서
> **Date:** 2026-07-06
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/prometheus-histogram-quantile

## 왜 봤나

- 대시보드에 `histogram_quantile(0.99, ...)`로 찍히는 p99가 "실제 관측된 요청의 99번째 값"이라고 믿고 있었는데, 버킷 경계를 바꾸면 값이 출렁이는 걸 보고 이게 뭘 근거로 나온 숫자인지 파고들었다.
- "인스턴스별 p99를 평균 내면 전체 p99"라고 막연히 생각하던 것도 이참에 확인했다.

## 핵심 한 문장

> Prometheus 히스토그램은 미리 정한 경계(`le`)별 **누적 카운터**일 뿐이고, `histogram_quantile`은 그 카운터에서 목표 순위가 떨어지는 버킷을 찾아 **경계 사이를 선형 보간**해 되돌려주는 근사값이다 — 원본 관측값은 어디에도 저장되지 않는다.

## 내부 동작

### 히스토그램은 하나의 메트릭이 아니라 여러 시계열

`http_request_duration_seconds`라는 히스토그램을 선언하면 실제로는 아래 시계열들이 생긴다.

```
http_request_duration_seconds_bucket{le="0.1"}   # ≤0.1s 관측 수 (누적)
http_request_duration_seconds_bucket{le="0.25"}  # ≤0.25s (누적, 위를 포함)
http_request_duration_seconds_bucket{le="0.5"}
http_request_duration_seconds_bucket{le="1"}
http_request_duration_seconds_bucket{le="+Inf"}  # == _count
http_request_duration_seconds_sum                 # 관측값 합
http_request_duration_seconds_count               # 총 관측 수
```

핵심은 `_bucket`이 **누적(cumulative)**이라는 점이다. `le="0.5"` 버킷은 "0.5초 이하인 관측의 총 개수"이고 당연히 `le="0.25"` 값을 포함한다. 클라이언트 라이브러리는 `observe(v)` 호출 시 `v <= le`인 **모든** 상위 버킷 카운터를 1 증가시킨다. 모든 버킷은 단조 증가 카운터라서 프로세스 재시작 전까지 절대 줄지 않는다. `le="+Inf"`는 정의상 `_count`와 같다.

### histogram_quantile 알고리즘 (bucketQuantile)

`histogram_quantile(φ, b)`는 버킷 시계열 집합 `b`를 받아 다음을 수행한다. `promql/quantile.go`의 흐름을 따라가면:

1. 버킷을 `le` 오름차순 정렬한다. 최상위는 반드시 `+Inf`여야 한다(아니면 `NaN`).
2. 목표 순위 `rank = φ * count`를 구한다(`count` = `+Inf` 버킷의 값 = 총 관측 수).
3. 누적 카운트가 `rank` 이상이 되는 첫 버킷 `b`를 이진 탐색으로 찾는다.
4. 그 버킷 구간 `[하한, 상한]`에서 **선형 보간**한다:

```
bucketStart = (b가 첫 버킷이면 0, 아니면 이전 버킷의 le)
bucketEnd   = 버킷 b의 le
count       = 버킷 b의 관측 수 - 이전 버킷의 누적 수   # 이 버킷만의 개수
rank        = rank - 이전 버킷의 누적 수                # 이 버킷 안에서의 순위
결과 = bucketStart + (bucketEnd - bucketStart) * (rank / count)
```

즉 "버킷 안에서 관측값이 **균등 분포**한다"고 가정하고 경계 사이를 직선으로 나눈다. 이 균등 가정이 근사의 원천이자 오차의 원천이다.

경계 예외 두 가지가 결과를 크게 좌우한다.

- 목표 버킷이 최상위 `+Inf`면 보간할 상한이 없으므로 **두 번째로 큰 유한 `le`값**을 그대로 반환한다. → p99가 가장 큰 유한 버킷을 넘어가면, 실제가 얼마든 그 경계로 **clamp**된다.
- 목표 버킷이 첫 버킷이고 그 `le`가 음수 이하이면 보간 없이 그 `le`를 반환한다.

### rate와 집계가 왜 안쪽에 들어가나

버킷은 카운터라서 그대로 쓰면 프로세스 수명 전체 누적이다. 최근 창의 분포를 보려면 `rate(..._bucket[5m])`로 초당 증가율을 먼저 구한다(카운터 리셋도 rate가 흡수). 여러 인스턴스를 합칠 때는 **le별로 먼저 더한 뒤** 분위수를 구한다:

```promql
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```

버킷이 카운터라 `sum by (le)`로 여러 인스턴스를 정직하게 합칠 수 있다는 점이 히스토그램의 결정적 장점이다.

### 누적성 보정과 경계 가정

정의상 누적 버킷은 `le`가 커질수록 값이 단조 증가해야 한다. 그런데 `rate()`가 부동소수점 결과를 내면서 반올림 오차로 상위 버킷이 하위 버킷보다 아주 살짝 작아지는 비단조 상황이 생길 수 있다. `bucketQuantile`은 이진 탐색 전에 버킷을 훑으며 각 버킷 값을 "직전까지 본 최댓값 이상"으로 끌어올려 단조성을 강제(rectify)한다 — 그래서 미세한 float 오차가 분위수를 뒤집지 않는다.

첫 버킷의 하한을 0으로 잡는 가정도 중요하다. 응답시간처럼 항상 양수인 값에는 자연스럽지만, 값이 음수일 수 있는 지표라면 첫 버킷 보간이 실제보다 낮게 나온다. Prometheus가 첫 버킷 `le`가 음수 이하일 때 보간을 건너뛰고 그 `le`를 반환하는 예외는 이 왜곡을 부분적으로 막으려는 장치다.

한편 평균 지연은 분위수와 무관하게 `_sum / _count`(창으로 보면 `rate(_sum[5m]) / rate(_count[5m])`)로 정확히 구할 수 있다. 평균은 보간이 필요 없어 정확하지만 꼬리(tail)를 못 보고, 분위수는 꼬리를 보지만 근사다 — 둘은 상호 보완이지 대체가 아니다.

## 검증

`quantile.go`의 공식에 구체적 숫자를 넣어 손으로 따라가 본다. rate 적용 후 누적 카운트가 이렇다고 하자(총 100).

```
le=0.1 : 20      le=0.25 : 50     le=0.5 : 90
le=1   : 98      le=+Inf : 100
```

- **p90**: rank = 0.9·100 = 90. 누적 ≥90인 첫 버킷 = `le=0.5`(90). 이전(`le=0.25`)=50 → 이 버킷 개수 = 90−50 = 40, 버킷 내 순위 = 90−50 = 40. 결과 = 0.25 + (0.5−0.25)·(40/40) = **0.5s**.
- **p95**: rank = 95. 첫 버킷 = `le=1`(98). 이전 90 → 개수 8, 내 순위 5. 결과 = 0.5 + (1−0.5)·(5/8) = **0.8125s**.
- **p99**: rank = 99. 누적 ≥99인 첫 버킷 = `le=+Inf`. 최상위이므로 보간 불가 → 두 번째로 큰 유한 le인 **1s**로 clamp. 실제 p99가 3s여도 대시보드엔 1s로 찍힌다.

p99가 `+Inf` 버킷에 걸리는 순간 숫자가 마지막 유한 경계에 붙어버리는 것 — 이게 "버킷 경계를 SLO 주변에 촘촘히 깔아라"는 조언의 실제 이유다. 반대로 p90처럼 순위가 버킷 경계와 정확히 맞아떨어지면(`rank/count`가 1) 보간 없이 상한을 그대로 돌려주는데, 이는 경계값이 실제 관측 밀도와 우연히 겹쳐 나온 결과일 뿐 "정확히 그 값"이라는 뜻은 아니다.

## 잘못 알고 있던 것

- **"histogram_quantile은 실제 관측값의 정확한 분위수다."** 아니다. 원본 관측값은 저장되지 않는다. 남는 건 경계별 카운트뿐이고, 결과는 버킷 내부 균등분포 가정 아래의 **선형 보간 근사**다. 버킷이 넓거나 분포가 한쪽으로 쏠릴수록 오차가 커지고, 목표 순위가 최상위 `+Inf` 버킷에 들어가면 마지막 유한 `le`값으로 clamp되어 "그 이상은 못 본다".
- **"인스턴스별 p99를 평균 내면 전체 p99다."** 분위수는 평균이 되지 않는다. 여기서 Summary와 Histogram이 갈린다. **Summary**는 클라이언트가 슬라이딩 윈도우로 분위수를 미리 계산해 내보내므로 정확하지만, 이미 계산된 분위수라 **인스턴스 간 집계가 불가능**하다(0.99 quantile들을 더하거나 평균낼 수 없다). **Histogram**은 버킷이 카운터라 `sum by (le)`로 합친 뒤 서버에서 분위수를 계산하므로 **전체 분위수를 집계로 얻을 수 있다** — 다인스턴스 환경에서 히스토그램을 권장하는 근본 이유다.

## 더 파고들 만한 것

- **Native histograms**(Prometheus 2.40+): 고정 `le` 대신 지수적으로 자라는 스파스 버킷을 쓴다. 경계를 미리 못 정해도 되고 해상도가 자동 조정되는데, 그러면 위의 clamp 문제는 어떻게 달라지나.
- 클라이언트가 `observe`에서 버킷을 고를 때의 자료구조(정렬된 경계 배열 + 이진 탐색)와, 고카디널리티 라벨이 붙은 히스토그램이 시계열 수를 어떻게 폭증시키나 → [메트릭 카디널리티](./metric-cardinality-explosion-and-prevention.md)와 연결.

## 참고

- Prometheus Docs — Metric types(Histogram), Best practices(Histograms and summaries)
- `prometheus/prometheus` `promql/quantile.go` — `bucketQuantile`
- Prometheus Docs — Native histograms
