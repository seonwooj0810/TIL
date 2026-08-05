# Kubernetes Deployment 롤링 업데이트: maxSurge/maxUnavailable 비대칭 라운딩과 proportional scaling 분배

> **Primary source:** Kubernetes 소스 `pkg/controller/deployment` — `rolling.go`(`rolloutRolling`/`reconcileNewReplicaSet`/`reconcileOldReplicaSets`), `util/deployment_util.go`(`ResolveFenceposts`/`MaxSurge`/`MaxUnavailable`/`NewRSNewReplicas`/`GetReplicaSetProportion`)
> **Secondary:** Kubernetes Docs — Workloads/Deployments §Rolling Update Deployment·§Proportional scaling; 같은 컨트롤러의 `sync.go`(`scale()`/`scaleReplicaSet` — 어노테이션 갱신 시점)
> **Date:** 2026-08-05
> **Status:** draft

## 왜 봤나

- `kubectl rollout status`를 보다 보면 Pod 개수가 예상과 다르게 움직이는 순간이 있다. "replicas 3, maxSurge/maxUnavailable 다 25%인데 왜 Pod가 4개가 아니라 3개뿐이지?", "replicas 1인데 왜 다운타임이 없지?" — 답은 두 값이 **독립된 두 스케일 경로(업/다운)** 를 통제하고, 퍼센트→정수 변환에 **비대칭 라운딩**이 걸려 있다는 데 있다.
- 흔한 오해: maxSurge/maxUnavailable을 "한 롤아웃에서 총 몇 개의 여유 슬롯을 쓸지 미리 정하는 예산"으로 생각하기 쉽다. 실제로는 컨트롤러가 매 sync loop마다 "지금 스케일업할 수 있는가"와 "지금 스케일다운할 수 있는가"를 따로 재계산하는 **폴링 기반 상태 전이**다.

## 핵심 한 문장

> Deployment 컨트롤러는 매 reconcile 주기마다 `replicas + maxSurge`(상한)와 `replicas - maxUnavailable`(하한)라는 두 울타리(fencepost) 안에서, 새 ReplicaSet은 상한에 닿을 때까지만 올리고 옛 ReplicaSet은 하한을 지키는 한도까지만 내리는 것을 반복하며, 그 상한·하한 자체는 퍼센트를 서로 다른 방향으로 반올림해 만들어진다.

## 내부 동작

### 1. 퍼센트 → 정수 변환: 대칭이 아니다

`ResolveFenceposts(maxSurge, maxUnavailable, desiredReplicas)`가 두 필드를 한 번에 정수로 만든다.

- `maxSurge`는 `GetScaledValueFromIntOrPercent(..., roundUp=true)` — **올림**
- `maxUnavailable`은 `GetScaledValueFromIntOrPercent(..., roundUp=false)` — **내림**
- 두 값이 변환 결과 **둘 다 0**이면 `maxUnavailable`을 강제로 1로 올린다(둘 다 0이면 스케일업도 스케일다운도 못 해 롤아웃이 멈추기 때문).

기본값은 둘 다 25%다(Docs 명시). `replicas=1`일 때 25%는 0.25인데, surge는 올림이라 `ceil(0.25)=1`, unavailable은 내림이라 `floor(0.25)=0`이고 이 경우 surge가 이미 0이 아니므로 "둘 다 0" 예외에 걸리지 않는다. 즉 **replicas=1인 Deployment는 기본 설정에서 maxUnavailable=0, maxSurge=1로 고정**된다 — 옛 Pod를 먼저 지우는 게 아니라 새 Pod를 먼저 하나 더 띄우는 경로만 열려 있다는 뜻이고, 이것이 "replicas 1개짜리 Deployment도 기본값으로 무중단 롤링이 된다"는 현상의 실제 원인이다.

`MaxUnavailable(d)`/`MaxSurge(d)`는 `ResolveFenceposts`를 감싸 전략이 `RollingUpdate`가 아니거나 `replicas==0`이면 0을 반환하는 가드만 얹은 래퍼다.

### 2. 스케일업과 스케일다운은 서로 다른 함수, 서로 다른 조건

`rolloutRolling`은 매 호출마다 이 순서로 딱 한 단계만 진행한다:

```
rolloutRolling(d, rsList):
    newRS, oldRSs = syncRevision(...)
    if reconcileNewReplicaSet(...):   # 스케일업 시도, 됐으면 여기서 리턴
        return syncStatus()
    if reconcileOldReplicaSets(...):  # 안 됐으면 스케일다운 시도
        return syncStatus()
    return syncStatus()               # 둘 다 안 됐으면 상태만 갱신
```

