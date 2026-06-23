# TCP 혼잡 제어의 cwnd 상태 머신: Slow Start · Congestion Avoidance · Fast Recovery

> **Primary source:** RFC 5681 (TCP Congestion Control), RFC 6582 (NewReno Fast Recovery)
> **Secondary:** RFC 8312 (CUBIC), RFC 6298 (RTO 계산), W. Stevens, *TCP/IP Illustrated Vol.1*
> **Date:** 2026-06-23
> **Status:** draft

## 왜 봤나

- TCP handshake와 teardown 상태 머신은 정리해 뒀는데([tcp-handshake](./tcp-handshake-and-teardown-state-machine.md)), 정작 "연결이 열린 뒤 송신 속도를 무엇이 결정하는가"는 흐릿하게 알고 있었다.
- "TCP는 수신 윈도우(rwnd)만큼 보낸다"고 막연히 알고 있었는데, 실제로 송신량을 옥죄는 건 대부분 **혼잡 윈도우(cwnd)** 라는 점을 짚고 넘어가고 싶었다.

## 핵심 한 문장

> TCP 송신자는 매 순간 `min(cwnd, rwnd)` 만큼만 미확인(in-flight) 데이터를 띄울 수 있고, `cwnd`는 **ACK라는 피드백 클럭**과 **손실이라는 혼잡 신호**에 따라 Slow Start → Congestion Avoidance → Fast Recovery 네 상태를 오가며 끊임없이 조절된다.

## 내부 동작

### 핵심 변수

RFC 5681이 정의하는 세 상태 변수(단위는 바이트):

- `cwnd` (congestion window): 송신자가 ACK를 받기 전에 네트워크에 띄울 수 있는 데이터 상한. **송신자 로컬 변수**이며 패킷으로 교환되지 않는다.
- `rwnd` (receiver window): 수신자가 광고하는 버퍼 여유. TCP 헤더의 Window 필드로 전달된다.
- `ssthresh` (slow start threshold): Slow Start와 Congestion Avoidance를 가르는 경계.

실제 송신 가능량 = `min(cwnd, rwnd)`. 흔히 "TCP 흐름은 rwnd가 정한다"고 생각하지만, LAN처럼 rwnd가 넉넉한 환경에서 병목은 거의 항상 cwnd다. 흐름 제어(flow control, rwnd)와 혼잡 제어(congestion control, cwnd)는 **목적이 다른 별개의 메커니즘**이다 — 전자는 수신자 보호, 후자는 네트워크 보호.

### 상태 1: Slow Start (지수 증가)

연결 직후 또는 타임아웃 복구 후 진입한다. 초기 cwnd(IW)는 RFC 5681 기준 SMSS(최대 세그먼트 크기)에 따라 2~4 MSS, 이후 RFC 6928이 약 10 MSS로 확대했다.

규칙: **ACK 하나가 도착할 때마다 `cwnd += SMSS`**. RTT 한 번에 cwnd만큼의 세그먼트가 나가고 그만큼 ACK가 돌아오므로, RTT마다 cwnd가 대략 **2배**가 된다. 이름은 "slow"지만 증가율은 지수적이다 — 시작점이 낮을 뿐이다.

```
cwnd (MSS 단위), ACK는 모두 정상 수신 가정
RTT 0:  1  ─┐ 보내고
RTT 1:  2   │ 각 ACK마다 +1 → 지수
RTT 2:  4   │
RTT 3:  8  ─┘
...  cwnd >= ssthresh 도달 시 Congestion Avoidance로 전환
```

### 상태 2: Congestion Avoidance (선형 증가)

`cwnd >= ssthresh`가 되면 진입. 더 이상 지수로 키우면 위험하므로 **RTT당 최대 1 SMSS**만 증가시킨다(AIMD의 Additive Increase). RFC 5681이 권장하는 근사식:

```
cwnd += SMSS * SMSS / cwnd     (ACK 수신마다)
```

cwnd가 SMSS개의 세그먼트로 차 있을 때 한 RTT 동안 SMSS개의 ACK가 오고, 각 ACK가 `SMSS/cwnd`만큼 키우므로 RTT 합계가 ≈1 SMSS가 된다. Slow Start의 곱셈적 증가와 대비되는 가산적 증가다.

### 혼잡 신호와 두 가지 손실 감지

cwnd를 줄이는 트리거는 "손실"인데, 감지 경로가 둘이고 **반응 강도가 다르다**:

```
                  ┌─ RTO 만료 (심각: ACK가 아예 안 옴)
손실 감지 ───────┤      → ssthresh = max(in-flight/2, 2*SMSS)
                  │        cwnd = 1 MSS,  Slow Start로 리셋
                  │
                  └─ 3 dup ACK (경미: 뒤 세그먼트는 도착 중)
                         → Fast Retransmit + Fast Recovery
```

**왜 3개인가?** 네트워크 재정렬(reordering)로 ACK 순서가 한두 개 뒤바뀌는 건 흔하다. dup ACK 1~2개를 손실로 단정하면 멀쩡한 데이터를 불필요하게 재전송한다. RFC 5681은 임계값을 3으로 잡아 재정렬과 진짜 손실을 구분한다.

### 상태 3·4: Fast Retransmit & Fast Recovery (RFC 5681 + NewReno)

3개의 중복 ACK를 받으면 RTO를 기다리지 않고 즉시 빠진 세그먼트를 재전송(Fast Retransmit)한 뒤 Fast Recovery로 들어간다. 핵심 절차:

