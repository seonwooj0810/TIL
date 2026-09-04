# SWIM 가십 프로토콜: 간접 프로빙(Indirect Probing)과 Lifeguard 자기인식·의심 타이머 스케일링

> **Primary source:** HashiCorp memberlist 소스 (`state.go`/`suspicion.go`/`awareness.go` — GitHub `hashicorp/memberlist`, 2026-09-04 WebFetch로 직접 확인)
> **Secondary:** SWIM 원 논문(Das, Gupta, Motivala, ICDCS 2002) / Lifeguard 논문(Suresh et al., ICDCN 2018) — 개념 수준 인용
> **Date:** 2026-09-04
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/swim-lifeguard-self-awareness-timeout

## 왜 봤나

- 멤버십 관리와 장애 감지를 all-to-all 하트비트로 하면 메시지 수가 O(N²)로 폭발한다. SWIM은 이를 O(1)(노드당 상수)로 낮추면서도 클러스터가 같은 뷰로 수렴하게 만드는데, "가십이 장애를 감지한다"는 식으로 감지(detection)와 전파(dissemination)를 뭉뚱그려 이해하기 쉽다.
- Consul, Serf, Nomad가 공통으로 쓰는 `hashicorp/memberlist`가 SWIM 구현체이고, Lifeguard 확장(자기인식 타임아웃 스케일링, 의심 타이머 가속)이 얹혀 있다는 사실은 잘 안 알려져 있다. 이 두 메커니즘이 무엇을 보정하는지 파본다.

## 핵심 한 문장

> SWIM은 무작위로 고른 노드에 direct ping을 보내고 실패하면 다른 k개 노드에게 "너희가 대신 확인해줘"라고 부탁하는 간접 프로빙으로 "내 네트워크만 문제"와 "저 노드가 진짜 죽음"을 구분하며, 판정 결과는 별도 메시지 없이 각 노드가 어차피 주고받는 주기적 프로브 패킷에 얹혀(piggyback) 가십으로 퍼진다.

## 내부 동작

### 1. 상태 전이

`memberlist`가 다루는 노드 상태는 `Alive`, `Suspect`, `Dead`, `Left` 4가지이고(SWIM 원 논문은 Alive/Suspect/Dead 3가지, `Left`는 구현체가 추가한 정상 이탈 상태), 각 상태는 `Incarnation`이라는 단조증가 카운터를 함께 들고 다닌다. 같은 노드에 대한 두 메시지가 충돌하면 **incarnation이 더 큰 쪽이 이긴다** — 자기 자신이 Suspect로 몰렸을 때 반박(refute)하는 방법이 incarnation을 올린 Alive 메시지를 다시 뿌리는 것이다.

```
        direct probe 성공
   ┌────────────────────────┐
   │                        ▼
 Alive ──probe 실패(간접+TCP도 실패)──▶ Suspect ──suspicion timeout 만료, 반박 없음──▶ Dead
   ▲                                    │
   └── 본인이 더 높은 incarnation의 ──────┘
        Alive 메시지를 가십으로 뿌림(반박)
```

### 2. 프로브 사이클 — direct → indirect → TCP fallback

`Memberlist.probe()`는 자기 자신을 제외한 노드 목록을 라운드로빈 인덱스(`probeIndex`)로 순회한다. 인덱스가 끝까지 가면 `resetNodes()`가 `GossipToTheDeadTime`을 넘긴 dead 노드를 제거하고 남은 노드를 셔플한 뒤 처음부터 다시 돈다 — 매 라운드 순서를 무작위화해 특정 순서·특정 노드로 프로브가 몰리는 것을 막는다.

`probeNode(node)`의 실제 흐름(`state.go`에서 직접 확인):

1. `awareness.ScaleTimeout(ProbeInterval)`로 이번 프로브 타임아웃을 정한다(§3).
2. 대상에게 UDP direct ping을 보낸다. `ackCh`로 ack가 오면 alive로 간주하고 끝.
3. 타임아웃까지 ack가 없으면 `HANDLE_REMOTE_FAILURE`로 진입해 두 가지를 **동시에** 시도한다.
   - **간접 프로빙**: `kRandomNodes(IndirectChecks, ...)`로 무작위 k개의 살아있는 노드를 골라 "너가 대신 이 노드에 ping해봐"라는 `indirectPingReq`를 보낸다. 성공하면 ack를 중계하고, 실패하면(프로토콜 v4+) nack을 보낸다.
   - **TCP fallback**: UDP는 막혔지만 TCP는 살아있는 "네트워크 반쪽 장애"를 잡기 위해 별도 고루틴으로 TCP ping도 병행한다. TCP만 성공하면 "네트워크 설정을 확인하라"는 경고를 남기고 alive로 처리한다.
