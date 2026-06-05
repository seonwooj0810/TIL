# TCP 연결 수립·종료 상태 머신 (3-way / 4-way)

> **Primary source:** RFC 9293 (Transmission Control Protocol, 2022) §3.3.2 State Machine Overview, §3.5 Establishing a Connection, §3.6 Closing a Connection, §3.4.1 ISN Selection
> **Secondary:** RFC 6528 (Defending Against Sequence Number Attacks), `ss`/`netstat` 상태 출력
> **Date:** 2026-06-05
> **Status:** draft

## 왜 봤나

- 서버에 `TIME-WAIT` 소켓이 수만 개 쌓이고 `CLOSE-WAIT`이 안 줄어드는 현상을 보고, "이 상태들이 정확히 어느 전이에서 생기는가"를 상태 머신 수준에서 다시 정리하고 싶었다.
- "3-way / 4-way"를 패킷 개수로만 외우고 있었지, **어느 쪽이 어떤 상태로 가는지**는 흐릿했다.

## 핵심 한 문장

> TCP 연결은 11개 상태를 갖는 유한 상태 머신이며, 수립은 SYN·SYN+ACK·ACK 3개 세그먼트로 양쪽을 `ESTABLISHED`로 올리고, 종료는 각 방향(half-duplex)을 따로 닫는 FIN/ACK 교환이라 보통 4개 세그먼트가 오가며 능동 종료 측만 `TIME-WAIT`을 거친다.

## 내부 동작

### 1. 상태 집합

RFC 9293 §3.3.2가 정의하는 상태는 11개다. `CLOSED`는 실제 TCB(Transmission Control Block)가 없는 가상 상태다.

| 상태 | 의미 | 어느 쪽 |
| --- | --- | --- |
| LISTEN | passive OPEN, SYN 대기 | 서버 |
| SYN-SENT | SYN 보내고 SYN+ACK 대기 | 능동 측 |
| SYN-RECEIVED | SYN 받고 SYN+ACK 보낸 뒤 ACK 대기 | 수동 측 |
| ESTABLISHED | 데이터 송수신 가능 | 양쪽 |
| FIN-WAIT-1 | 내 FIN 보냄, ACK/FIN 대기 | 능동 종료 |
| FIN-WAIT-2 | 내 FIN이 ACK됨, 상대 FIN 대기 | 능동 종료 |
| CLOSE-WAIT | 상대 FIN 받음, **내 close() 대기** | 수동 종료 |
| CLOSING | 동시 종료 — 서로 FIN, 내 FIN ACK 대기 | 양쪽 |
| LAST-ACK | 내 FIN 보냄, 마지막 ACK 대기 | 수동 종료 |
| TIME-WAIT | 마지막 ACK 보냄, 2·MSL 대기 | 능동 종료 |
| CLOSED | 연결 없음 | — |

### 2. 3-way handshake (§3.5)

핵심 원리: **SYN과 FIN은 각각 시퀀스 번호 1을 소비**한다(데이터가 없어도 1바이트처럼 취급). 그래서 SYN(seq=x)에 대한 ACK는 `ack=x+1`이다. RFC 9293 Figure 6의 흐름:

```
   Peer A (active)                                  Peer B (passive)
1. CLOSED                                           LISTEN
2. SYN-SENT    --> <SEQ=100><CTL=SYN>            --> SYN-RECEIVED
3. ESTABLISHED <-- <SEQ=300><ACK=101><SYN,ACK>   <-- SYN-RECEIVED
4. ESTABLISHED --> <SEQ=101><ACK=301><ACK>        --> ESTABLISHED
```

- A: `connect()` → SYN 송신, `CLOSED→SYN-SENT`.
- B: SYN 수신 → SYN+ACK 송신, `LISTEN→SYN-RECEIVED`.
- A: SYN+ACK 수신 → ACK 송신, `SYN-SENT→ESTABLISHED`.
- B: ACK 수신 → `SYN-RECEIVED→ESTABLISHED`.

왜 2-way가 아니라 3-way인가: 양방향 각각에 대해 **ISN을 교환하고 그 ISN이 상대에게 도달했음을 확인**해야 한다. A→B 방향은 1·2단계로, B→A 방향은 2·3단계로 확정된다. 2단계만으로는 B의 ISN이 A에게 받아들여졌다는 보장이 없다.

ISN은 0부터 시작하지 않는다. §3.4.1과 RFC 6528에 따르면 `ISN = M + F(localIP, localPort, remoteIP, remotePort, secretkey)`로, `M`은 약 4µs마다 증가하는 32비트 타이머(약 4.55시간마다 wrap), `F`는 비밀키 해시다. 단조 증가 타이머는 같은 4-튜플의 **과거 연결 잔존 세그먼트**와 시퀀스 공간이 겹치는 것을 줄이고, 해시 항은 off-path 공격자가 ISN을 추측해 위조 세그먼트를 끼워 넣는 것을 막는다.

#### 동시 OPEN

양쪽이 동시에 active OPEN하면(드뭄) 서로 SYN을 보내고 `SYN-SENT→SYN-RECEIVED→ESTABLISHED`로 수렴한다. RFC 9293 Figure 7. LISTEN 없이도 연결이 선다.

### 3. 4-way termination (§3.6)

TCP는 full-duplex라 **방향마다 독립적으로 닫는다**. 한쪽이 FIN을 보내면 그 방향만 닫히고(half-close), 반대 방향은 살아 있어 데이터를 더 보낼 수 있다. RFC 9293 Figure 12(능동 측 A가 먼저 닫는 경우):

