# 메트릭 카디널리티 폭발과 방지

> **Primary source:** Prometheus docs - Instrumentation, Metric and label naming, Storage
> **Secondary:** Prometheus docs - Histograms and summaries, promtool
> **Date:** 2026-06-16
> **Status:** draft

## 왜 봤나

- "라벨을 많이 붙이면 나중에 분석하기 좋다" 정도로 생각했는데, Prometheus에서는 라벨 조합 하나가 곧 별도 time series라서 저장소, 쿼리, 알림 비용을 함께 키운다.

## 핵심 한 문장

> Prometheus 메트릭 카디널리티 폭발은 라벨 값의 가능한 조합 수가 통제되지 않아 active series 수가 곱셈으로 늘어나는 현상이며, 방지는 라벨 설계 시점의 bounded dimension 선택과 수집 후 cardinality 점검에서 시작된다.

## 내부 동작

Prometheus 공식 문서에 따르면 모든 고유한 label set은 하나의 time series를 만든다. 여기서 label set은 metric name까지 포함해 생각하는 편이 실무적으로 안전하다. 예를 들어 같은 `http_requests_total`이라도 `method="GET", route="/orders/{id}", status="200"`과 `method="POST", route="/orders", status="201"`은 서로 다른 series다. 값이 counter 하나로 보이더라도 내부 저장소와 쿼리 엔진은 label set별로 샘플 흐름을 나누어 다룬다.

카디널리티는 더하기보다 곱셈 문제에 가깝다.

```text
series_count(metric)
  ~= count(distinct method)
   * count(distinct route)
   * count(distinct status)
   * count(distinct instance)
   * ...
```

각 차원이 완전히 독립적으로 곱해진다고 단정할 수는 없다. 실제로는 특정 route에는 특정 status만 나오고, 특정 instance는 일부 route만 처리할 수 있다. 그래도 설계 리뷰에서는 곱셈 상한으로 먼저 보는 편이 좋다. `method=5`, `route=80`, `status=12`, `instance=40`이면 이 metric family 하나만으로 최대 192,000개 조합이 된다. 여기에 `user_id`처럼 unbounded dimension을 붙이면 상한 계산 자체가 무너진다.

Prometheus instrumentation best practices는 라벨을 과용하지 말라고 한다. 문서의 가이드라인은 metric cardinality를 10 미만으로 유지하려고 하고, 100을 넘거나 그 정도로 커질 가능성이 있으면 차원을 줄이거나 범용 처리 시스템으로 옮기는 대안을 검토하라는 쪽에 가깝다.

내부 자료구조 관점에서 보면 cardinality 폭발은 head block의 series map과 label index가 커지는 문제다. Prometheus storage 문서는 로컬 TSDB가 수집 샘플을 2시간 block으로 묶고, block은 chunks, metadata, index를 포함한다고 설명한다. 현재 들어오는 샘플은 memory의 head에 유지되고, crash recovery를 위해 WAL에 기록된다. 따라서 새 label set이 생긴다는 것은 대략 다음 상태 전이를 만든다고 볼 수 있다.

```text
scrape sample
  |
  v
metric name + sorted labels
  |
  v
series exists? ---- no ----> create series reference
  |                         update label postings/index state
 yes                        append WAL series record
  |                         allocate head chunk state
  v
append sample
  |
  v
WAL sample record + head chunk
```

공식 문서가 모든 내부 map 이름을 이 방식으로 설명하는 것은 아니지만, storage layout을 따라가면 비용의 방향은 분명하다. active series가 늘면 메모리에는 series 메타데이터와 head chunk 상태가 더 오래 남고, WAL에는 새 series와 sample 기록이 늘고, block index에는 label name/value에서 series로 가는 posting 정보가 커진다.

라벨 하나가 위험해지는 이유는 값 자체의 크기보다 값의 공간이 열려 있기 때문이다.

```text
좋은 후보: method, status_code, normalized_route, region
위험 후보: user_id, email, session_id, order_id, raw_path, error_message
```

`status_code`는 HTTP 상태 코드라는 닫힌 집합 안에 있다. `route`도 `/orders/{id}`처럼 정규화된 template이면 bounded dimension에 가깝다. 반면 `/orders/123456` 같은 raw path는 요청 수에 비례해 label value가 증가한다. `error_message`에 id, timestamp, SQL literal이 섞이면 사실상 매번 새 label value가 된다.

히스토그램은 특히 조심해야 한다. Prometheus classic histogram은 bucket별 series를 만든다. 공식 histogram 문서에 따르면 `le` 라벨은 bucket의 upper inclusive boundary를 나타낸다. 즉 `http_request_duration_seconds_bucket{le="0.3"}` 같은 series가 bucket마다 생기고, 여기에 `_count`, `_sum`도 붙는다. 단순화하면 classic histogram 하나의 series 수는 다음처럼 늘어난다.

```text
histogram_series
  ~= label_combinations * (bucket_count + _sum + _count)
```

bucket이 12개이고 route/method/status/instance 조합이 10,000개라면 histogram family 하나가 대략 140,000개 series를 만들 수 있다. latency를 보고 싶어서 histogram을 붙였을 뿐인데, `route`에 raw path를 넣으면 bucket 수까지 곱해져 폭발 속도가 더 빨라진다. 그래서 histogram에는 SLO 판단에 필요한 차원만 남기고, per-user latency 분석 같은 요구는 trace, log, analytical store 쪽으로 분리하는 편이 낫다.

