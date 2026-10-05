# Kubernetes QoS 클래스는 퇴출 순서를 직접 정하지 않는다 — kubelet의 3단 정렬과 커널 oom_score_adj 공식이 같은 "usage − request"로 수렴하는 이유

> **Primary source:** Kubernetes 공식 docs "Node-pressure Eviction"(Pod selection for kubelet eviction / Node out of memory behavior), "Pod Quality of Service Classes" · kubernetes 소스 `pkg/kubelet/qos/policy.go`(`GetContainerOOMScoreAdjust`), `pkg/kubelet/eviction/helpers.go`(`rankMemoryPressure`, `exceedMemoryRequests`, `priority`, `memory`) · Linux 소스 `mm/oom_kill.c`(`oom_badness`), `fs/proc/base.c`(`proc_oom_score`)
> **Secondary:** LWN "Another OOM killer rewrite"(docs가 링크하는 oom_score 배경 글), cgroup v2 admin guide의 `memory.oom.group`
> **Date:** 2026-10-05
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/kubernetes-qos-oom-eviction-order

## 왜 봤나

- "메모리가 모자라면 BestEffort → Burstable → Guaranteed 순으로 죽는다"는 설명이 흔하다. 그런데 노드에서 파드를 없애는 주체는 **둘**이다: 사용자 공간의 kubelet(eviction)과 커널의 OOM killer. 둘은 서로 다른 입력으로 서로 다른 시점에 동작한다.
- 공식 문서는 명시적으로 "kubelet은 eviction 순서를 정할 때 QoS 클래스를 쓰지 않는다"고 적는다. 그렇다면 QoS 순서라는 직관은 어디서 오는가? 두 경로를 따라가 보면 둘 다 결국 **"request 대비 얼마나 더 쓰는가"** 라는 한 축으로 수렴하고, QoS 클래스는 그 결과를 근사하는 라벨일 뿐이라는 게 보인다.

## 핵심 한 문장

> kubelet은 (request 초과 여부 → Priority → usage−request) 3단 비교로 파드를 정렬해 퇴출하고, 그보다 먼저 커널 OOM이 터지면 kubelet이 QoS별로 심어둔 `oom_score_adj`(Burstable은 `1000 − 1000·request/capacity`)가 `rss+swap+pagetable`에 더해져 사실상 "request 대비 초과 사용량"이 가장 큰 컨테이너가 죽는다.

## 내부 동작

### 1) 두 개의 방어선

```
 메모리 사용량 ↑
 ──────────────────────────────────────────────────────────────▶
   │                          │                         │
   │ memory.available         │ kubelet housekeeping     │ 커널 할당 실패
   │ < eviction threshold     │ (기본 10s 주기 폴링)       │ (노드 전역 or memcg)
   ▼                          ▼                         ▼
 [kubelet eviction]  ── 정렬 후 파드 단위 종료 ──   [OOM killer]
  - 파드 phase=Failed                                - 프로세스(또는 cgroup 그룹) 단위 SIGKILL
  - PDB 무시, hard면 grace 0s                         - restartPolicy에 따라 재시작 가능
```

- 문서에 따르면 kubelet은 `housekeeping-interval`(기본 10s)마다 임계값을 평가한다. 메모리가 그 사이에 급격히 오르면 kubelet이 MemoryPressure를 보기 전에 커널 OOM killer가 먼저 호출될 수 있다(문서의 Known issues). 그래서 두 경로를 모두 이해해야 한다.
### 2) kubelet eviction: QoS가 아니라 3단 비교자

`helpers.go`의 메모리 압박 정렬은 한 줄이다:

```go
func rankMemoryPressure(pods []*v1.Pod, stats statsFunc) {
	orderedBy(exceedMemoryRequests(stats), priority, memory(stats)).Sort(pods)
}
```