4. 둘 다 실패해야 비로소 `suspectNode()`가 호출되어 Suspect로 전환된다.

즉 **"핑 한 번 실패 = 죽음"이 아니라, 최소 1(direct) + k(indirect) + 1(TCP fallback)번의 독립적인 확인이 모두 실패해야 Suspect로 넘어간다.** 간접 프로빙이 "요청자 자신의 네트워크 문제"와 "대상 노드의 실제 장애"를 구분해준다 — 요청자만 대상과 연결이 끊겼다면 다른 k개 노드 중 누군가는 성공적으로 ping해서 살아있다고 보고할 것이다.

### 3. Lifeguard 확장 ① — 자기인식(Self-Awareness)이 프로브 타임아웃을 조정

`awareness` 구조체는 `[0, max-1]` 범위로 clamp되는 정수 health score 하나만 들고 있다(`awareness.go`).

```go
func (a *awareness) ApplyDelta(delta int) {
    a.score += delta
    if a.score < 0 { a.score = 0 }
    else if a.score > (a.max - 1) { a.score = (a.max - 1) }
}

func (a *awareness) ScaleTimeout(timeout time.Duration) time.Duration {
    return timeout * (time.Duration(a.score) + 1)
}
```

프로브가 성공하면 `awarenessDelta = -1`(건강도 개선), 간접 프로빙까지 갔는데 기대한 nack 수보다 적게 받으면 그 부족분만큼 `+delta`를 적용한다. **핵심은 이 점수가 "내가 최근에 프로브에 얼마나 잘 응답받았는가"를 누적하고, 그 점수로 다음 프로브의 타임아웃을 늘린다는 것(`timeout × (score+1)`).** 노드 자신이 요즘 느리거나(GC pause, CPU 과부하 등) 네트워크가 불안정하면 스스로 "지금 건강도가 낮으니 더 관대한(긴) 기준을 쓰겠다"고 조정한다 — 없으면 바쁜 노드 하나가 정상 노드들을 잇달아 오탐(false positive) suspect로 몰아버린다. Lifeguard 논문이 지적한 원 SWIM의 약점이다.

### 4. Lifeguard 확장 ② — 의심 타이머의 로그 스케일 가속

Suspect로 전환되면 고정 타이머가 아니라 `suspicion` 구조체가 타이머를 관리한다(`suspicion.go`). 생성 시점엔 최대값 `max`로 시작하지만, 이미 Suspect로 확인한 다른 노드로부터 같은 판정("나도 쟤 죽은 것 같아")이 `Confirm()`으로 들어올 때마다 카운터 `n`이 증가하고, 다음 공식으로 남은 시간을 재계산한다.

```go
func remainingSuspicionTime(n, k int32, elapsed time.Duration, min, max time.Duration) time.Duration {
    frac := math.Log(float64(n)+1.0) / math.Log(float64(k)+1.0)
    raw := max.Seconds() - frac*(max.Seconds()-min.Seconds())
    timeout := time.Duration(math.Floor(1000.0*raw)) * time.Millisecond
    if timeout < min { timeout = min }
    return timeout - elapsed
}
```

`k`는 "이 정도 독립 확인을 받으면 최소 시간까지 줄이겠다"는 목표치다. `n=0`이면 `frac=0`이라 타임아웃은 `max` 그대로, `n=k`에 도달하면 `frac=1`이라 `min`까지 줄어든다. 로그를 쓰는 이유는 **확인이 쌓일수록 한계효용이 줄어들게** 하기 위해서다 — 첫 확인 한두 개가 가장 크게 깎고 이후로는 점점 덜 깎인다.

`k=3, min=1s, max=6s` 예:

| n(확인 수) | frac = ln(n+1)/ln(k+1) | timeout = max − frac×(max−min) |
|---|---|---|
| 0 | 0 | 6.0s |
| 1 | ln2/ln4 ≈ 0.500 | 3.5s |
| 2 | ln3/ln4 ≈ 0.793 | 2.04s |
| 3 | ln4/ln4 = 1.000 | 1.0s (min) |

첫 확인 하나만으로 6s→3.5s(2.5s 감소)로 가장 크게 깎이고, 세 번째 확인은 2.04s→1.0s(1.04s 감소)로 덜 깎이는 로그형 체감을 볼 수 있다.

### 5. 가십 전파는 감지와 분리된 채널

