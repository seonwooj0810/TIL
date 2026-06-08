# HTTP/3 (QUIC) 핵심 차이점

> **Primary source:** RFC 9000 (QUIC: A UDP-Based Multiplexed and Secure Transport)
> **Secondary:** RFC 9114 (HTTP/3), RFC 9001 (Using TLS to Secure QUIC), RFC 9113 (HTTP/2)
> **Date:** 2026-06-08
> **Status:** draft

## 왜 봤나

- 앞 노트([HTTP/2 multiplexing과 HOL blocking](./http2-multiplexing.md))에서 "HTTP/2는 애플리케이션 레이어 HOL은 풀었지만 TCP 레이어 HOL은 남았다"로 끝냈다. 그걸 어떻게 푸는지가 QUIC다.
- "HTTP/3 = HTTP/2를 UDP 위에 올린 것" 정도로만 알고 있었는데, 실제로는 전송 계층 자체를 새로 정의한 것이라 그 경계를 정리하고 싶었다.

## 핵심 한 문장

> QUIC는 UDP 위에서 **스트림 단위로 독립적인 신뢰성·흐름제어**를 제공하고 TLS 1.3을 전송 핸드셰이크에 통합한 전송 프로토콜이며, HTTP/3는 그 위에 HTTP 시맨틱을 매핑한 것이다 — 결과적으로 TCP의 단일 바이트스트림이 만들던 전송 계층 HOL blocking이 제거된다.

## 내부 동작

### 1. 레이어 비교

```
        HTTP/2                         HTTP/3
   +----------------+            +------------------+
   |  HTTP/2 frames |            |  HTTP/3 frames   |
   +----------------+            +------------------+
   |    TLS 1.2/1.3 |            |  QUIC (streams,  |
   +----------------+            |  TLS1.3 내장,    |
   |      TCP       |            |  loss recovery)  |
   +----------------+            +------------------+
   |      IP        |            |       UDP        |
   +----------------+            +------------------+
                                 |       IP         |
                                 +------------------+
```

HTTP/2는 TLS·TCP가 별개 계층이라 핸드셰이크가 직렬(TCP 3-way → TLS)로 쌓인다. QUIC는 RFC 9001에 따라 TLS 1.3 핸드셰이크를 자신의 CRYPTO 프레임으로 실어 전송 핸드셰이크와 합친다.

### 2. 스트림: 전송 계층 HOL blocking 제거

RFC 9000 §2에 따르면 QUIC 연결은 **여러 개의 독립적인 스트림**을 가지며, 각 스트림은 자체 시퀀싱·흐름제어를 갖는다. TCP는 연결 전체가 단일 바이트스트림이라 패킷 하나가 유실되면 그 뒤 모든 바이트가 수신 버퍼에서 대기한다(전송 계층 HOL). QUIC는 스트림별로 신뢰성을 보장하므로, 스트림 A의 패킷 유실이 스트림 B의 전달을 막지 않는다.

스트림 ID는 62비트 정수이며 하위 2비트가 종류를 인코딩한다(§2.1):

| 2 LSB | 종류 |
| --- | --- |
| 0x00 | Client-initiated, bidirectional |
| 0x01 | Server-initiated, bidirectional |
| 0x02 | Client-initiated, unidirectional |
| 0x03 | Server-initiated, unidirectional |

스트림은 송신·수신 방향 각각 상태 머신을 가진다. 송신 측 단순화하면:

```
Ready ──(첫 STREAM 프레임 전송)──▶ Send
  └─(RESET_STREAM)─┐                 │
                   ▼                 ▼ (FIN 비트 전송)
              Reset Sent      Data Sent ──(전부 ACK)──▶ Data Recvd
```

### 3. 패킷 번호 공간 — 재전송 모호성 제거

TCP는 재전송 시 같은 시퀀스 번호를 재사용해서 ACK가 원본인지 재전송분인지 구분이 안 되는 "retransmission ambiguity"가 있다. RFC 9000 §13.2.1에 따르면 QUIC 패킷 번호는 **단조 증가**하며 재전송 시에도 새 번호를 쓴다. 유실된 데이터는 "패킷"이 아니라 그 안의 **프레임**을 새 패킷에 다시 실어 보낸다. 따라서 RTT 측정이 정확해진다.

