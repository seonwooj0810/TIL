# TCP 재전송 타임아웃(RTO) 계산: Jacobson/Karels EWMA와 Karn 알고리즘

> **Primary source:** RFC 6298 (Computing TCP's Retransmission Timer)
> **Secondary:** Jacobson, "Congestion Avoidance and Control" (SIGCOMM 1988) §2 / RFC 9293 §3.8.1 / RFC 7323 §4 (timestamp 기반 RTTM) / Karn & Partridge (SIGCOMM 1987)
> **Date:** 2026-07-23
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/tcp-rto-retransmission-timeout

## 왜 봤나

- cwnd 상태 머신([tcp-congestion-control](./tcp-congestion-control-state-machine.md))을 정리하면서 "그래서 손실을 **언제** 판정하나"가 남았다. 그 타이머가 RTO다.
- "RTO는 그냥 평균 RTT에 여유 좀 준 값" 정도로 알고 있었는데, 실제로는 **평균이 아니라 편차(variance)** 가 RTO를 지배한다는 걸 몰랐다. 그리고 재전송된 세그먼트의 ACK로는 RTT를 재면 안 된다는 함정(Karn)도.

## 핵심 한 문장

> RTO는 RTT의 지수가중이동평균(SRTT)에 그 편차의 이동평균(RTTVAR)을 4배 더한 값이며(`RTO = SRTT + 4·RTTVAR`), 편차 항이 있어야 RTT가 출렁일 때 성급한 재전송을 피한다.

## 내부 동작

### 상태 변수와 갱신 순서

TCP는 연결(정확히는 각 SRTT 추정 대상)마다 두 상태 변수를 든다.

- `SRTT` — smoothed round-trip time (RTT의 평활 추정).
- `RTTVAR` — round-trip time variation (RTT 편차의 평활 추정).

RTT 측정치 `R`이 도착할 때 갱신은 RFC 6298 §2에 못박혀 있고, **순서가 중요**하다.

```
최초 측정 R:
    SRTT    = R
    RTTVAR  = R / 2
    RTO     = SRTT + max(G, K·RTTVAR)        # K=4, G=클럭 granularity

이후 측정 R':
    RTTVAR  = (1 - beta)·RTTVAR + beta·|SRTT - R'|   # beta = 1/4, SRTT는 아직 옛값
    SRTT    = (1 - alpha)·SRTT + alpha·R'            # alpha = 1/8
    RTO     = SRTT + max(G, K·RTTVAR)
```

**RTTVAR을 먼저** 계산한다. `|SRTT − R'|`에서 쓰는 `SRTT`는 이번 라운드에 아직 갱신되지 않은 **직전 값**이어야 한다. 순서를 바꿔 SRTT를 먼저 갱신하면 편차가 과소평가된다 — 방금 R'을 반영한 SRTT는 R'에 더 가까워졌으므로 `|SRTT−R'|`가 작아진다.

`alpha=1/8`, `beta=1/4`는 EWMA의 gain이다. 값이 작을수록 과거를 오래 기억(느린 반응), 클수록 최근값에 민감. 표준이 이 상수를 고른 이유는 다음 절의 **비트 시프트** 구현 때문이다.

### 왜 편차(RTTVAR)를 더하나 — Jacobson의 핵심 통찰

1988년 이전 BSD는 `RTO = beta · SRTT` (beta≈2) 같은 **고정 배수**를 썼다. 문제는 부하가 높아 RTT 분산이 커질 때다. 평균의 상수배는 분산을 못 따라가서, 실제로는 정상인 지연을 손실로 오판 → 불필요 재전송 → 혼잡 악화(붕괴)로 이어진다.

Jacobson의 처방: RTO를 **평균 + 안전마진**으로 두되, 안전마진을 RTT **편차에 비례**시킨다. 정규 근사에서 `mean + 4·mean_deviation`은 대략 상위 극단(수 σ)을 덮으므로, RTT가 안정적이면 RTO가 SRTT 바로 위에 붙고, 출렁이면 자동으로 크게 벌어진다. `K=4`가 그 배수다.

```
RTT 안정적:  RTTVAR≈0  → RTO ≈ SRTT           (타이트, 손실 빨리 감지)
RTT 요동:    RTTVAR 큼  → RTO = SRTT + 4·RTTVAR (여유, 오판 방지)
```

### 정수 고정소수점 구현 (실제 커널 산술)

alpha·R'처럼 분수 곱을 매번 부동소수점으로 하면 느리다. Jacobson은 **스케일된 정수 + 시프트**로 짠다. SRTT를 8배(<<3), RTTVAR을 4배(<<2) 스케일로 보관하면 gain이 시프트가 된다.

```c
// err = R' - (srtt >> 3)   // 스케일 해제한 SRTT와의 오차
// srtt   += err;                   // srtt는 8·SRTT 저장 → += err 는 SRTT += err/8
// if (err < 0) err = -err;         // |err|
// err   -= (rttvar >> 2);
// rttvar += err;                   // rttvar는 4·RTTVAR 저장 → RTTVAR += (|err|-RTTVAR)/4
// rto    = (srtt >> 3) + (rttvar >> 2) << ...  // = SRTT + 4·RTTVAR
```

`beta=1/4`, `alpha=1/8`이 각각 `>>2`, `>>3`으로 떨어지는 게 상수 선택의 이유다. Linux는 여기에 `rtt_us` 마이크로초 해상도와 `tp->mdev`(mean deviation), 그리고 RTT가 급감할 때 RTTVAR이 너무 빨리 줄지 않게 하는 `mdev_max` 보정을 얹는다.

### 하한/상한 클램프

- **하한 1초(SHOULD).** `max(G, K·RTTVAR)`로 granularity는 넣어주지만, RFC 6298은 최종 RTO를 **최소 1초**로 클램프하길 권한다. LAN에서 RTT가 수백 µs여도 RTO를 sub-ms로 두면 지터·delayed ACK에 성급히 재전송하기 때문. (Linux는 `TCP_RTO_MIN`을 200ms로 두는 등 실무 튜닝이 있다 — 표준의 1초와는 다르다.)
- **상한:** 최소 60초 이상을 허용해야 한다(MAY 클램프).

### 타이머 만료와 지수 백오프

RTO 타이머가 터지면:

```
1. 가장 오래된 미확인 세그먼트 재전송
2. RTO = RTO * 2               # 지수 백오프 (Karn의 두 번째 규칙)
3. 타이머 재무장
4. (혼잡 제어 측에선 ssthresh 낮추고 slow start로)
```

백오프된 RTO는 **다음 유효 측정이 나올 때까지 유지**된다. 한 번 성공했다고 즉시 원복하지 않는다 — 반복 손실 구간에서 타이머가 다시 조급해지는 걸 막는다.

### Karn 알고리즘 — 재전송의 ACK로는 RTT를 재지 마라

세그먼트를 재전송한 뒤 ACK가 오면, 그게 **원본**에 대한 ACK인지 **재전송본**에 대한 것인지 구분할 수 없다(retransmission ambiguity). 이 ACK로 RTT를 재면:

- 원본 ACK인데 재전송 시각 기준으로 재면 → RTT를 과소평가 → RTO 붕괴.
- 재전송 ACK인데 원본 시각 기준으로 재면 → RTT를 과대평가.

Karn의 규칙: **재전송이 개입된 세그먼트의 왕복은 RTT 표본에서 제외**한다. 다만 RFC 7323 timestamp 옵션을 쓰면 각 ACK가 어느 전송을 반영하는지 echo되므로, 이 경우엔 재전송본이어도 안전하게 측정할 수 있다(Karn 예외).

```
             send S(원본)  ── t0
     재전송   send S(retx)  ── t1
                      ACK   ── t2   ← 이 ACK가 t0의 응답? t1의 응답? 모름
                                     ⇒ Karn: 이 왕복은 SRTT에 넣지 않음
```

## 검증

RFC 6298 §2의 산술을 직접 밟아본다. `alpha=1/8, beta=1/4, K=4`, 첫 측정 `R=100ms`, 이후 계속 `R'=100ms`로 안정적이라 가정.

```
초기:   SRTT=100,  RTTVAR=50,   RTO=100+4·50 = 300ms
R'=100: RTTVAR=(3/4)·50 + (1/4)·|100-100| = 37.5
        SRTT  =(7/8)·100 + (1/8)·100        = 100
        RTO   =100 + 4·37.5 = 250ms
R'=100: RTTVAR=(3/4)·37.5 + 0 = 28.125
        SRTT  =100
        RTO   =100 + 4·28.125 = 212.5ms  → (1s 하한 적용 시 1000ms로 클램프)
```

RTT가 일정하면 RTTVAR이 매 라운드 3/4로 기하 감쇠 → RTO가 SRTT(100ms)로 수렴한다. 이제 한 번 `R'=300ms`로 튀면:

```
        RTTVAR=(3/4)·28.125 + (1/4)·|100-300| = 21.09 + 50 = 71.09
        SRTT  =(7/8)·100 + (1/8)·300 = 125
        RTO   =125 + 4·71.09 = 409ms
```

편차 항이 즉시 커져 RTO가 뛴다. **SRTT는 125로 조금 움직였는데 RTO는 250→409로 크게 벌어진다** — 마진을 지배하는 건 평균이 아니라 편차라는 걸 산술이 보여준다. (1초 하한을 적용하는 표준 구현에선 위 값들이 전부 1000ms로 눌리지만, 하한을 낮춘 LAN 튜닝에선 이 상대 변화가 그대로 드러난다.)

## 잘못 알고 있던 것

- **"RTO ≈ 평균 RTT × 상수."** 아니다. `RTO = SRTT + 4·RTTVAR`이고, 지배 항은 **편차**다. 고정 배수(`beta·SRTT`)는 1988년 이전 방식이고, RTT 분산이 커지는 혼잡 상황에서 오판 재전송을 유발해 혼잡 붕괴로 이어진 원인이었다. 편차 항의 도입이 Jacobson의 핵심 기여다.
- **"모든 ACK로 RTT를 측정한다."** Karn 알고리즘 때문에 **재전송이 낀 왕복은 표본에서 뺀다**. 안 그러면 재전송 모호성으로 SRTT가 오염된다. timestamp 옵션(RFC 7323)이 있을 때만 예외적으로 잰다.
- **"갱신은 SRTT 먼저, 그다음 RTTVAR."** 반대다. RTTVAR을 **먼저** 계산해야 한다. `|SRTT−R'|`의 SRTT가 옛값이어야 편차가 제대로 잡힌다.
- **"RTO 백오프는 성공 ACK 한 번이면 원복된다."** 지수 백오프로 두 배가 된 RTO는 **다음 유효 RTT 측정이 나올 때까지** 유지된다. 즉시 되돌리지 않는다.
- **"RTO와 cwnd/fast retransmit은 같은 손실 감지."** RTO는 **타이머 기반**(ACK가 아예 안 옴)이고, fast retransmit은 **3 duplicate ACK 기반**이다. RTO 만료는 훨씬 보수적인 최후의 방어선이라 slow start로 되돌아가는 강한 페널티를 동반한다.

## 더 파고들 만한 것

- **F-RTO / spurious timeout 감지**(RFC 5682): RTO가 오발동했을 때(실은 지연이었을 때) cwnd를 불필요하게 죽이지 않고 회복하는 알고리즘.
- **RACK-TLP**(RFC 8985): 시간 기반 손실 감지로 RTO/dupACK 카운팅을 대체해가는 현대 Linux 기본 손실 감지기.

## 참고

- RFC 6298 — Computing TCP's Retransmission Timer (§2 알고리즘, §5 하한/백오프)
- Jacobson, Congestion Avoidance and Control, SIGCOMM 1988 (§2, Appendix A 정수 구현)
- Karn & Partridge, Improving Round-Trip Time Estimates in Reliable Transport Protocols, SIGCOMM 1987
- RFC 7323 §4 — Timestamps 옵션 기반 RTTM (Karn 예외)
- RFC 9293 §3.8.1 — RTO 관련 통합 규정
