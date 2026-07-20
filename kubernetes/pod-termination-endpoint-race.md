# 쿠버네티스 파드 종료의 경쟁 조건: SIGTERM과 엔드포인트 제거는 순서가 없다

> **Primary source:** Kubernetes Docs — Pods / Pod Lifecycle §"Termination of Pods", Service/EndpointSlice §"EndpointSlices"·"terminating conditions"
> **Secondary:** kube-proxy 동작 문서(ProxyTerminatingEndpoints), 이전 노트 [kube-proxy iptables ClusterIP 라우팅](./kube-proxy-iptables-clusterip-routing.md)
> **Date:** 2026-07-20
> **Status:** draft

## 왜 봤나

롤링 업데이트나 스케일 인 때 "무중단"이라고 믿었는데 클라이언트에 간헐적으로 `connection refused` / RST가 찍혔다. `terminationGracePeriodSeconds`만 넉넉히 주면 될 줄 알았는데 아니었다. 파드가 죽는 절차와, 서비스 엔드포인트에서 빠지는 절차가 **누가 먼저인지 보장이 없다**는 게 원인이었다.

## 핵심 한 문장

> 파드 삭제 한 번은 kubelet의 SIGTERM 경로와 EndpointSlice→kube-proxy 라우팅 철거 경로를 **동시에·독립적으로** 깨우며, 둘 사이에 순서 보장이 없으므로 preStop 지연이나 애플리케이션 드레이닝 없이는 "이미 엔드포인트에 남아있는데 앱은 이미 종료 중"인 창(window)이 생긴다.

## 내부 동작

파드를 지우면(`kubectl delete`, 스케일 인, 롤링 교체, eviction 모두 동일) API 서버는 오브젝트에 `metadata.deletionTimestamp`를 찍고 `terminationGracePeriodSeconds`(기본 30초) 카운트다운을 시작한다. 이 상태 변화 하나가 **watch로 연결된 여러 컨트롤러를 각자 깨운다.** 서로를 기다리지 않는다.

```
          delete Pod (deletionTimestamp 세팅)
                       │
        ┌──────────────┴───────────────────────┐
        ▼                                        ▼
  [ kubelet (해당 노드) ]              [ EndpointSlice 컨트롤러 (control plane) ]
        │                                        │
   preStop 훅 실행                     엔드포인트 condition 갱신:
        │                              ready=false, serving=?, terminating=true
   컨테이너에 SIGTERM                            │  (이후 EndpointSlice 오브젝트 write)
        │                                        ▼
   grace 만료까지 대기                  [ 모든 노드의 kube-proxy ]
        │                              watch로 변경 수신 → iptables/IPVS 재프로그래밍
   SIGKILL(강제 종료)                          (파드 IP로의 DNAT 룰 제거)
```

**왼쪽(kubelet) 경로**: `preStop` 훅이 있으면 먼저 실행하고, 끝나면 컨테이너 PID 1에 SIGTERM을 보낸다. grace 기간이 지나면(또는 컨테이너가 먼저 나가면) SIGKILL. preStop 실행 시간도 grace 예산에서 **차감**된다 — preStop + 앱의 SIGTERM 처리 시간이 `terminationGracePeriodSeconds`를 넘기면 뒷부분이 SIGKILL로 잘린다.

**오른쪽(라우팅) 경로**: EndpointSlice 컨트롤러가 "이 파드는 종료 중"을 관측하고 해당 엔드포인트의 condition을 바꾼 뒤 EndpointSlice 오브젝트를 갱신한다. 그 변경을 **모든 노드의 kube-proxy가 각자 watch로 받아** 자기 노드의 iptables/IPVS 룰에서 그 파드 IP를 뺀다. 즉 라우팅이 실제로 끊기기까지는 `컨트롤러 처리 지연 + apiserver watch 전파 + N개 노드 kube-proxy 재프로그래밍`이라는 여러 홉의 비동기 지연이 쌓인다.

두 경로 사이엔 배리어가 없다. kubelet은 파드가 있는 노드에서 거의 즉시 SIGTERM을 쏘는데, 라우팅 철거는 클러스터 전역으로 퍼지는 데 수백 ms~수 초가 걸릴 수 있다. 그래서 **"앱은 이미 SIGTERM 받고 리스너를 닫았는데, 어떤 노드의 kube-proxy는 아직 이 파드로 새 연결을 DNAT"** 하는 구간이 생긴다. 그 연결은 대상 포트에 리스너가 없어 커널이 RST를 돌려주고 → 클라이언트엔 `connection refused`.

### terminating condition의 존재 이유

