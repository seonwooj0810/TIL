# Kubernetes HPA의 desiredReplicas 계산 알고리즘과 안정화 윈도우

> **Primary source:** Kubernetes 공식 docs — Horizontal Pod Autoscaling (tasks/run-application/horizontal-pod-autoscale)
> **Secondary:** KEP-853 (configurable-hpa-scale-velocity)
> **Date:** 2026-06-22
> **Status:** draft

## 왜 봤나

- "HPA가 CPU 보고 알아서 늘려준다" 수준으로만 알고 있었는데, 실제로는 **무엇을** 기준으로 **얼마나** 늘릴지가 하나의 결정적 공식과 여러 보정 장치로 정해진다는 걸 코드/스펙으로 확인하고 싶었다.
- "메트릭이 임계치를 넘으면 1개씩 늘어난다"고 막연히 알고 있었는데 이건 틀렸다 — HPA는 증분이 아니라 **목표 비율로 한 번에 원하는 개수를 계산**한다.

## 핵심 한 문장

> HPA는 기본 15초 주기로 `desiredReplicas = ceil(currentReplicas × (currentMetric / desiredMetric))`를 계산하고, tolerance·not-ready 보정·안정화 윈도우로 진동(flapping)을 억제한 뒤 워크로드의 replica 수를 그 값으로 덮어쓴다.

## 내부 동작

### 1. 제어 루프 — 연속이 아니라 폴링

HPA는 이벤트 기반 연속 감시가 아니다. `kube-controller-manager`의 HPA 컨트롤러가 `--horizontal-pod-autoscaler-sync-period`(기본 **15초**)마다 한 번씩 깨어나 모든 HPA 리소스를 평가한다. 한 사이클은:

```
[15s tick] → 메트릭 조회(metrics.k8s.io / custom.metrics.k8s.io)
           → 파드별 메트릭 집계 → desiredReplicas 계산
           → tolerance 체크 → 안정화 윈도우 적용 → behavior 정책 클램프
           → scale 서브리소스에 replicas 기록
```

### 2. 핵심 공식

공식 문서에 따르면 기본 계산은 다음과 같다:

```
desiredReplicas = ceil[ currentReplicas × (currentMetricValue / desiredMetricValue) ]
```

- `currentMetricValue`는 보통 **Ready 상태 파드들의 메트릭 평균**(예: 평균 CPU 사용량 `200m`).
- 비율 예시: 현재 평균 `200m`, 목표 `100m` → 비율 2.0 → replica 2배. 현재 `50m`이면 비율 0.5 → 절반.
- 즉 HPA는 "1씩 증감"이 아니라 **목표 사용률로 수렴시키는 비례 제어기**다. 한 번에 절반으로 줄거나 2배로 늘 수 있다(behavior 정책이 막지 않는 한).

### 3. tolerance — 작은 흔들림 무시

비율이 1.0에 충분히 가까우면 스케일링을 **건너뛴다**. 기본 tolerance는 **0.1(10%)**. 즉 비율이 `0.9 ~ 1.1` 구간이면 아무 동작도 하지 않는다. 메트릭이 목표 근처에서 미세하게 출렁여도 replica가 흔들리지 않게 하는 1차 방어선이다.

### 4. not-ready 파드와 결측 메트릭 — 비대칭 보수성

이 부분이 HPA 동작의 핵심 디테일이다. 아직 Ready가 아니거나 메트릭이 없는 파드를 어떻게 셈할지가 **스케일 방향에 따라 다르게(보수적으로)** 처리된다:

| 상황 | 스케일 **업** 판단 시 | 스케일 **다운** 판단 시 |
| --- | --- | --- |
| 메트릭 결측 파드 | 사용률 **0%**로 가정 | 사용률 **100%**로 가정 |
| 아직 Ready 아닌 파드 | 사용률 **0%**로 가정(계산에서 사실상 제외/억제) | (제외) |

방향이 반대인 이유: 업스케일을 과하게 하면 비용 폭증·과프로비저닝, 다운스케일을 과하게 하면 가용성 붕괴. 그래서 **"업은 작게 잡고, 다운은 크게 잡는다"**. 결측 파드를 업 계산에선 0%(굳이 더 늘릴 근거 약화), 다운 계산에선 100%(함부로 줄이지 못하게)로 둔다.

Ready 판정에도 유예가 있다:
- `--horizontal-pod-autoscaler-initial-readiness-delay` 기본 **30초**
- `--horizontal-pod-autoscaler-cpu-initialization-period` 기본 **5분** (파드의 첫 Ready 전환 직후 CPU 메트릭이 신뢰 구간에 들기까지)

이 윈도우 안의 파드는 "방금 떠서 아직 워밍업 중"으로 보고 메트릭을 액면 그대로 믿지 않는다. 새 파드의 콜드스타트 CPU 스파이크가 곧바로 추가 업스케일을 유발하는 폭주를 막는다.

### 5. 다중 메트릭 — 최댓값 채택

`metrics:`에 여러 항목(CPU + 메모리 + custom)을 두면, 각 메트릭으로 독립적으로 desiredReplicas를 구한 뒤 **그중 가장 큰 값**을 최종 후보로 쓴다. 어느 한 자원이라도 부족하면 늘리겠다는 보수적 합집합.

### 6. 안정화 윈도우(stabilization window) — flapping 방지