**스케일업 — `NewRSNewReplicas`**: `maxTotalPods = replicas + maxSurge`. `currentPodCount`는 새 RS뿐 아니라 **old+new 전체 RS의 spec.replicas 합**이다. `currentPodCount >= maxTotalPods`면 더 못 올리고 그대로 리턴한다. 여유가 있으면 `scaleUpCount = maxTotalPods - currentPodCount`만큼, 단 목표 replicas를 넘지 않게 클램프해서 새 RS를 올린다. 즉 **옛 RS가 아직 Pod를 많이 쥐고 있으면 그만큼 새 RS의 서지 여유가 깎인다** — surge는 "새 RS 전용 여유"가 아니라 "전체 Pod 개수 상한"이다.

**스케일다운 — `reconcileOldReplicaSets`**: `minAvailable = replicas - maxUnavailable`. `maxScaledDown = allPodsCount(spec 기준) - minAvailable - (newRS의 미가용 Pod 수)`. 여기서 새 RS의 미가용 Pod 수를 빼는 이유가 핵심이다 — 새로 올라간 Pod가 아직 Ready가 아니라면 그 자리를 "이미 비어 있는 것"처럼 셈해서, 옛 Pod를 추가로 지웠을 때 실질 가용 Pod 수가 `minAvailable` 밑으로 떨어지는 걸 막는다. `maxScaledDown <= 0`이면 이번 사이클엔 스케일다운을 아예 안 한다.

스케일다운 순서도 한 방향이 아니라 2단계다:
1. `cleanupUnhealthyReplicas` — 생성시각 오름차순으로 old RS를 훑으면서, **건강하지 않은(=Available 미달) Pod부터** 예산 안에서 먼저 정리한다. 정상 Pod엔 손대지 않는다.
2. `scaleDownOldReplicaSetsForRollingUpdate` — 1단계 후에도 `availablePodCount(실제 Available 기준) > minAvailable`이면 그 차이만큼, 다시 생성시각이 오래된 RS부터 순서대로 spec.replicas를 깎는다.

즉 "옛 Pod를 지우는 순서 = 무조건 생성순"이 아니라 **"불건강한 것 먼저, 그다음에야 생성순"** 이다.

### 3. Proportional scaling — replicas 자체가 바뀔 때

`dc.scale()`(`sync.go`)은 세 갈래로 나뉜다: (a) 활성 RS가 하나뿐이면 그냥 그 RS를 목표치로 직접 스케일, (b) 새 RS가 이미 saturated(목표치만큼 다 찼음)면 옛 RS들을 전부 0으로, (c) 그 외 — 즉 **옛 RS에 아직 Pod가 남아 있고 새 RS는 아직 다 안 찼을 때**만 아래의 비례 분배가 실행된다.

- `allowedSize = 새 replicas + maxSurge`, `deploymentReplicasToAdd = allowedSize - allRSs의 현재 replicas 합`
- 늘릴 때(`>0`)는 RS를 **크기가 큰(→최신) 순**으로, 줄일 때(`<0`)는 **크기가 작은(→오래된) 순**으로 정렬한 뒤, `GetReplicaSetProportion` → `getReplicaSetFraction`으로 RS마다 `rs.spec.replicas * (새 replicas+maxSurge) / deploymentMaxReplicasBeforeScale` 비율만큼 증감분을 배분한다.
- `deploymentMaxReplicasBeforeScale`는 그 RS의 `MaxReplicasAnnotation` 값이다. 이 값은 **RS가 생성될 때 한 번만 찍히는 게 아니라, `scaleReplicaSet`이 그 RS를 스케일할 때마다(생성이든 이후의 롤링 스케일업/다운이든) `deployment.Spec.Replicas + MaxSurge`로 다시 덮어써진다** — 즉 "각 RS가 마지막으로 자기 자신이 스케일됐던 시점의 목표치 스냅샷"이라, 한동안 손 안 댄 RS는 최신 목표치보다 낡은 값을 들고 있을 수 있는 **RS별 지연 스냅샷**이다.
- 정수 나눗셈 반올림으로 생기는 오차(합이 `deploymentReplicasToAdd`에 딱 안 맞는 나머지)는 정렬 순서상 **맨 앞(가장 크거나 가장 최신인) RS 하나에 몰아서** 보정한다.