| 단계 | 비교자 | 의미 |
| --- | --- | --- |
| 1 | `exceedMemoryRequests` | usage > request 인 파드가 앞(먼저 퇴출). 통계가 없는 파드는 가장 앞 |
| 2 | `priority` | PriorityClass 값이 낮은 파드가 앞 |
| 3 | `memory` | `usage − request`가 큰 파드가 앞 |

- BestEffort는 request가 0이므로 1단계에서 **무조건** "초과" 그룹에 들어간다. Guaranteed는 limit=request라서 cgroup 상한 때문에 request를 넘을 수 없어 항상 "미초과" 그룹이다. **QoS 순서는 이 1단계의 부산물**이다.
- 그러나 Burstable이 request 이하로 쓰고, 높은 Priority의 BestEffort가 있으면? BestEffort는 초과 그룹이라 여전히 먼저다. 반대로 같은 초과 그룹 안에서는 **Priority가 QoS보다 앞선다** — 낮은 Priority의 Burstable 초과 파드가 높은 Priority의 BestEffort보다 먼저 퇴출된다.

### 3) 커널 OOM: kubelet이 심어두는 oom_score_adj

`policy.go`의 상수와 분기(이번에 소스로 확인):

```go
KubeletOOMScoreAdj    int = -999
KubeProxyOOMScoreAdj  int = -999
guaranteedOOMScoreAdj int = -997
besteffortOOMScoreAdj int = 1000
...
if types.IsNodeCriticalPod(pod) { return guaranteedOOMScoreAdj }
switch v1qos.GetPodQOS(pod) { Guaranteed: -997, BestEffort: 1000 }
oomScoreAdjust = 1000 - (1000*containerMemReq)/memoryCapacity     // Burstable
if oomScoreAdjust < 1000 + guaranteedOOMScoreAdj { return 3 }     // 하한 클램프
if oomScoreAdjust == besteffortOOMScoreAdj      { return 999 }   // BestEffort보다 1 낮게
```

- 사이드카(재시작 정책 Always인 init 컨테이너)는 일반 컨테이너 중 **최소 request** 기준 adj 이하로 맞춘다.

커널 쪽 `oom_badness()`:

```c
points = get_mm_rss_sum(mm) + get_mm_counter_sum(mm, MM_SWAPENTS)
       + mm_pgtables_bytes(mm) / PAGE_SIZE;   // 단위: 페이지
adj *= totalpages / 1000;                      // adj를 "1/1000 메모리" 단위로 환산
points += adj;
```

- `adj == OOM_SCORE_ADJ_MIN(-1000)`이면 후보에서 제외(LONG_MIN). 선택은 `points < chosen_points`면 건너뛰는 최대값 탐색이고 초기값이 LONG_MIN이라, **음수 점수도 유일한 후보면 죽는다**. -997은 "면제"가 아니라 "거의 마지막"이다.
- 노드 전역 OOM에서 `totalpages = totalram + total_swap`, memcg(컨테이너 limit) OOM에서는 `totalpages = memcg max`다.

### 4) 왜 "usage − request"로 수렴하나 (스왑 없음, capacity ≈ totalpages 가정)

Burstable 컨테이너에 대해 T = 전체 페이지, U = 사용 페이지, R = request 페이지라 하면

```
adj    ≈ 1000 − 1000·R/T
points = U + adj·T/1000 = U + T − R = T + (U − R)
```

- 모든 Burstable 컨테이너에 T가 공통으로 더해지므로 **순위는 U − R로만 결정**된다. kubelet의 3단계 `memory` 비교자와 같은 축이다. 소스 주석도 "10% request 컨테이너는 adj 900, 10%를 넘게 쓰면 점수 1000"이라는 같은 직관을 적어 둔다.
- BestEffort는 `U + T`(R=0과 같음, adj 1000 vs Burstable 상한 999), Guaranteed는 `U − 0.997T`로 사실상 바닥이다.
- 문서 스스로 "컨테이너 안에 작은 프로세스가 많으면 동작하지 않는 휴리스틱"이라고 경고한다 — `oom_badness`는 **프로세스(mm) 단위**로 점수를 매기기 때문이다.