방지 알고리즘은 "수집 전에 줄이고, 수집 후에 감시한다"로 나눌 수 있다.

```text
metric design review:
  1. 이 라벨 값 집합이 닫혀 있는가?
  2. 최대 조합 수를 손으로 계산할 수 있는가?
  3. 집계 시 이 라벨을 실제로 사용할 PromQL이 있는가?
  4. 장애 대응에 필요한 차원인가, 사후 분석용 차원인가?
  5. histogram이면 bucket 수까지 곱했는가?

runtime review:
  1. series 수가 어떤 metric name에서 늘었는가?
  2. 어떤 label name/value가 증가를 주도하는가?
  3. recording rule이나 dashboard가 고카디널리티 label을 보존하는가?
  4. alert query가 필요 없는 label을 aggregate away 하는가?
```

첫 번째 질문에서 "아니오"가 나오면 라벨 후보에서 빼는 것이 기본값이다. 필요한 경우에는 원값을 label로 넣지 않고 정규화한다. HTTP endpoint는 framework route template을 쓰고, tenant는 전체 고객 id 대신 plan, shard, region처럼 운영 의사결정에 직접 쓰이는 bounded 차원으로 낮춘다.

PromQL에서도 cardinality를 줄이는 습관이 필요하다. 예를 들어 error rate 알림은 보통 user 단위가 아니라 service, route, status class 정도면 충분하다.

```promql
sum by (service, route) (
  rate(http_requests_total{status=~"5.."}[5m])
)
/
sum by (service, route) (
  rate(http_requests_total[5m])
)
```

반대로 `sum without(instance)`만 하고 `path`, `user_id`, `exception` 같은 라벨을 그대로 남기면 결과 벡터도 커진다. 쿼리 결과가 커지면 evaluation memory와 dashboard rendering 비용도 같이 늘어난다. 따라서 "저장할 때만 문제"가 아니라 "읽을 때도 문제"다. Recording rule은 비용을 줄일 수 있지만, 고카디널리티 라벨을 그대로 보존한 recording rule은 비싼 series를 하나 더 복제하는 효과를 낼 수 있다.

카디널리티 방지는 정보 손실과 운영 가능성 사이의 선택이다. metric은 전체 시스템의 증상과 추세를 빠르게 보기 위한 신호다. 개별 요청, 사용자, 주문의 원인 분석은 trace span attribute나 log field로 넘기는 편이 대체로 맞다.

정리하면 Prometheus에서 라벨은 SQL 컬럼처럼 마음껏 늘리는 속성이 아니다. label set은 TSDB의 series key이고, series key가 늘면 메모리의 head state, WAL, block index, 쿼리 결과 벡터가 함께 커진다. 좋은 메트릭 설계는 "나중에 쓸지도 모르는 모든 차원"을 담는 것이 아니라 "운영 판단에 필요한 bounded 차원"만 담고, 나머지는 trace/log/분석계로 보내는 것이다.

## 검증

이번 노트는 코드 실험 대신 Prometheus 공식 문서의 흐름을 따라 검증했다.

```text
1. Metric and label naming 문서는 label key-value 조합 하나가 새 time series를 만든다고 설명한다.
2. Instrumentation best practices는 labelset마다 RAM, CPU, disk, network 비용이 생긴다고 설명한다.
3. 같은 문서는 cardinality가 100을 넘거나 그 가능성이 있으면 차원 축소나 다른 처리 시스템을 검토하라고 안내한다.
4. Storage 문서는 샘플이 2시간 block, index, chunks, WAL/head 구조로 저장된다고 설명한다.
5. Histograms 문서는 classic histogram bucket이 `le` 라벨을 가진 누적 bucket series로 표현된다고 설명한다.
```

작은 계산으로도 폭발이 보인다.

```text
http_request_duration_seconds
  method: 5
  route: 100
  status: 12
  instance: 30
  buckets: 10 + count + sum = 12

5 * 100 * 12 * 30 * 12 = 2,160,000 series
```

여기서 route가 template이 아니라 raw path이면 `route=100`이라는 가정이 깨진다. 요청 수가 많을수록 새 path value가 계속 생기고, histogram bucket 수까지 곱해져 같은 트래픽에서도 series 증가율이 더 커진다.

## 잘못 알고 있던 것

- 라벨은 "나중에 group by 할 수 있는 메타데이터"라고만 생각했다. Prometheus에서는 라벨 조합이 곧 저장 단위인 series key라서 비용이 즉시 발생한다.
- histogram은 latency 관측을 위한 하나의 metric이라고 생각하기 쉽다. classic histogram은 bucket마다 별도 series를 만들기 때문에 라벨 조합 수와 bucket 수가 함께 곱해진다.
- high cardinality를 디스크 용량 문제로만 봤다. 실제로는 active series의 head memory, WAL, index, query vector 크기까지 같이 보는 문제다.

## 더 파고들 만한 것

- Prometheus TSDB head block과 postings index의 실제 Go 구현에서 series 생성 경로 확인하기.
- OpenTelemetry metric view나 collector processor로 고카디널리티 attribute를 제거하는 방법.

## 참고

- Prometheus docs - Instrumentation: https://prometheus.io/docs/practices/instrumentation/
- Prometheus docs - Metric and label naming: https://prometheus.io/docs/practices/naming/
- Prometheus docs - Storage: https://prometheus.io/docs/prometheus/latest/storage/
- Prometheus docs - Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus docs - promtool: https://prometheus.io/docs/prometheus/latest/command-line/promtool/

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