EndpointSlice의 엔드포인트에는 boolean 3개가 있다: `ready`, `serving`, `terminating`. 종료 중 파드는 `terminating=true`가 되고 `ready`는 false로 떨어진다. 그런데 `serving`은 파드가 아직 readiness를 통과하는 동안 true로 남을 수 있다. 이 분리 덕분에, ready 엔드포인트가 **하나도 없는** 상황(예: 급격한 롤링)에서 kube-proxy가 "serving 중인 terminating 엔드포인트"로라도 트래픽을 흘려 블랙홀을 피할 수 있다(ProxyTerminatingEndpoints). 즉 종료 중 파드가 라우팅에서 사라지는 것은 즉각적·원자적이 아니라 **조건 기반의 점진적** 과정이다.

### 그래서 무중단의 조건

라우팅 철거가 전파될 때까지 앱이 **계속 정상 응답**하도록 SIGTERM을 늦추거나, 앱이 SIGTERM 후에도 잠깐 드레이닝하게 만든다. 관용적으로 preStop에 짧은 sleep을 둔다:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 10"]   # 라우팅 전파 대기용
terminationGracePeriodSeconds: 45              # sleep(10) + 실제 드레이닝 여유
```

sleep 동안 파드는 여전히 살아있어 in-flight/새 요청을 정상 처리하고, 그 사이 kube-proxy 룰이 이 파드를 뺀다. sleep이 끝나면 SIGTERM이 오고, 이때부터 앱은 새 연결을 끊고 남은 요청만 마무리하면 된다. sleep 없이 grace만 늘리는 것은 SIGKILL까지의 시간만 늘릴 뿐 경쟁 자체를 없애지 못한다.

## 검증

Kubernetes 공식 "Termination of Pods" 절차를 따라가 순서를 확인했다: (1) delete → deletionTimestamp, grace 시작, (2) 파드가 "Terminating"으로 표시됨과 **동시에** 서비스 엔드포인트에서 제거 대상이 됨(문서가 "at the same time as the kubelet is starting graceful shutdown"이라고 명시), (3) preStop 실행 → SIGTERM → grace 만료 시 SIGKILL. 문서가 endpoint 제거와 kubelet 종료가 **병행**임을 직접 서술한다는 점이 핵심 근거다.

동작을 스니펫으로 재현해 보면(개념적 타임라인):

```
t=0.00  delete 수신, grace=30 시작
t=0.00  kubelet: preStop 없음 → 즉시 SIGTERM → 앱이 리스너 close
t=0.05  EndpointSlice 컨트롤러가 ready=false write (처리 지연)
t=0.20  노드 A kube-proxy iptables 갱신 완료
t=0.35  노드 B kube-proxy 아직 갱신 전  ← 이 창에서 노드 B발 새 연결 → RST
```

preStop `sleep 10`을 넣으면 SIGTERM이 t=10으로 밀려, t≈0.35의 라우팅 철거가 먼저 끝나므로 RST 창이 사라진다.

## 잘못 알고 있던 것

- **"쿠버네티스가 엔드포인트에서 먼저 빼고 그 다음에 파드를 죽인다"** — 아니다. 두 작업은 동일한 삭제 이벤트로 촉발되는 **독립적·병행** 절차이고 순서 보장이 없다. 오히려 SIGTERM이 라우팅 철거보다 먼저 도달하기 쉽다(kubelet은 로컬, 철거는 전역 전파).
- **"`terminationGracePeriodSeconds`를 늘리면 무중단이 된다"** — grace는 SIGTERM→SIGKILL 사이 시간일 뿐, 엔드포인트 전파 경쟁과 무관하다. 새 연결 차단 문제는 preStop 지연 + 앱의 SIGTERM 드레이닝으로 푼다.
- **"PID 1이 자동으로 SIGTERM에 반응한다"** — 컨테이너 엔트리가 `sh -c "java ..."` 같은 셸이면 셸이 시그널을 자식에 전달하지 않아 SIGTERM이 무시되고 grace 만료 후 SIGKILL로 강제 종료된다(드레이닝 실패). `exec` 폼이나 시그널 전달 가능한 init을 써야 한다.

## 더 파고들 만한 것

- EndpointSlice 컨트롤러의 배칭/mirroring과 대규모 서비스에서의 전파 지연 특성.
- ProxyTerminatingEndpoints가 실제 라우팅 결정에서 ready/serving/terminating을 어떻게 우선순위화하는지 kube-proxy 소스에서 확인.

## 참고

- Kubernetes Docs — Pods / Pod Lifecycle: "Termination of Pods"
- Kubernetes Docs — Service, EndpointSlices (endpoint conditions: ready/serving/terminating)
- 이전 노트: [kube-proxy iptables ClusterIP 라우팅](./kube-proxy-iptables-clusterip-routing.md)