`gossip()`은 프로브 사이클과 별개의 티커로 돌며, 대기 중인 브로드캐스트 메시지(상태 변경 등)를 `GossipNodes`개의 무작위 노드에게 UDP 패킷으로 보낸다. 중요한 점은 이게 **새 라운드트립이 아니라 이미 나가는 프로브/ack 패킷에 얹혀서(compound message)도 함께 전달된다**는 것 — `probeNode`에서 대상이 suspect/dead 상태면 ping 메시지에 suspect 메시지를 컴파운드로 묶어 같이 보내는 코드가 그 예다. 전파와 프로빙 트래픽을 겹쳐 보내 추가 대역폭 없이 epidemic 방식(각 라운드마다 아는 노드 수가 대략 배로 늘어 O(log N) 라운드에 전체 수렴)으로 퍼진다.

가십만으로는 패킷 유실 시 일부 노드가 영영 최신 상태를 못 받을 수 있어, `pushPull()`이 주기적으로 무작위 노드 1개와 **전체 멤버 리스트를 통째로 교환**하는 안티엔트로피를 추가로 수행한다. 이 간격은 `pushPullScale`로 클러스터 크기에 비례해 늘어나(작은 클러스터는 자주, 큰 클러스터는 드물게) 대역폭 비용을 억제한다.

## 검증

이 저장소엔 실행 환경이 없으므로 다음 두 방식으로 재현·확인한다.

**(a) 직접 계산 재현**: 위 §4의 표는 `remainingSuspicionTime` 공식을 계산기(또는 JShell)에 넣어 검증할 수 있다.

```java
jshell> for (int n = 0; n <= 3; n++)
   ...>   System.out.printf("n=%d timeout=%.2fs%n", n,
   ...>     6.0 - (Math.log(n+1.0)/Math.log(4.0)) * (6.0-1.0));
```
n이 0→3으로 늘 때 timeout이 6.00 → 3.50 → 2.04 → 1.00으로 로그형으로 줄면 공식 이해가 맞다는 뜻이다.

**(b) 소스 포인터 재현**: `hashicorp/memberlist` 저장소를 클론(또는 GitHub 열람)해 `state.go`의 `probeNode`(direct→indirect→TCP fallback 순서), `suspicion.go`의 `remainingSuspicionTime`/`Confirm`, `awareness.go`의 `ScaleTimeout`/`ApplyDelta`를 읽으면 위 서술과 일치하는지 확인할 수 있다 — 이 세 파일은 이번 노트 작성 시 WebFetch로 전체 내용을 직접 읽고 인용했다.

## 잘못 알고 있던 것

- **"가십 프로토콜이 장애를 감지한다"** — 아니다. 감지(누가 죽었는지 판정)는 direct/indirect ping의 probe-ack 서브시스템이 하고, 가십은 이미 내려진 판정 결과를 확산시키는 역할만 한다. 둘은 독립 메커니즘이고, 패킷을 얹어서(piggyback) 같이 보낼 뿐이다.
- **"핑 한 번 실패하면 바로 dead 처리"** — SWIM은 direct ping 실패 시 다른 k개 노드에게 간접 확인을 요청하고(memberlist는 TCP fallback까지 추가) 그마저 실패해야 Suspect로 전환한다. Suspect도 즉시 dead가 아니라 반박(더 높은 incarnation의 Alive 메시지) 기회를 주는 타이머 기간이 있다.
- **"의심 타이머는 고정 시간이다"** — Lifeguard 확장에서는 다른 노드들의 독립적 확인(confirmation) 수가 늘수록 `log` 스케일로 짧아진다. 정말 죽은 노드는 여러 노드가 동시에 확인해줘서 빠르게 확정되고, 애매한 경우는 더 오래 기다린다.
- **"모든 노드가 같은 프로브 타임아웃을 쓴다"** — 각 노드는 자신의 최근 프로브 성공/실패 이력을 awareness 점수로 누적해 스스로의 타임아웃을 늘리거나 줄인다. 이게 없으면 일시적으로 바쁜 노드 하나가 클러스터 전체에 오탐 suspect를 연쇄적으로 퍼뜨릴 수 있다.

## 더 파고들 만한 것

- Consul처럼 SWIM류 멤버십 프로토콜과 Raft류 합의 프로토콜을 함께 쓰는 시스템에서 두 계층이 왜 분리되어야 하는지(멤버십=근사적 뷰, 합의=정확한 로그 순서).
- Serf가 memberlist 위에 얹은 Lamport 타임스탬프 기반 이벤트 코얼레싱이 가십 전파와 어떻게 상호작용하는지.

## 참고

- HashiCorp memberlist GitHub 저장소 — `state.go`, `suspicion.go`, `awareness.go`
- Das, Gupta, Motivala, "SWIM", ICDCS 2002 / Suresh et al., "Lifeguard", ICDCN 2018

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
