# Prometheus rate()/increase()는 왜 정수 카운터에서 소수를 돌려주나 — extrapolatedRate의 경계 외삽 알고리즘

> **Primary source:** Prometheus 소스 `promql/functions.go`의 `extrapolatedRate` (commit `e71425d`, L452–633), `docs/querying/functions.md`의 `rate()`/`increase()` 절
> **Secondary:** `docs/querying/basics.md`의 range vector selector 설명 (left-open/right-closed 구간)
> **Date:** 2026-09-28
> **Status:** draft

## 왜 봤나

- `increase(http_requests_total[5m])`가 `37.5` 같은 소수를 돌려주거나, 요청이 딱 3번 들어왔는데 `4.2`가 나오는 걸 보고 "버그인가?" 싶어지는 경우가 흔하다. 원인은 버그가 아니라 **윈도우 경계까지의 외삽(extrapolation)** 이다.
- `rate()`를 "(마지막 값 − 첫 값) / 윈도우 길이"로 이해하면 이 동작을 설명할 수 없다. 실제로는 **샘플이 덮은 구간**과 **윈도우 경계까지의 빈틈**을 따로 계산해서, 빈틈을 채울지·반만 채울지·0점에서 멈출지를 고른다.

## 핵심 한 문장

> `rate`/`increase`는 윈도우 안 첫·마지막 샘플 사이의 증가량(리셋 보정 포함)을 구한 뒤, 경계까지의 빈틈이 평균 샘플 간격의 1.1배보다 작으면 경계까지, 크면 평균 간격의 절반만큼만 선형 외삽하고, 카운터는 0 아래로는 외삽하지 않는다.

## 내부 동작

`funcRate`와 `funcIncrease`는 같은 함수 `extrapolatedRate(vals, args, enh, isCounter=true, isRate)`를 부른다. 차이는 `isRate` 하나 — 마지막에 윈도우 초로 나누느냐뿐이다. 그래서 문서도 `increase`를 "`rate(v)`에 윈도우 초를 곱한 syntactic sugar"라고 설명한다.

### 1) 구간과 샘플

- `rangeStart = Ts − (range + offset)`, `rangeEnd = Ts − offset`.
- range selector는 **left-open, right-closed** (`(rangeStart, rangeEnd]`) — 왼쪽 경계와 정확히 같은 타임스탬프의 샘플은 빠진다 (basics.md).
- 샘플이 1개뿐이면(`numSamplesMinusOne == 0`) 결과 없음. 간격을 추정할 수 없기 때문이다.

### 2) 원시 증가량 + 카운터 리셋 보정

```
resultFloat = last.F − first.F
for 연속 샘플 (prev, curr):
    if curr.F < prev.F:        // 값이 줄었다 = 리셋
        resultFloat += prev.F  // 리셋 직전 값만큼 되돌려 더함
```

값 `100, 110, 5, 15`이면 `15−100 = −85`, 리셋에서 `+110` → `25` (= 10 + 5 + 10). 리셋 뒤 0부터 다시 셌다고 가정하는 것이다.

### 3) 경계까지의 빈틈과 임계값

```
durationToStart = (firstT − rangeStart)초
durationToEnd   = (rangeEnd − lastT)초
sampledInterval = (lastT − firstT)초
avg             = sampledInterval / (샘플수 − 1)
threshold       = avg × 1.1
```

소스 주석의 논리: 샘플 간격이 대체로 일정하다고 가정하면, 빈틈이 `avg×1.1` 이상이라는 건 "있어야 할 자리에 샘플이 없다" = 시계열이 윈도우 **안에서** 시작/끝났다는 뜻이다. 그래서

| 조건 | 외삽 거리 |
|---|---|
| 빈틈 < threshold | 빈틈 전체 (경계까지) |
| 빈틈 ≥ threshold | `avg / 2` (시리즈의 실제 시작·끝 추정 지점) |

### 4) 카운터의 0점 클램프 (왼쪽만)

카운터는 음수가 될 수 없으므로 기울기로 0이 되는 지점을 역산한다.

```
durationToZero = sampledInterval × (first.F / resultFloat)
durationToStart = min(durationToStart, durationToZero)
```

이 클램프는 **왼쪽(시작) 쪽에만** 적용된다. 오른쪽은 3)의 규칙만 따른다.

### 5) 최종 배율

```
factor = (sampledInterval + durationToStart + durationToEnd) / sampledInterval
if isRate: factor /= range초
result = resultFloat × factor
```

### 상태 흐름

```
 samples in (start, end]
        │ 1개 이하 → 결과 없음
        ▼
 raw = last − first (+ 리셋마다 prev 가산)
        ▼
 ┌─ 왼쪽 빈틈 ≥ 1.1·avg ? ── yes → avg/2
 │                         no  → 빈틈 그대로
 └─ counter면 min(·, durationToZero)
 ┌─ 오른쪽 빈틈 ≥ 1.1·avg ? ─ yes → avg/2
 │                          no → 빈틈 그대로
        ▼
 raw × (covered + left + right) / covered  [÷ range if rate]
```

