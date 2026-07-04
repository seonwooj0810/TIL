# Nagle 알고리즘과 delayed ACK: 두 최적화가 겹칠 때 생기는 40ms 지연

> **Primary source:** RFC 896 (Congestion Control in IP/TCP, Nagle 1984) · RFC 1122 §4.2.3.2 (Host Requirements — delayed ACK) · RFC 9293 §3.7.4 (TCP, "Silly Window Syndrome Avoidance")
> **Secondary:** Linux 커널 `tcp_output.c`의 `tcp_nagle_check`, `TCP_NODELAY`/`TCP_QUICKACK` socket option man page
> **Date:** 2026-07-04
> **Status:** draft

## 왜 봤나

- "small write가 느리다"는 얘기를 들으면 반사적으로 Nagle을 꺼라(`TCP_NODELAY`)고 하는데, **왜** 느려지는지 — 즉 Nagle 단독이 아니라 delayed ACK와 **맞물릴 때만** 40ms가 튀는 이유를 끝까지 따라가 본 적이 없었다.
- "Nagle은 작은 패킷을 버퍼링해서 지연을 준다"고만 알고 있었는데, 정확히 어떤 조건에서 送信을 멈추는지 상태 조건을 몰랐다.

## 핵심 한 문장

> Nagle은 "아직 ACK 안 온 작은 세그먼트가 있으면 새 작은 데이터를 보내지 말고 모아라", delayed ACK는 "ACK를 최대 ~40–200ms 미뤄 piggyback하라" — 각자는 합리적이지만, **송신자는 ACK를 기다리고 수신자는 데이터를 기다리는** 교착이 겹치면서 한 번의 작은 write가 delayed ACK 타이머만큼 통째로 지연된다.

## 내부 동작

### Nagle 알고리즘의 판정 조건 (RFC 896)

Nagle의 규칙은 단순하다. **송신 대기 중(un-ACKed)인 데이터가 있고**, 지금 보내려는 데이터가 **full-sized segment(MSS)보다 작으면** 보내지 않고 버퍼에 모은다. 다음 중 하나가 되면 그때 flush 한다.

1. 모인 데이터가 MSS를 채워 full segment가 되거나,
2. 아직 안 보낸 이전 데이터에 대한 **ACK가 도착**하거나(→ "in-flight 작은 세그먼트 없음" 상태 복귀),
3. (Linux) `TCP_NODELAY`가 켜져 있거나, push/urgent 등 예외 조건.

의사코드로 표현하면(Linux `tcp_nagle_check` 취지):

```
can_send_now(seg):
    if seg.len >= MSS:            return true      # full segment는 항상 즉시
    if nodelay:                   return true      # TCP_NODELAY
    if no_unacked_data_in_flight: return true      # in-flight 작은 조각 없음
    return false                                   # 그 외 → 모은다(hold)
```

핵심은 **"in-flight인 작은 세그먼트가 딱 하나로 제한된다"** 는 것. 네트워크에 항상 최대 한 개의 미완성 작은 패킷만 떠 있게 해서, RTT가 길어도 tinygram(작은 패킷)이 폭주하지 않게 한다. 그래서 Nagle은 self-clocking(ACK가 clock 역할) 이다 — 전송 속도가 결국 RTT에 묶인다. RFC 896이 풀려던 원 문제는 텔넷 같은 대화형 세션에서 키 한 글자(1B payload + 40B 헤더)마다 패킷이 나가 헤더 오버헤드가 40배가 되고, 느린 WAN에서 이 tinygram이 큐에 쌓여 혼잡을 악화시키던 상황이다. Nagle은 이를 "ACK가 돌아올 때까지 모으기"로 자연스럽게 배치(coalescing)한다.

Linux에는 여기에 더해 **Minshall 변형**(`tcp_minshall_check`)이 있다. 원래 Nagle은 "un-ACKed 데이터가 있으면"으로 판정하지만, Minshall은 "마지막으로 보낸 것이 **작은 세그먼트**였는지"로 좁혀, full-sized 전송이 진행 중일 때 뒤따르는 작은 write가 불필요하게 막히지 않게 한다.

### delayed ACK (RFC 1122 §4.2.3.2)

수신 측은 데이터를 받을 때마다 즉시 ACK를 쏘면 순수 ACK 패킷(헤더만 40B)이 낭비다. 그래서:

- ACK를 최대 **500ms를 넘지 않게** 지연하되(RFC 상한), 실제 구현은 보통 **40ms(Linux)~200ms** 타이머,
- **full-sized segment 2개를 받으면** 지연 없이 즉시 ACK(“ack every second segment”),
- 회신할 응답 데이터가 있으면 그 데이터에 ACK를 **piggyback**.

즉 수신자는 "곧 응답 데이터나 두 번째 세그먼트가 오겠지" 하고 ACK를 잠깐 쥐고 있는다.

### 두 최적화가 만드는 교착 (request/response 패턴)

문제는 애플리케이션이 한 요청을 **여러 번의 작은 write**로 쪼갤 때 터진다. 대표적으로 헤더 write + body write처럼 두 조각을 연달아 보내고 응답을 기다리는 경우:

