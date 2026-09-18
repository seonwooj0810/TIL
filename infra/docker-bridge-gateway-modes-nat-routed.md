# Docker 브리지 네트워크 게이트웨이 모드: NAT/masquerade와 routed/direct-routing의 경계

> **Primary source:** Docker Engine 공식 문서 — Networking overview(`/engine/network/`), Port publishing and mapping(`/engine/network/port-publishing/`), Bridge network driver(`/engine/network/drivers/bridge/`, Gateway modes: `nat`/`nat-unprotected`/`routed`/`isolated`)
> **Secondary:** Docker Engine Docs — Packet filtering and firewalls 개요, GitHub moby/moby#45610
> **Date:** 2026-09-18
> **Status:** draft

## 왜 봤나

- "`docker run -p`는 그냥 iptables 포트포워딩 한 줄 추가하는 것"이라고 뭉뚱그려 알고 있었다. 실제로는 마스커레이딩 여부, 발신 패킷의 소스 주소, 외부에서의 도달 가능성이 **게이트웨이 모드**에 따라 완전히 다른 경로를 탄다.
- 이전 infra 노트들(overlay2, cgroup v2, seccomp, namespaces)이 "컨테이너 하나 안"의 격리 메커니즘이었다면, 이번엔 "컨테이너 여러 개 + 호스트 + 외부망" 사이의 패킷 경로 결정 메커니즘이라 결이 다르다.
- 흔한 혼동: "포트를 게시(publish)하지 않으면 아무도 접근 못 한다" / "NAT를 끄면 외부에서 바로 붙을 수 있다" 같은 단순화가 실제로는 어디서 틀리는지 짚고 싶었다.

## 핵심 한 문장

> Docker 브리지 네트워크의 접근성은 "NAT 온/오프"라는 하나의 스위치가 아니라, `nat`/`nat-unprotected`/`routed`/`isolated` 네 가지 게이트웨이 모드가 만드는 **(마스커레이딩 여부 × 발신 소스주소 × direct-routing 허용 여부 × 타 네트워크 접근 경로)** 네 축의 조합 상태다.

## 내부 동작

### 기본 그림: 브리지 + masquerade + 게시된 포트만 DNAT

컨테이너가 브리지 네트워크에 붙으면 자기 서브넷 안의 IP를 받는다. 기본(`nat` 모드) 동작은 두 방향이 완전히 다른 규칙을 쓴다.

```
[아웃바운드: 컨테이너 → 외부]
container(172.17.0.2) → docker0 → (SNAT/masquerade: src를 호스트 인터페이스 주소로 치환) → 외부

[인바운드: 외부 → 컨테이너]
외부 → 호스트IP:hostPort → (DNAT+PAT: dst를 containerIP:containerPort로 치환) → container
        ※ 이 DNAT 규칙은 '-p/--publish'로 게시한 포트에만 생성된다.
```

즉 나가는 트래픽은 "항상" 마스커레이딩되지만(`com.docker.network.bridge.enable_ip_masquerade`, 기본 `true`), 들어오는 트래픽은 "게시한 포트만" DNAT 대상이 된다 — 두 규칙은 독립적인 축이다.

### 게이트웨이 모드 4종: `com.docker.network.bridge.gateway_mode_ipv4`/`_ipv6`

브리지 드라이버는 네트워크 단위로 이 옵션을 받는다. 기본값은 `nat`.

```
모드              NAT/masquerade   발신 소스주소        미게시 포트 노출   외부 도달 조건
─────────────────────────────────────────────────────────────────────────────
nat (기본)        있음              호스트 주소로 치환    없음(필터링)      호스트 게시 주소로만
nat-unprotected   있음              호스트 주소로 치환    있음(필터 생략)    호스트 주소 + 직접 라우팅
routed            없음              컨테이너 자신 주소     없음(필터링)      외부 라우팅 테이블에
                                                                          컨테이너 서브넷 경로 필요
isolated          -                -                    -                브리지에 주소 자체가 없음
                                                          (--internal 네트워크 전용)
```