```
   Peer A (active close)                            Peer B (passive close)
1. ESTABLISHED                                      ESTABLISHED
2. (close) FIN-WAIT-1 --> <SEQ=100><FIN,ACK>     --> CLOSE-WAIT
3.         FIN-WAIT-2 <-- <SEQ=300><ACK=101><ACK> <-- CLOSE-WAIT
4.                                          (close)
           TIME-WAIT  <-- <SEQ=300><FIN,ACK>     <-- LAST-ACK
5.         TIME-WAIT  --> <SEQ=101><ACK=301><ACK> --> CLOSED
6. (2·MSL) CLOSED
```

- 2번에서 B는 ACK만 먼저 보내고 `ESTABLISHED→CLOSE-WAIT`. **여기서 B의 애플리케이션이 아직 살아 있다.** B가 `close()`를 호출해야 비로소 4번 FIN이 나간다. 그 사이 B는 A에게 데이터를 더 보낼 수 있다.
- 그래서 세그먼트가 4개로 보이지만, 2·3번을 한 세그먼트로 합치면(즉 B가 받자마자 닫으면) **3개로 줄 수도 있다**. "항상 4번"은 아니다.

#### 동시 종료

양쪽이 거의 동시에 FIN을 보내면 `FIN-WAIT-1`에서 ACK 대신 상대 FIN을 받아 `CLOSING`으로 가고, 서로의 ACK를 받으면 `TIME-WAIT`으로 간다(Figure 13).

### 4. TIME-WAIT과 2·MSL

능동 종료 측만 `TIME-WAIT`에 들어가 **2·MSL** 동안 머문다. MSL(Maximum Segment Lifetime)은 §3.4.2에서 기본 2분으로 권고되어 2·MSL = 4분이지만, 리눅스 등은 보통 30~60초의 고정값(`TCP_TIMEWAIT_LEN`)을 쓴다고 알려져 있다. 목적은 두 가지다.

1. **마지막 ACK의 신뢰성 있는 전달**: 5번 ACK가 유실되면 상대(`LAST-ACK`)는 FIN을 재전송한다. 내가 이미 `CLOSED`였다면 RST로 응답해 상대가 오류로 닫게 된다. `TIME-WAIT`에 머물러 있어야 재전송된 FIN에 ACK를 다시 보내고 타이머를 리셋할 수 있다.
2. **이전 연결의 지연 세그먼트 소멸 대기**: 같은 4-튜플로 새 연결(incarnation)이 서면, 네트워크에 떠돌던 이전 연결의 늦은 세그먼트가 새 연결에 섞일 수 있다. 2·MSL은 그런 세그먼트가 만료되기를 보장한다.

## 검증

`ss`로 상태 전이를 직접 관찰할 수 있다. 능동/수동 종료 측에서 보이는 상태가 다른 것이 핵심.

```bash
# 서버를 띄우고 클라이언트가 먼저 끊으면(능동 종료) 클라이언트 쪽:
$ ss -tan | grep 8080
TIME-WAIT 0 0 127.0.0.1:54321 127.0.0.1:8080   # 능동 종료 측 = TIME-WAIT

# 반대로 서버가 close()를 안 하면 서버 쪽에 CLOSE-WAIT이 쌓인다:
$ ss -tan state close-wait
# → 애플리케이션이 close()를 호출 안 한 누수 신호
```

3-way 흐름은 `tcpdump`의 플래그로 확인된다: `[S]`(SYN) → `[S.]`(SYN+ACK) → `[.]`(ACK). 종료는 `[F.]`(FIN+ACK) 교환으로 나타난다. SYN 패킷의 `seq`와 다음 ACK의 `ack` 차이가 정확히 1인 것에서 "SYN이 시퀀스 1 소비"를 눈으로 볼 수 있다.

## 잘못 알고 있던 것

- **"종료는 항상 정확히 4개 세그먼트"** → half-close 때문에 보통 4개지만, 수동 측이 받은 즉시 닫으면 ACK와 FIN이 합쳐져 3개가 될 수 있다. 반대로 동시 종료는 경로가 다르다(`CLOSING` 경유).
- **"TIME-WAIT은 양쪽에 생긴다"** → **먼저 닫은(능동 종료) 쪽만** 거친다. 수동 측은 `CLOSE-WAIT→LAST-ACK→CLOSED`로 `TIME-WAIT` 없이 끝난다.
- **"CLOSE-WAIT은 곧 사라진다"** → 아니다. `CLOSE-WAIT`은 **내 애플리케이션이 `close()`를 호출해야** 벗어난다. 쌓여 있으면 거의 항상 코드가 소켓을 안 닫는 버그다.
- **"ISN은 0이나 랜덤"** → 시간 기반 단조 증가 타이머 + 비밀키 해시(RFC 6528). 순수 랜덤이 아니라 과거 세그먼트 회피와 추측 방어를 동시에 노린 설계다.

## 더 파고들 만한 것

- `TIME-WAIT` 재사용: `SO_REUSEADDR` / 리눅스 `tcp_tw_reuse`가 어떤 조건(타임스탬프 기반)에서 안전하게 재사용을 허용하는가.
- SYN flood와 SYN cookie: `SYN-RECEIVED` 상태(half-open) 큐 고갈을 TCB 없이 방어하는 메커니즘.

## 참고

- RFC 9293 §3.3.2(상태 머신), §3.4.1(ISN), §3.5(수립), §3.6(종료)
- RFC 6528 (ISN 생성과 시퀀스 번호 공격 방어)
- 관련 노트(예정): `network/tls-1.3-handshake.md`, `network/http2-multiplexing.md`