패킷 번호는 단일 공간이 아니라 세 개의 **번호 공간**(Initial / Handshake / Application Data)으로 분리된다(§12.3). 핸드셰이크 패킷 유실이 데이터 패킷 ACK 처리에 섞이지 않게 한다.

### 4. Connection ID와 연결 마이그레이션

TCP 연결은 4-tuple(src IP:port, dst IP:port)로 식별돼서 클라이언트 IP가 바뀌면(Wi-Fi→LTE) 연결이 끊긴다. QUIC는 §5.1의 **Connection ID**로 식별하므로 4-tuple이 바뀌어도 연결이 유지된다. NAT rebinding이나 네트워크 전환에서 핸드셰이크를 다시 할 필요가 없다.

### 5. 패킷·프레임 구조

QUIC 패킷은 Long Header(핸드셰이크용)와 Short Header(1-RTT 데이터용)로 나뉜다(§17). 페이로드는 여러 **프레임**으로 구성되며 주요 타입(§19):

- `STREAM`: 스트림 데이터 (offset + length + data)
- `ACK`: 수신한 패킷 번호 범위 (TCP SACK보다 표현력 높음)
- `CRYPTO`: TLS 핸드셰이크 메시지
- `MAX_DATA` / `MAX_STREAM_DATA`: 흐름제어 윈도우 갱신
- `NEW_CONNECTION_ID`, `PATH_CHALLENGE`: 마이그레이션용

## 검증

RFC 9000 본문 흐름을 따라가며 "HOL이 왜 풀리는가"를 추적:

1. §2.2 "데이터를 STREAM 프레임으로 보내고, 손실되면 다시 STREAM 프레임으로 보낸다."
2. §2.3 "한 스트림에서의 손실 처리가 다른 스트림 진행을 막지 않아야 한다(MUST NOT)."
3. §13.2.1 패킷 번호 단조 증가 → 어떤 패킷이 유실됐는지 ACK로 명확히 식별.

즉 "스트림별 독립 신뢰성 + 패킷 번호 비재사용"이 결합돼 전송 계층 HOL이 사라지는 구조다.

curl로 직접 확인 (HTTP/3 지원 빌드 필요):

```bash
curl --http3 -sI https://cloudflare-quic.com/ | head -1
# HTTP/3 200  → ALPN "h3"로 협상되어 UDP/443 위에서 응답
```

## 잘못 알고 있던 것

- **"HTTP/3는 HTTP/2를 UDP에 올린 것"** → 아니다. HTTP/3(RFC 9114)는 *애플리케이션 매핑*일 뿐이고, 멀티플렉싱·신뢰성·흐름제어 같은 핵심은 전송 프로토콜인 QUIC(RFC 9000)가 담당한다. HTTP/2의 스트림 개념이 QUIC 스트림으로 *내려간* 것이라 HTTP/3 프레임 레이어에는 더 이상 자체 스트림 다중화가 없다.
- **"QUIC는 그냥 빠른 UDP"** → UDP는 비신뢰 전송이고, QUIC는 그 위에 손실 복구·혼잡 제어·순서 보장을 *스트림 단위로* 다시 구현한 신뢰성 전송이다.
- **"HPACK을 그대로 쓴다"** → HTTP/2의 HPACK은 순서 의존성 때문에 HOL을 유발할 수 있어, HTTP/3는 QPACK(RFC 9204)으로 교체했다.

## 더 파고들 만한 것

- QPACK: 동적 테이블 동기화를 위한 인코더/디코더 스트림 분리 메커니즘.
- QUIC 혼잡 제어(RFC 9002) — TCP NewReno 매핑과 패킷 번호 공간별 loss detection.

## 참고

- RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport (§2 Streams, §5 Connections, §12~13 Packets, §17~19 Frames)
- RFC 9114 — HTTP/3
- RFC 9001 — Using TLS to Secure QUIC
- [HTTP/2 multiplexing과 HOL blocking](./http2-multiplexing.md)