1. `ssthresh = max(FlightSize / 2, 2*SMSS)` — 절반으로 줄임(Multiplicative Decrease).
2. `cwnd = ssthresh + 3*SMSS` — "window inflation". 3을 더하는 건 *이미 네트워크를 빠져나가 수신자 버퍼에 도착한* 3개의 세그먼트를 회계상 반영하는 것이다.
3. 추가 dup ACK가 올 때마다 `cwnd += SMSS` (계속 inflate) — 새 데이터를 보낼 수 있으면 보낸다.
4. **재전송을 ack하는 새 ACK** 도착 시: `cwnd = ssthresh` (deflate)하고 Congestion Avoidance로 복귀.

NewReno(RFC 6582)는 한 윈도우에서 여러 세그먼트가 동시에 손실됐을 때를 보강한다. Fast Recovery 진입 시점의 최고 시퀀스 번호를 `recover`로 기록해 두고, 들어온 새 ACK가 `recover`를 다 덮지 못하는 **부분 ACK(partial ACK)** 면 Recovery를 빠져나오지 않고 다음 빠진 세그먼트를 곧장 재전송한다. 이로써 다중 손실에도 RTO로 추락하지 않고 한 RTT에 하나씩 메운다.

### 전체 상태 전이

```
        connection / RTO 후
            │ cwnd=IW, ssthresh=큰값
            ▼
       ┌──────────┐ cwnd>=ssthresh   ┌──────────────────────┐
       │SlowStart │ ───────────────▶ │ Congestion Avoidance │
       │ (지수)   │ ◀───────────────┐│       (선형)         │
       └────┬─────┘   RTO: cwnd=1   │└──────────┬───────────┘
            │ RTO            새 ACK │           │ 3 dup ACK
            │           (deflate)   │           ▼
            │                  ┌────┴───────────────┐
            └─────────────────▶│   Fast Recovery    │
                  RTO          │ (retransmit+inflate)│
                               └────────────────────┘
```

AIMD(Additive Increase / Multiplicative Decrease) — 천천히 올리고(+1/RTT), 손실엔 확 깎는다(×1/2) — 가 이 톱니파(sawtooth) cwnd 그래프의 본질이고, 다수 흐름이 병목 링크 대역폭을 공평하게 나눠 갖게 만드는 수렴 성질의 근거다.

## 검증

RFC 5681 §3.1~§3.2의 의사 규칙을 한 흐름으로 따라가 본다. SMSS=1000B, IW=1 MSS, ssthresh=64KB(=64 MSS)로 시작한다고 가정:

```
RTT0  cwnd=1   < ssthresh → SlowStart, ACK 1개 → cwnd=2
RTT1  cwnd=2   각 ACK +1 → cwnd=4
RTT2  cwnd=4              → cwnd=8
...   cwnd=64  >= ssthresh → Congestion Avoidance 진입
RTT k cwnd=64  ACK 64개, 각 +1000*1000/64000 ≈ +15.6B → RTT당 ≈+1 MSS → cwnd=65
...   여기서 3 dup ACK 발생, FlightSize=80 MSS 가정
      ssthresh = max(80/2, 2) = 40 MSS
      cwnd = 40 + 3 = 43 MSS  (Fast Retransmit + 재전송)
      새 ACK 도착 → cwnd = 40 MSS, Congestion Avoidance 재개
```

cwnd가 80→40으로 반토막 났을 뿐 1로 추락하지 않은 점이 RTO 경로(`cwnd=1`)와의 결정적 차이다. `ss -ti`(Linux)로 실 소켓의 `cwnd`, `ssthresh`, `rtt` 값을 직접 볼 수 있다.

## 잘못 알고 있던 것

- **"TCP 송신량은 수신 윈도우(rwnd)가 정한다"** — 아니다. 실제 상한은 `min(cwnd, rwnd)`이고, 대역폭이 넉넉한 환경에서 병목은 거의 cwnd다. rwnd는 수신자 버퍼 보호용 흐름 제어, cwnd는 네트워크 보호용 혼잡 제어로 목적이 다르다.
- **"Slow Start는 천천히 증가한다"** — 증가 자체는 RTT마다 2배인 지수 증가다. 시작 cwnd가 작아서 절대량이 작을 뿐, 증가율로 치면 가장 공격적인 구간이다.
- **"손실이 나면 cwnd가 항상 1로 떨어진다"** — RTO 타임아웃일 때만 1로 리셋(Slow Start)이다. 3 dup ACK로 감지되면 cwnd는 절반 수준에서 멈추고(Fast Recovery) Congestion Avoidance로 복귀한다. 손실의 *심각도*를 두 경로로 다르게 다룬다.
- **"중복 ACK 하나만 와도 재전송한다"** — 재정렬과 진짜 손실을 구분하려고 임계값이 3이다.

## 더 파고들 만한 것

- CUBIC(RFC 8312): cwnd를 RTT가 아닌 **시간**의 3차 함수로 키워 고대역폭·고지연(BDP가 큰) 링크에서 Reno의 선형 증가 한계를 넘는 방식. Linux 기본 알고리즘.
- BBR: 손실 기반이 아니라 병목 대역폭·RTT를 추정하는 모델 기반 혼잡 제어. AIMD 패러다임 자체를 벗어난다.
- SACK(RFC 2018)와 Fast Recovery의 결합: 어떤 세그먼트가 도착했는지 선택적으로 알려줘 NewReno의 "한 RTT에 하나씩 복구" 제약을 완화.

## 참고

- RFC 5681 — TCP Congestion Control (Slow Start, Congestion Avoidance, Fast Retransmit/Recovery 표준 정의)
- RFC 6582 — NewReno Modification to TCP's Fast Recovery
- RFC 6928 — Increasing TCP's Initial Window (IW10)
- RFC 8312 — CUBIC for Fast Long-Distance Networks
- W. R. Stevens, *TCP/IP Illustrated, Vol.1* — 21장 TCP Timeout & Retransmission