### 5) 그 다음: 프로세스 하나냐, 컨테이너 전체냐

- cgroup v2 노드에서 kubelet 설정 `singleProcessOOMKill`이 nil이면 kubelet.go가 `false`로 정하고, 이 경우 컨테이너 cgroup에 `memory.oom.group=1`을 넣는다(`kuberuntime_container_linux.go`). 그러면 OOM 피해자가 하나 고르면 **그 컨테이너 cgroup 전체**가 같이 죽는다. cgroup v1은 항상 단일 프로세스 kill이다.

## 검증

(a) 실행 중 클러스터에서 QoS별 adj를 직접 관찰:

```bash
# 노드 메모리 16Gi 가정, request 4Gi / limit 8Gi 인 Burstable 파드
kubectl get pod web -o jsonpath='{.status.qosClass}'          # Burstable
kubectl exec web -- cat /proc/1/oom_score_adj                  # ≈ 1000-1000*4/16 = 750
kubectl exec web -- cat /proc/1/oom_score                      # 0..2000 스케일 값
# Guaranteed 파드 → -997, BestEffort 파드 → 1000
# request를 아주 작게(예: 1Mi) 준 Burstable 컨테이너 → 999 (1000이 되지 않음)
```

- `/proc/<pid>/oom_score`는 `fs/proc/base.c`의 `proc_oom_score`가 `(1000 + badness*1000/totalpages) * 2/3`로 [0, 2000] 범위에 스케일한 값이다. 같은 노드에서 request를 바꿔가며 이 값의 순서가 `usage − request` 순서와 맞는지 보면 4)절이 확인된다.
- cgroup v2 노드에서 `cat /sys/fs/cgroup/<pod 경로>/<container>/memory.oom.group`이 1이면 그룹 kill 모드다.

(b) 소스 포인터(이번 실행에서 열어 확인): `pkg/kubelet/qos/policy.go`의 `GetContainerOOMScoreAdjust`, `pkg/kubelet/eviction/helpers.go`의 `rankMemoryPressure`, `mm/oom_kill.c`의 `oom_badness`와 `chosen_points` 비교.

## 잘못 알고 있던 것

- **"kubelet은 QoS 순으로 퇴출한다"** → 아니다. 문서에 "kubelet does not use the pod's QoS class to determine the eviction order"라고 명시돼 있다. 순서는 request 초과 여부 → Priority → 초과량이고, QoS 순서는 1단계의 결과로 *대개* 맞아떨어질 뿐이다. 같은 초과 그룹에서는 Priority가 이긴다.
- **"Burstable의 oom_score_adj 하한은 2"** → 공식 문서 표는 `min(max(2, ...), 999)`로 적지만, 현재 소스는 `oomScoreAdjust < 1000 + (-997)`이면 **3**을 반환한다. 즉 실제 하한은 3이다(Guaranteed 대비 최소 1000 차이를 두려는 의도). 정확한 값이 필요하면 문서 표가 아니라 `policy.go`를 보자.
- **"Guaranteed(-997)는 OOM에서 안전하다"** → 커널은 -1000만 제외한다. -997은 점수를 크게 깎을 뿐이고 후보가 그것뿐이면 죽는다. 또 자기 limit에 닿는 memcg OOM은 QoS와 무관하게 그 컨테이너 안에서 일어난다.

## 더 파고들 만한 것

- Memory QoS(cgroup v2 `memory.high`/`memory.min`/`memory.low`)가 OOM 이전 단계에서 TieredReservation으로 어떻게 보호선을 긋는지 — `memoryThrottlingFactor` 공식과 함께.
## 참고

- https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/qos/policy.go
- https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/eviction/helpers.go
- https://github.com/torvalds/linux/blob/master/mm/oom_kill.c
- https://lwn.net/Articles/391222/

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