- **`nat`**: 게시된 포트마다 DNAT/PAT 규칙이 개별 생성되고, 나가는 패킷은 마스커레이딩된다. 외부 클라이언트는 컨테이너 IP를 몰라도 되고 몰라야 한다 — 오직 "호스트 IP:게시포트"로만 접근 가능. 다른 브리지 네트워크의 컨테이너도 같은 제약을 받는다(호스트 주소를 거쳐야 함, direct routing 불가).
- **`nat-unprotected`**: NAT 자체는 켜져 있지만 "게시하지 않은 포트를 막는" 필터 규칙을 생성하지 않는다. 레거시 호환용으로, direct routing이 가능한 경로만 있으면 게시 여부와 무관하게 모든 포트가 노출된다.
- **`routed`**: NAT/masquerade 규칙 자체가 없다. 다만 "게시된 포트만 통과"시키는 필터 규칙은 여전히 생성된다. 나가는 패킷은 컨테이너 자신의 IP를 소스로 유지한다. 외부에서 붙으려면 그 외부 호스트가 "컨테이너 서브넷으로 가는 경로 = 도커 호스트"라는 라우팅 정보를 별도로 가지고 있어야 한다(정적 라우트, BGP 등) — 이게 문서가 말하는 "direct routing"이다. 같은 로컬 L2 세그먼트라면 별도 설정 없이도 도달 가능하지만, L2 밖에서는 라우터가 그 경로를 알아야 한다.
- **`isolated`**: `--internal` 네트워크에서만 쓸 수 있고, 이 모드일 때는 브리지 디바이스에 게이트웨이 주소 자체를 배정하지 않는다. north-south(외부-내부) 트래픽이 원천적으로 불가능해진다.

게이트웨이 모드는 **`ipv4`/`ipv6`에 각각 독립적으로** 지정할 수 있다. IPv4는 `nat`(호환성), IPv6는 `routed`(주소 공간이 넓어 NAT 불필요)로 섞는 구성이 문서 예시로 나온다. 이때 `docker inspect`의 포트 매핑에서 IPv6 쪽은 `HostPort`가 비는데, routed는 호스트 포트 개념 자체가 없기 때문이다.

### 타 네트워크 간 접근성도 모드에 종속된다

같은 호스트에서 서로 다른 브리지 네트워크에 붙은 컨테이너 A(네트워크1), B(네트워크2)가 있을 때:

- 네트워크2가 `nat`/`nat-unprotected`면: A는 B의 게시된 포트를 **호스트 주소**를 통해서만 접근할 수 있다. B의 컨테이너 IP로 직접 갈 수 없다.
- 네트워크2가 `routed`면: A는 B의 게시된 포트에 **direct routing**으로, 호스트 주소를 거치지 않고 접근할 수 있다.

이건 "게이트웨이 모드가 단순히 외부(호스트 밖) 접근성만 결정한다"는 생각을 깨는 지점이다 — 호스트 안의 네트워크 간 트래픽 경로도 같은 축으로 갈린다.

### direct routing은 기본적으로 잠겨 있다

`routed` 모드라 해도 "브리지 네트워크의 컨테이너 IP로 리모트 호스트가 직접 접근하는 것"은 기본값이 아니다. 문서상 두 가지 옵트인 경로가 있다:

1. 데몬 전역 옵션 `--allow-direct-routing`(`daemon.json`의 `"allow-direct-routing": true`) — 모든 리눅스 브리지 네트워크에서 게시된 포트에 대한 direct routing을 허용.
2. 네트워크별 드라이버 옵션 `com.docker.network.bridge.trusted_host_interfaces` — 지정한 호스트 인터페이스(예: `vxlan.1`, `eth3`)로부터만 그 네트워크로의 direct routing을 허용.

즉 "라우팅 테이블에 경로만 있으면 무조건 뚫린다"가 아니라, Docker 쪽에서 한 번 더 신뢰 경계를 긋는다.

### IP forwarding을 켜면서 동시에 FORWARD 기본정책을 DROP으로 바꾼다

리눅스에서 컨테이너 네트워킹이 동작하려면 `net.ipv4.ip_forward`/`net.ipv6.conf.all.forwarding` sysctl이 켜져 있어야 한다. Docker는 이게 꺼져 있으면 시작 시 직접 켜는데, **이때 동시에 FORWARD 체인의 기본 정책을 DROP으로 설정**한다(`ip-forward-no-drop` 옵션으로 끌 수 있음). 이렇게 하지 않으면 ip_forward가 켜진 호스트는 그 자체로 "허용되지 않은 트래픽까지 다 넘겨주는 오픈 라우터"가 될 수 있기 때문이다 — Docker가 명시적으로 허용 규칙을 만든 컨테이너 트래픽만 통과시키고 나머지는 기본으로 막는 구조다.

## 검증

이 repo엔 실행 환경이 없으므로, 실제 Docker 호스트가 있는 독자가 재현할 수 있는 절차로 적는다.

```bash
# 1) routed 모드 네트워크와 nat 모드 네트워크를 각각 만든다
docker network create --subnet 203.0.113.0/24 \
  -o com.docker.network.bridge.gateway_mode_ipv4=routed routednet
docker network create natnet

# 2) 각 네트워크에서 포트를 게시한 컨테이너를 띄운다
docker run -d --network natnet    -p 8080:80 --name c-nat    nginx
docker run -d --network routednet -p 8081:80 --name c-routed nginx

# 3) 옵션이 실제로 적용됐는지 확인
docker network inspect routednet -f '{{json .Options}}'

# 4) iptables nat 테이블에서 두 네트워크의 규칙 유무를 비교
#    natnet 쪽에는 해당 서브넷에 대한 MASQUERADE/DNAT 규칙이 보이고,
#    routednet 쪽에는 nat 테이블 규칙이 없어야 한다(filter 테이블 허용 규칙만 존재).
sudo iptables -t nat -L -n -v

# 5) 포트 매핑 구조 차이 확인 (routed면 IPv6 HostPort가 비는 등 케이스 재현 가능)
docker container inspect c-nat    --format '{{json .NetworkSettings.Ports}}'
docker container inspect c-routed --format '{{json .NetworkSettings.Ports}}'
```