```
Sender(A, Nagle ON)                 Receiver(B, delayed ACK ON)
 write#1(작은 seg) ──────────────▶  받음. full seg 2개 아님 → ACK 보류(타이머 시작)
 write#2(작은 seg)
   └ Nagle: in-flight 미완 seg(#1) 있음 & <MSS → HOLD (전송 안 함)
   ...                              ...ACK 아직 안 옴 → A는 계속 대기...
   ▼ (아무 일도 안 일어남)          ▼ delayed ACK 타이머 만료(~40ms)
                        ◀────────── ACK(#1) 뒤늦게 전송
 ACK 수신 → in-flight 비었으니
 write#2 이제서야 flush ───────────▶ 받고 응답 처리
```

A는 ACK를 기다리느라 write#2를 못 보내고, B는 두 번째 세그먼트(=write#2)가 와야 즉시 ACK할 텐데 그게 안 오니 타이머 만료까지 ACK를 안 준다. **서로가 서로를 기다리는** 이 데드락이 매 요청마다 delayed ACK 타이머(~40ms) 를 통째로 물게 한다. throughput이 아니라 **latency**가 죽는 것이 특징 — 대역폭은 남는데 요청당 40ms가 규칙적으로 찍힌다.

### 상태로 정리

| 송신 write 개수 | Nagle 상태 | delayed ACK | 결과 |
| --- | --- | --- | --- |
| 한 번에 큰 write 1개(≥MSS) | 즉시 전송 | 곧 응답에 piggyback | 정상 |
| 작은 write 1개 후 응답 대기 | in-flight 없음→즉시 | 타이머 만료 후 ACK, 하지만 응답이 곧 옴 | 대부분 OK |
| **작은 write 2개+ 연속** | #2 HOLD | #1에 대한 ACK 지연 | **40ms 스파이크** |

## 검증

Nagle 판정은 Linux 소스에서 직접 확인된다. `net/ipv4/tcp_output.c`의 `tcp_nagle_check()`는 대략 "세그먼트가 MSS 미만이고(nonagle 아님), in-flight(`tp->packets_out`)가 있으면 참(=보내지 마라)"을 반환한다. 즉 위 의사코드의 (2)(3) 조건이 그대로 코드에 있다.

동작 재현 흐름(개념): 클라이언트가 `TCP_NODELAY` 없이 헤더/바디를 두 번 write 하고 서버 응답을 기다리는 루프를 돌리면, `tcpdump`상 각 요청 사이에 ~40ms 간격이 규칙적으로 찍힌다. `setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, 1)`로 Nagle을 끄면 write#2가 즉시 나가 간격이 사라진다.

```c
// 해법 1: 송신자 — 작은 세그먼트를 모으지 말고 즉시 flush
int one = 1;
setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

// 해법 2(리눅스) : 수신자 — 다음 ACK를 지연 없이
setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one)); // 1회성, 재설정 필요

// 해법 3(가장 근본) : write를 한 번에 (writev/버퍼링) — 조각내지 않기
```

가장 견고한 해법은 **애플리케이션이 논리적 메시지를 한 번의 write(또는 `writev`)로 보내는 것**이다. Nagle을 끄는 건 증상 치료에 가깝고, 조각 write를 없애면 Nagle이 켜져 있어도 교착이 안 생긴다.

## 잘못 알고 있던 것

- **"Nagle이 느림의 원인이다"** → 반만 맞다. Nagle **단독**으로는 in-flight ACK가 돌아오는 순간 바로 flush하므로 심각한 지연이 없다. 문제는 **delayed ACK와 겹칠 때**만 생기는 상호작용 버그다. 그래서 한쪽만 꺼도(NODELAY 또는 QUICKACK) 대부분 해소된다.
- **"작은 write 한 번이면 무조건 40ms 걸린다"** → 아니다. 교착은 **미완 세그먼트가 있는데 또 작은 세그먼트를 보내려 할 때(연속 조각 write)** 성립한다. write 한 번 후 곧장 응답을 받는 패턴은 대개 정상이다.
- **"delayed ACK는 항상 200ms"** → 구현마다 다르다. Linux는 기본 ~40ms(`TCP_DELACK_MIN`), RFC 1122 상한이 500ms일 뿐 실제 값은 훨씬 짧고 동적으로 조정된다.

## 더 파고들 만한 것

- TCP **Silly Window Syndrome** 회피(RFC 9293 §3.7.4) — Nagle과 동전의 양면인 수신 측 작은-윈도우 광고 억제.
- Linux의 delayed ACK 동적화(quick ACK 모드 진입/이탈, `tcp_incr_quickack`)와 ACK compression.

## 참고

- RFC 896 — John Nagle, "Congestion Control in IP/TCP Internetworks" (tinygram 문제 정의).
- RFC 1122 §4.2.3.2 — delayed ACK 규칙과 500ms 상한.
- RFC 9293 §3.7.4 — Nagle/SWS avoidance의 현대 통합 기술.
- Linux `net/ipv4/tcp_output.c` — `tcp_nagle_check`, `tcp_minshall_check`.