즉 "새 RS부터 먼저 목표치까지 채운다"가 아니라, 두 개 이상의 RS가 동시에 떠 있는 상태에서만 old/new가 **몸집 비례로 동시에** 움직이고, 그 비례 계산의 분모 자체가 최신값이 아니라 RS별로 갱신 시점이 다른 스냅샷이라는 게 미묘한 지점이다.

## 검증

1. 소스 확인(이번 실행에서 GitHub raw로 직접 읽음): `pkg/controller/deployment/util/deployment_util.go`, `rolling.go`, `sync.go`에서 본문에 인용한 함수 전부(`ResolveFenceposts`·`NewRSNewReplicas`·`reconcileOldReplicaSets`·`cleanupUnhealthyReplicas`·`GetReplicaSetProportion`·`scale()`/`scaleReplicaSet` 등)를 직접 읽고 확인했다.
2. 직접 재현 가능한 커맨드:
   ```
   kubectl create deployment demo --image=nginx --replicas=1
   kubectl rollout restart deployment/demo
   kubectl get rs -w   # 잠깐 동안 RS가 2개, 총 Pod가 2개로 surge=1이 실제로 뜨는지 확인
   kubectl get deployment demo -o jsonpath='{.spec.strategy.rollingUpdate}'
   ```
   `maxUnavailable`을 명시하지 않으면 기본 25%가 `replicas=1`에서 0으로 내려가는지, `maxSurge`는 1로 올라가는지를 `describe deployment`의 `RollingUpdateStrategy` 필드로 확인할 수 있다.
3. 여러 활성 RS 상태에서 `.spec.replicas`를 바꾸며 `kubectl get rs`로 각 RS의 `DESIRED` 값이 한쪽으로 몰리지 않고 비례해서 바뀌는지 관찰하면 proportional scaling을 눈으로 볼 수 있다(Docs의 "Proportional scaling" 예제와 동일한 방식).

## 잘못 알고 있던 것

- maxSurge와 maxUnavailable을 "한 롤아웃 동안 쓸 수 있는 하나의 예산"으로 생각하기 쉽지만, 실제로는 스케일업 판단(`reconcileNewReplicaSet`)과 스케일다운 판단(`reconcileOldReplicaSets`)이 **완전히 분리된 두 함수**이고, 매 sync마다 그때그때의 Pod 개수/가용성 기준으로 다시 계산된다. 예산을 미리 나눠 쓰는 게 아니라 매번 "지금 이 경계를 넘는가"만 본다.
- 퍼센트 라운딩이 surge/unavailable에서 같은 방향일 거라 생각하기 쉽지만, surge는 올림·unavailable은 내림으로 **의도적으로 비대칭**이다. 이 비대칭 때문에 `replicas=1`처럼 작은 수에서 두 값이 우연히 같은 결과(둘 다 0 또는 둘 다 1)로 겹치지 않고, 시스템이 "무조건 먼저 늘리고 나중에 줄이는" 쪽으로 편향된다.
- 옛 ReplicaSet의 Pod가 지워지는 순서를 "먼저 만들어진 RS부터 통째로"라고 생각하기 쉽지만, 실제로는 두 컨트롤러가 나눠서 결정한다. Deployment 컨트롤러(`cleanupUnhealthyReplicas`)는 "어느 RS의 spec.replicas를 얼마나 줄일지"만 정하되 Available 미달 replica를 가진 RS를 먼저 줄이고, 그다음에야 생성순으로 넘어간다. 그 RS 안에서 **어느 Pod가 실제로 삭제되는지**는 별도의 ReplicaSet 컨트롤러가 not-ready < ready, pending < running 순으로 골라 정한다 — Deployment 컨트롤러는 개수만 정하고 대상 Pod 선택에는 관여하지 않는다.

## 더 파고들 만한 것

- StatefulSet의 `RollingUpdate.partition`은 이 fencepost 방식과 전혀 다른 "ordinal 경계선" 방식으로 롤링을 제어한다 — 비교해 볼 만하다.
- HPA가 롤아웃 도중에 개입할 때 `.spec.replicas`를 바꾸는 주체가 되면서 proportional scaling과 surge/unavailable 계산이 같은 sync loop 안에서 어떻게 충돌 없이 맞물리는지.

## 참고

- Kubernetes Docs — Deployments (Rolling Update Deployment / Proportional scaling 섹션)
- Kubernetes 소스 `pkg/controller/deployment/{util/deployment_util.go, rolling.go, sync.go}`

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