무엇을 보면 확인되는가: `natnet`에서는 `iptables -t nat -L`에 해당 서브넷/포트에 대한 `MASQUERADE`(또는 `SNAT`)와 DNAT 규칙이 나타나고, `routednet`에서는 nat 테이블에 해당 네트워크 관련 규칙이 없어야 한다. 정확한 체인 이름(`DOCKER`, `DOCKER-USER` 등)은 버전·백엔드(iptables vs 실험적 nftables)마다 달라질 수 있어 문서 자체가 "구현 세부사항으로 취급하라"고 명시한다 — 그래서 구체적 체인 이름을 단정하지 않고 nat 테이블 유무라는 관찰 가능한 사실로 검증 절차를 잡았다.

## 잘못 알고 있던 것

- **오해 1: "포트를 게시(`-p`)하지 않으면 아무도 그 포트에 못 붙는다."**
  실제로는 같은 브리지 네트워크에 붙은 다른 컨테이너나 호스트 자신은, 게시 여부와 무관하게 컨테이너의 **모든** 포트에 접근할 수 있다(`com.docker.network.bridge.enable_icc`가 기본 `true`이기 때문). `-p`/`--publish`가 여는 것은 "호스트 바깥" 또는 "다른 네트워크"로부터의 접근이다. 게시하지 않은 포트가 완전히 닫히는 건 같은 네트워크 밖에서 바라볼 때뿐이다.

- **오해 2: "NAT를 끄면(=`routed` 모드) 외부에서 곧바로 컨테이너에 붙을 수 있게 된다."**
  `routed` 모드가 없애는 건 마스커레이딩/DNAT 규칙뿐이다. 외부 호스트가 실제로 컨테이너 서브넷에 도달하려면 그 호스트(또는 그 앞의 라우터)가 "이 서브넷은 이 도커 호스트를 거쳐 간다"는 라우팅 정보를 별도로 가지고 있어야 한다. NAT 제거는 라우팅 가능성의 전제조건일 뿐, 라우팅 자체를 만들어주지 않는다. 게다가 direct routing 자체도 `allow-direct-routing`/`trusted_host_interfaces`로 opt-in 해야 열린다.

- **오해 3: "포트를 `127.0.0.1`에 게시하면 완전히 안전하다."**
  Docker 28.0.0 이전 버전에서는 **같은 L2 스위치에 연결된 다른 호스트**가 그 "localhost 게시" 포트에 접근할 수 있는 버그가 있었다(moby/moby#45610, 문서에 경고로 명시). "로컬 바인딩 = 이 머신 밖에서는 절대 도달 불가"라는 가정이 버전·구현 세부사항에 의존했던 사례다.

- **오해 4: "`ip_forward`를 켜면 호스트가 그냥 라우터가 돼서 뭐든 포워딩한다."**
  Docker가 `net.ipv4.ip_forward`/`net.ipv6.conf.all.forwarding`을 켤 때는 그와 동시에 FORWARD 체인 기본 정책을 DROP으로 맞춘다. 그래서 켜져 있어도 실제로 통과하는 건 Docker가 명시적으로 허용 규칙을 만든 컨테이너 트래픽뿐이고, 그 외 포워딩은 기본으로 막힌다 — "호스트가 오픈 라우터가 되는 부작용"을 정책 자체로 상쇄한다.

## 더 파고들 만한 것

- iptables 백엔드 대신 nftables 백엔드(`firewall-backend` 옵션)를 쓸 때 규칙 구조와 IP forwarding 기본 정책이 어떻게 달라지는지(문서는 nftables가 기본 DROP 정책을 자동 설정하지 않는다고 언급한다).
- Swarm overlay 네트워크(VXLAN 캡슐화 기반, 멀티호스트)가 이 단일 호스트 bridge NAT 모델과 근본적으로 어떻게 다른 계층에서 동작하는지.

## 참고

- Docker Engine Docs — Networking overview (`/engine/network/`)
- Docker Engine Docs — Port publishing and mapping (`/engine/network/port-publishing/`)
- Docker Engine Docs — Bridge network driver, Gateway modes (`/engine/network/drivers/bridge/`)
- Docker Engine Docs — Packet filtering and firewalls (`/engine/network/packet-filtering-firewalls/`)
- GitHub moby/moby#45610 (localhost 게시 포트의 L2-adjacent 접근 이슈)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