tolerance가 1차 방어선이라면, 안정화 윈도우는 시간축 방어선이다. 계산된 추천값을 바로 적용하지 않고 **과거 일정 구간의 추천값들을 모아 그중 하나를 고른다**:

- **scaleDown 기본 300초(5분)**: 지난 5분간의 추천값 중 **가장 큰 값**을 골라 다운스케일한다 → 잠깐 트래픽이 꺼져도 5분 안에 한 번이라도 높았으면 줄이지 않음. 급격한 축소·재확장 사이클 방지.
- **scaleUp 기본 0초**: 윈도우가 0이므로 업스케일 추천은 **즉시** 반영(지연 없이 빠르게 대응).

방향별 선택 규칙: 다운은 윈도우 내 **max** 추천, 업은 윈도우 내 **min** 추천을 쓴다 → 양쪽 모두 "성급한 변화"를 누른다.

### 7. behavior 정책 — 변화 속도 클램프 (KEP-853)

`behavior.scaleUp` / `behavior.scaleDown`에 정책을 둬서 **한 주기당 변화 폭**을 제한한다. 기본값:

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    selectPolicy: Max          # 여러 정책 중 가장 큰 변화 허용
    policies:
    - type: Percent
      value: 100               # 15초마다 최대 100% 증가(2배)
      periodSeconds: 15
    - type: Pods
      value: 4                 # 또는 15초마다 최대 +4 파드
      periodSeconds: 15
  scaleDown:
    stabilizationWindowSeconds: 300
    selectPolicy: Max
    policies:
    - type: Percent
      value: 100               # 15초마다 최대 100% 감소
      periodSeconds: 15
```

`selectPolicy: Max`는 "여러 정책이 허용하는 변화량 중 가장 큰 것"을 택한다(업에서 Percent와 Pods 중 더 큰 쪽). `Disabled`로 두면 해당 방향 스케일링을 완전히 끈다.

### 상태 흐름 요약

```
        ┌────────────── 15s sync tick ──────────────┐
        ▼                                            │
  메트릭 집계 → ratio = cur/target                    │
        │                                            │
   |ratio-1| ≤ 0.1 ? ──yes──► no-op ─────────────────┤
        │ no                                         │
        ▼                                            │
  desired = ceil(replicas × ratio)                   │
  (not-ready/결측 보정: 업=0%, 다운=100%)              │
        ▼                                            │
  안정화 윈도우(업 min / 다운 max) → behavior 클램프     │
        ▼                                            │
  scale 서브리소스.replicas = desired ────────────────┘
```

## 검증

공식 docs의 알고리즘 절을 따라가며 손계산으로 확인:

```
# 시나리오: replicas=3, 목표 CPU=50%, Ready 파드 평균=90%
ratio = 90/50 = 1.8           # |1.8-1| = 0.8 > 0.1 → 스케일 대상
desired = ceil(3 × 1.8) = ceil(5.4) = 6   # 3 → 6 (한 번에 2배)
# behavior scaleUp Percent 100%/15s 이면 3→6은 +100% 이내라 그대로 허용

# 시나리오: 같은 디플로이, 평균=20%로 급락
ratio = 20/50 = 0.4
desired = ceil(3 × 0.4) = ceil(1.2) = 2   # 3 → 2 가 "추천"
# 하지만 scaleDown 안정화 300s: 지난 5분 추천 중 max(=직전 6 등)를 채택 → 즉시 줄지 않음
```

손계산이 docs의 예시(`200m/100m → 2배`, tolerance 0.1)와 일치함을 확인했다. 실제 클러스터라면 `kubectl describe hpa <name>`의 이벤트에서 `New size: N; reason: cpu resource utilization (percentage of request) above target`로 같은 계산 결과를 관찰할 수 있다.

## 잘못 알고 있던 것

- **(오해) HPA는 메트릭을 실시간 연속 감시한다.** → 실제로는 기본 **15초 폴링** 루프다. 스파이크가 15초 안에 끝나면 HPA는 못 볼 수도 있다. 그래서 짧고 날카로운 버스트는 HPA로 흡수가 안 되고, 그게 KEDA·VPA·request 기반 오버프로비저닝이 필요한 이유다.
- **(오해) 임계치를 넘으면 파드가 1개씩 증가한다.** → HPA는 증분 제어가 아니라 **목표 비율 비례 제어**다. 한 번에 절반으로 줄거나 2배로 뛸 수 있고, 그 폭을 막는 건 behavior 정책뿐이다.
- **(오해) 업/다운이 대칭이다.** → 비대칭이 설계의 핵심이다. 결측·미준비 파드 가정(업 0% / 다운 100%), 안정화 윈도우(업 0초 / 다운 300초), 윈도우 내 선택(업 min / 다운 max) 모두 **"빠르게 늘리고 천천히 줄인다"**는 한 방향으로 정렬돼 있다.

## 더 파고들 만한 것

- VPA(Vertical Pod Autoscaler)의 recommender가 메트릭 히스토리(decaying histogram)로 request를 추정하는 방식 — HPA와 동시 사용 시 충돌 지점.
- custom.metrics.k8s.io / external.metrics.k8s.io adapter(Prometheus Adapter, KEDA)가 HPA에 메트릭을 공급하는 파이프라인.

## 참고

- [Horizontal Pod Autoscaling | Kubernetes](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [KEP-853: configurable HPA scale velocity](https://github.com/kubernetes/enhancements/blob/master/keps/sig-autoscaling/853-configurable-hpa-scale-velocity/README.md)
