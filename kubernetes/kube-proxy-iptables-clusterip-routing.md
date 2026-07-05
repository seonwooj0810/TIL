# kube-proxy iptables 모드의 ClusterIP 라우팅: 존재하지 않는 IP로 보낸 패킷이 어떻게 Pod에 닿나

> **Primary source:** Kubernetes 공식 docs — Service / Virtual IPs and Service Proxies (iptables proxy mode), kube-proxy 소스 `pkg/proxy/iptables/proxier.go`
> **Secondary:** netfilter/iptables `statistic`·`conntrack` 매뉴얼, Linux nat table 문서
> **Date:** 2026-07-05
> **Status:** draft

## 왜 봤나

- `kubectl get svc` 로 보이는 ClusterIP(예: `10.96.0.10`)는 어떤 네트워크 인터페이스에도 붙어 있지 않다. `ping` 도 안 되고 ARP 응답도 없다. 그런데 Pod에서 그 IP로 요청하면 멀쩡히 백엔드 Pod로 도달한다. 이 "가짜 IP"가 어떻게 실체 있는 Pod로 이어지는지가 궁금했다.
- 나는 오래 "kube-proxy가 트래픽을 프록시한다"고 이해했다 — 즉 kube-proxy 프로세스가 패킷을 실제로 중계하는 줄 알았다. iptables 모드에서는 틀린 이해였다.

## 핵심 한 문장

> iptables 모드의 kube-proxy는 패킷을 나르지 않는다 — 커널 nat 테이블에 DNAT 규칙 사슬을 심어 두고, 실제 목적지 변환·부하분산·역방향 복원은 전부 커널 netfilter와 conntrack이 수행한다.

## 내부 동작

### 1. ClusterIP는 라우팅 대상이 아니라 iptables 매칭 키

ClusterIP는 인터페이스에 할당된 주소가 아니다. 그래서 L3 라우팅 관점에선 "갈 곳 없는" 주소지만, 패킷이 커널 네트워크 스택을 통과할 때 **nat 테이블의 PREROUTING/OUTPUT 훅**에서 목적지 IP가 ClusterIP인지 매칭된다. kube-proxy는 이 매칭을 위한 규칙만 심어 둔다. 즉 ClusterIP의 의미는 "라우팅 목적지"가 아니라 "DNAT 규칙의 조건"이다.

### 2. kube-proxy의 역할: 컨트롤 플레인만

kube-proxy는 API 서버의 Service/EndpointSlice 변화를 watch 하다가, 그 상태를 iptables 규칙으로 **번역해 커널에 반영**한다. 데이터 플레인(실제 패킷 처리)에는 관여하지 않는다. 그래서 kube-proxy가 잠깐 죽어도 이미 설치된 규칙으로 기존 라우팅은 계속 동작한다 — 변화 반영만 멈출 뿐이다.

### 3. 규칙 사슬 구조 (3단 점프)

nat 테이블에 다음과 같은 커스텀 체인들이 만들어진다:

```
PREROUTING / OUTPUT
   └─▶ KUBE-SERVICES           (모든 Service의 진입점, 목적지=ClusterIP:port 매칭)
          └─▶ KUBE-SVC-<hash>  (특정 Service. 여기서 엔드포인트 하나를 "고른다")
                 ├─▶ KUBE-SEP-<hashA>  (endpoint A: DNAT → PodA_IP:port)
                 ├─▶ KUBE-SEP-<hashB>  (endpoint B: DNAT → PodB_IP:port)
                 └─▶ KUBE-SEP-<hashC>  (endpoint C: DNAT → PodC_IP:port)
```

- `KUBE-SERVICES` 는 `-d 10.96.0.10/32 -p tcp --dport 80 -j KUBE-SVC-XXXX` 형태로, 목적지가 특정 ClusterIP:port면 그 Service 체인으로 점프시킨다.
- `KUBE-SVC-XXXX` 는 엔드포인트(=준비된 Pod) 하나를 고른다.
- `KUBE-SEP-YYYY` (Service EndPoint)에서 실제 `DNAT --to-destination PodIP:port` 이 일어난다.

### 4. 확률 기반 로드밸런싱 — `statistic` 모듈의 계단식 확률

핵심은 `KUBE-SVC` 체인이 엔드포인트를 **어떻게 균등하게** 고르느냐다. iptables에는 라운드로빈이 없다. 대신 netfilter `statistic` 모듈의 `--mode random --probability p` 를 쓴다: 규칙이 확률 p로 매칭(=점프)되고, 안 되면 다음 규칙으로 흐른다.

균등 분포를 만들려면 확률을 **1/n, 1/(n-1), …, 1/2, 1(마지막)** 로 계단식으로 준다. 엔드포인트 3개라면:

```
규칙1:  -m statistic --mode random --probability 0.33333  -j KUBE-SEP-A
규칙2:  -m statistic --mode random --probability 0.50000  -j KUBE-SEP-B
규칙3:  (무조건)                                           -j KUBE-SEP-C
```

- 규칙1이 A를 고를 확률 = 1/3.
- 규칙1을 통과(2/3)한 뒤 규칙2가 B를 고를 확률 = (2/3)·(1/2) = 1/3.
- 둘 다 통과한 나머지(1/3)는 규칙3이 무조건 C. → 셋 다 정확히 1/3.

이 "남은 확률에 대한 조건부 확률" 설계가 계단식 분모의 이유다. 앞 규칙이 흡수하고 남긴 트래픽만 뒷 규칙이 나눠 갖는다.