### 계산 예 (range = 1m, scrape 15s, rangeStart를 t=0으로)

**A. 정상 시리즈** — 샘플 t=5,20,35,50 / 값 100,110,120,130
raw=30, covered=45, avg=15, threshold=16.5. 왼쪽 5·오른쪽 10 모두 < 16.5 → 전부 외삽.
durationToZero=45×100/30=150 > 5 → 클램프 없음.
factor=60/45 → `increase`=**40**, `rate`=40/60≈0.667. 증가분이 정수 10씩이어도, 값이 100,101,103,104였다면 4×4/3≈**5.33**이 된다 — 소수 결과의 정체.

**B. 윈도우 중간에 태어난 시리즈** — 샘플 t=35,50 / 값 2,5
raw=3, avg=15. 왼쪽 빈틈 35 ≥ 16.5 → 7.5로 축소. durationToZero=15×2/3=10 > 7.5 → 7.5 유지. 오른쪽 10 → 그대로.
factor=(15+7.5+10)/15≈2.167 → `increase`≈**6.5**.

**C. 0점 클램프** — 같은 조건, 값 1,5
raw=4, durationToZero=15×1/4=3.75 < 7.5 → 3.75.
factor=(15+3.75+10)/15≈1.917 → `increase`≈**7.67** (= t=31.25의 0에서 출발해 t=60까지 기울기 4/15로 선형 연장한 값).

### 참고: 최신 main의 분기

확인한 커밋에서는 selector에 `anchored`/`smoothed` 수정자가 붙으면 이 함수가 아니라 `extendedRate`로 넘어가고, 시리즈의 start timestamp(ST)가 윈도우 안에 있으면 왼쪽 외삽 대신 "ST 시점에 값 0"을 가정하는 분기도 있다. 이 노트는 수정자 없는 기본 경로만 다룬다.

## 검증

`promtool test rules`로 외삽을 직접 재현할 수 있다 (Prometheus 서버 불필요).

```yaml
# rate_test.yml — 실행: promtool test rules rate_test.yml
rule_files: []
evaluation_interval: 15s
tests:
  - interval: 15s
    input_series:
      - series: 'c_total'
        values: '100+10x10'     # t=0,15,...,150 에 100,110,...,200
    promql_expr_test:
      - expr: increase(c_total[1m])
        eval_time: 1m
        exp_samples:
          - labels: '{}'
            value: 40
```

- eval_time=1m이면 구간은 (0s, 60s] → t=0 샘플은 **제외**되고 t=15..60의 110..140만 남는다. raw=30, 왼쪽 빈틈 15 < 16.5 → factor=60/45 → 40.
- `expr`을 `c_total - c_total offset 1m`으로 바꿔도 40 — 이 경우는 외삽이 "우연히" 정확한 경우다. `values`를 `'100 101 103 104 106'`처럼 불규칙하게 바꾸면 두 식이 갈라지는 걸 볼 수 있다. 부동소수 오차로 실패하면 promtool이 실제 값(got)을 출력하니 그걸로 확인한다.
- 윈도우를 `[15s]`로 줄이면 샘플이 1개뿐이라 결과가 비는 것도 같은 파일로 확인된다.

## 잘못 알고 있던 것

- **"`increase()`는 `마지막 − 처음`이다"** → 아니다. 샘플이 덮은 구간(covered)을 윈도우 전체로 늘리는 배율 `(covered+left+right)/covered`가 곱해진다. 그래서 정수 카운터에서도 소수가 나오고, 짧은 윈도우일수록 배율이 커져 오차도 커진다.
- **"시리즈가 윈도우 중간에 생겨도 경계까지 쭉 외삽된다"** → 빈틈이 평균 간격의 1.1배 이상이면 `avg/2`만 외삽하고, 카운터는 0점 아래로 내려가지 않게 클램프된다. 새 파드의 첫 5분 `increase`가 과대 추정되지 않는 이유다.
- (덤) **`sum` 먼저, `rate` 나중** → 문서가 명시적으로 금지한다. 합친 시리즈에서는 한 타깃의 재시작이 "감소"로 안 보여 리셋 보정이 깨진다. 항상 `sum(rate(x[5m]))`.

## 더 파고들 만한 것

- `anchored`/`smoothed` 수정자와 `extendedRate`: 외삽 대신 경계 보간을 쓰는 방식이 어떤 오차를 줄이는지.
- native histogram의 `histogramRate`: 버킷 단위 리셋 감지(`DetectReset`)와 스키마 불일치 처리.

## 참고

- Prometheus `docs/querying/functions.md` — `rate()`, `increase()`, `resets()`
- Prometheus `docs/querying/basics.md` — range vector selector의 구간 정의
- Prometheus `promql/functions.go` — `extrapolatedRate`, `funcRate`, `funcIncrease`