### 5. DNAT과 conntrack — 상태는 커널이 기억한다

`KUBE-SEP` 에서 DNAT이 일어나면 목적지 IP/port가 ClusterIP → PodIP 로 바뀐다. 그런데 DNAT은 **연결(flow)의 첫 패킷에만** 규칙 평가로 적용된다. 커널 `conntrack`(연결 추적)이 이 변환을 하나의 conntrack 엔트리로 기록하기 때문이다:

```
original:  src=Pod_CLIENT dst=10.96.0.10:80   (클라이언트가 보낸 그대로)
reply:     src=PodB_IP:8080 dst=Pod_CLIENT    (DNAT 반영된 실제 목적지)
```

- 같은 flow의 이후 패킷은 규칙을 다시 타지 않고 conntrack 엔트리를 따라 같은 Pod로 간다 → **연결이 중간에 다른 Pod로 튀지 않는다**(엔드포인트 선택은 flow당 한 번).
- 응답 패킷(PodB→Client)은 conntrack의 reply 튜플을 근거로 커널이 **자동으로 un-DNAT**한다. src를 PodB_IP → ClusterIP 로 되돌려 주므로, 클라이언트는 자기가 보낸 ClusterIP에서 답이 온 것처럼 본다. kube-proxy가 응답에 손대지 않아도 된다.

### 6. 왜 이 방식이 대규모에서 느려지나 → IPVS 모드

iptables 규칙은 본질적으로 **리스트를 위에서부터 선형 평가**한다. Service·엔드포인트가 늘면 `KUBE-SERVICES` 를 지나며 매칭까지 훑는 규칙 수가 O(n)로 증가하고, 규칙 갱신(한 Pod 추가에도 큰 테이블 재작성)도 비싸진다. 그래서 대규모 클러스터는 IPVS 모드를 쓴다 — IPVS는 커널 해시 테이블로 O(1) 조회에 rr/lc 등 실제 스케줄러를 제공한다. (다만 DNAT/conntrack에 기대는 큰 그림은 iptables 모드와 같다.)

## 검증

공식 docs의 "iptables proxy mode" 설명과 kube-proxy 소스의 체인 명명(`KUBE-SERVICES`/`KUBE-SVC-`/`KUBE-SEP-`)을 따라가며 흐름을 확인했다. 노드에서 직접 규칙을 덤프하면 위 3단 구조와 계단식 확률이 그대로 보인다:

```bash
# Service 진입 규칙 (ClusterIP → KUBE-SVC 점프)
iptables -t nat -L KUBE-SERVICES -n | grep 10.96.0.10

# 특정 Service의 엔드포인트 선택 (계단식 확률)
iptables -t nat -L KUBE-SVC-XXXX -n
#  ... statistic mode random probability 0.33333  -> KUBE-SEP-A
#  ... statistic mode random probability 0.50000  -> KUBE-SEP-B
#  ...                                             -> KUBE-SEP-C

# 실제 DNAT
iptables -t nat -L KUBE-SEP-A -n
#  DNAT tcp -- ... to:10.244.1.5:8080

# flow가 conntrack에 고정됨을 확인
conntrack -L -d 10.96.0.10
#  tcp ... src=10.244.0.7 dst=10.96.0.10 ... [ASSURED]
```

확률 계단이 균등 분포를 주는지는 위 4절의 조건부 확률 계산으로 확인된다: n개 엔드포인트에서 k번째 규칙의 확률을 1/(n-k+1)로 두면 각 엔드포인트의 최종 선택 확률이 모두 1/n로 떨어진다.

## 잘못 알고 있던 것

- **"kube-proxy가 트래픽을 프록시한다"** — iptables/IPVS 모드에서는 아니다. kube-proxy는 컨트롤 플레인(규칙 설치)만 하고, 패킷은 커널 netfilter가 처리한다. userspace 모드(초기, 지금은 안 씀)에서만 kube-proxy가 실제로 패킷을 중계했다. 이름의 "proxy"가 오해를 부른다.
- **"ClusterIP로 가는 라우트가 어딘가 있을 것"** — 없다. ClusterIP는 인터페이스에도, 라우팅 테이블에도 없는 순수 가상 주소이며 오직 iptables 매칭 조건으로만 존재한다. 그래서 `ping ClusterIP`가 안 되는 게 정상이다(대상이 TCP DNAT 규칙일 뿐 ICMP 응답 주체가 없다).
- **"확률 규칙이면 요청마다 다른 Pod로 갈 수 있으니 연결이 흔들리겠다"** — 아니다. 확률 선택은 flow의 **첫 패킷 한 번**만 일어나고, 이후는 conntrack이 같은 Pod로 고정한다. 로드밸런싱 단위는 패킷이 아니라 연결이다.

## 더 파고들 만한 것

- IPVS 모드의 내부: 커널 IPVS 해시 테이블·스케줄러(rr/wrr/lc)와 conntrack의 관계.
- `externalTrafficPolicy: Local` 이 SNAT/소스 IP 보존과 부하 불균형에 미치는 영향.
- conntrack 테이블 고갈(`nf_conntrack: table full`)이 대량 커넥션 환경에서 만드는 장애 패턴.

## 참고

- Kubernetes docs — Service, Virtual IPs and Service Proxies (iptables proxy mode)
- kube-proxy 소스 `pkg/proxy/iptables/proxier.go` (KUBE-SERVICES/KUBE-SVC/KUBE-SEP 체인 생성)
- iptables `statistic`·netfilter `conntrack` 매뉴얼
