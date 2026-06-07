# HTTP/2 multiplexing과 HOL blocking

> **Primary source:** RFC 9113 (HTTP/2, 2022) §4 HTTP Frames, §5 Streams and Multiplexing, §5.1 Stream States, §5.2 Flow Control, §6 Frame Definitions; RFC 7541 (HPACK)
> **Secondary:** RFC 9114 (HTTP/3) §2(QUIC 대비), RFC 9218 (Extensible Prioritization), `nghttp -v` / Chrome `chrome://net-export`
> **Date:** 2026-06-07
> **Status:** draft

## 왜 봤나

- "HTTP/2는 멀티플렉싱으로 HOL blocking을 없앴다"는 한 줄을 자주 봤는데, **무엇을 없앴고 무엇이 남았는지**가 흐릿했다. 실제로 TCP 레벨 HOL blocking은 그대로 남아 HTTP/3가 등장한 것이라, 그 경계를 프레임/스트림 수준에서 정리하고 싶었다.
- 스트림 우선순위를 "의존성 트리(dependency tree)"로 외우고 있었는데, RFC 9113에서 그게 deprecate됐다는 말을 듣고 확인이 필요했다.

## 핵심 한 문장

> HTTP/2는 하나의 TCP 연결 위에서 요청/응답을 **stream**이라는 논리 채널로 나누고 각 메시지를 작은 **frame**으로 쪼개 인터리빙(interleaving)함으로써, HTTP/1.1의 "응답을 보낸 순서대로만 받을 수 있다"는 애플리케이션 레벨 HOL blocking은 제거하지만, 모든 stream이 단일 TCP 바이트스트림을 공유하므로 **패킷 한 개의 유실이 전체 stream을 멈추는 전송 레벨 HOL blocking은 그대로 남는다**.

## 내부 동작

### 1. Frame — 멀티플렉싱의 최소 단위 (§4.1)

HTTP/2의 모든 통신은 9옥텟 고정 헤더를 가진 frame으로 이뤄진다. 핵심은 마지막 **Stream Identifier** 필드다 — 이 한 필드가 멀티플렉싱을 가능케 한다.

```
 +-----------------------------------------------+
 |                 Length (24)                   |   payload 길이
 +---------------+---------------+---------------+
 |   Type (8)    |   Flags (8)   |
 +-+-------------+---------------+-------------------------------+
 |R|                 Stream Identifier (31)                     |  ← 어느 stream 소속인가
 +=+=============================================================+
 |                   Frame Payload (0...)                      ...
 +---------------------------------------------------------------+
```

- Length는 24비트지만 기본 상한은 SETTINGS의 `SETTINGS_MAX_FRAME_SIZE`(기본 16,384옥텟). Type은 frame 종류, Stream Identifier(31비트)는 소속 stream.
- 주요 frame type(§6): `DATA(0x0)`, `HEADERS(0x1)`, `PRIORITY(0x2)`, `RST_STREAM(0x3)`, `SETTINGS(0x4)`, `PUSH_PROMISE(0x5)`, `PING(0x6)`, `GOAWAY(0x7)`, `WINDOW_UPDATE(0x8)`, `CONTINUATION(0x9)`.
- 한 연결의 바이트스트림에는 서로 다른 stream의 frame이 **순서를 섞어 흐른다**. 수신 측은 Stream Identifier로 frame을 해당 stream의 버퍼에 재조립한다. 이것이 멀티플렉싱의 전부다.

### 2. Stream과 식별자 규칙 (§5.1.1)

stream은 한 연결 안의 독립적인 양방향 frame 시퀀스다.

- **클라이언트가 시작한 stream은 홀수**, 서버가 시작한(PUSH_PROMISE) stream은 **짝수**, `0`은 연결 전체 제어용(SETTINGS, 연결 레벨 WINDOW_UPDATE 등).
- stream identifier는 **단조 증가**하며 재사용 불가. 소진되면(2^31−1) 새 연결을 맺어야 한다.
- 동시 stream 수는 `SETTINGS_MAX_CONCURRENT_STREAMS`로 상대가 제한한다.

### 3. Stream 상태 머신 (§5.1)

각 stream은 독립된 상태 기계를 가진다. HEADERS frame이 stream을 열고, END_STREAM 플래그가 한쪽 방향을 닫는다.

```
                          +--------+
                  send PP |        | recv PP
                 ,--------|  idle  |--------.
                /         |        |         \
               v          +--------+          v
        +----------+          |           +----------+
        | reserved |          | send/recv | reserved |
        | (local)  |          |  HEADERS  | (remote) |
        +----------+          v           +----------+
               |          +--------+           |
       send H  |   recv ES|        |send ES    | recv H
               |  ,-------|  open  |-------.    |
               | /        |        |        \  |
               vv         +--------+         vv
        +----------+          |           +----------+
        |half-closed|         |           |half-closed|
        | (remote) |          |送/受 ES   | (local)  |
        +----------+          v           +----------+
               \          +--------+          /
         send R \ recv R  | closed | send R  / recv R
                 `------->|        |<-------'
                          +--------+
  H=HEADERS, PP=PUSH_PROMISE, ES=END_STREAM flag, R=RST_STREAM
```

- `open`에서 한쪽이 END_STREAM을 보내면 그 방향만 닫힌 **half-closed**가 되어 나머지 방향은 계속 데이터를 흘릴 수 있다.
- `RST_STREAM`은 어느 상태에서든 즉시 `closed`로 보낸다 — **연결 전체가 아니라 그 stream만** 끊는다. HTTP/1.1에서 요청 하나를 취소하려면 연결을 끊어야 했던 것과 대비된다.

### 4. Flow control — stream을 공평하게 (§5.2)

멀티플렉싱은 한 stream이 연결을 독식하는 문제를 낳는다. HTTP/2는 **DATA frame에만** 적용되는 credit 기반 흐름 제어로 이를 막는다.

- 수신자는 stream별/연결별 **window**(받을 수 있는 바이트 수)를 광고하고, 데이터를 소비하면 `WINDOW_UPDATE` frame으로 window를 늘린다. 송신자는 두 window의 **최솟값**만큼만 보낼 수 있다.
- 초기 window는 `SETTINGS_INITIAL_WINDOW_SIZE`(기본 65,535). HEADERS/SETTINGS 등 제어 frame은 흐름 제어 대상이 아니다.

### 5. HPACK — 헤더 압축 (RFC 7541)

HTTP/1.1은 매 요청 헤더를 평문 반복 전송했다. HTTP/2는 HEADERS/CONTINUATION frame 안에서 HPACK으로 압축한다: **정적 테이블**(61개 고정 엔트리, 예: index 2 = `:method: GET`) + **동적 테이블**(연결 동안 학습) + **Huffman 코딩**. 반복 헤더는 인덱스 한 바이트로 줄어든다.

### 6. HOL blocking — 어디는 풀고 어디는 남았나

```
HTTP/1.1 (연결당 직렬):    [req1]→[resp1]  [req2]→[resp2]   응답이 순서대로만 옴
                          resp1이 느리면 resp2가 뒤에서 막힘 (애플리케이션 HOL)

HTTP/2 (멀티플렉싱):       stream1,3,5의 frame을 섞어 전송 → 애플리케이션 HOL 해소
   그러나 단일 TCP:        ...|s1|s3|[유실]|s5|...  TCP가 순서 보장 위해 s5 frame을
                          이미 받았어도 유실분 재전송까지 애플리케이션에 못 올림 → 전 stream 정지
```

- HTTP/1.1의 HOL은 "한 연결에서 응답을 보낸 순서대로만 받는다"는 **애플리케이션 레벨** 제약이었다. 멀티플렉싱이 이것을 푼다.
- 그러나 모든 stream은 **하나의 TCP 연결 = 하나의 순서 보장 바이트스트림**을 공유한다. TCP는 중간 세그먼트가 유실되면 그 뒤 바이트를 이미 받았어도 애플리케이션에 올리지 않는다(in-order delivery). 그 결과 **유실 하나가 무관한 모든 stream을 멈춘다** — 전송 레벨 HOL blocking. RFC 9114(HTTP/3)는 이를 QUIC의 stream별 독립 전송으로 해결한다.

## 검증

`nghttp -v`로 frame 단위 인터리빙과 stream id를 직접 따라갈 수 있다.

```bash
$ nghttp -v -n https://nghttp2.org/
# recv SETTINGS frame <length=..., flags=0x00, stream_id=0>   ← 연결 제어
# send HEADERS frame  <length=..., flags=0x25, stream_id=13>  ← 홀수 = 클라 시작
#   ; END_STREAM | END_HEADERS | PRIORITY
# recv HEADERS frame  <length=..., flags=0x04, stream_id=13>
# recv DATA frame     <length=..., flags=0x00, stream_id=13>
# recv WINDOW_UPDATE  <length=4, flags=0x00, stream_id=0>     ← 연결 레벨 window 회복
```

여러 리소스를 동시에 요청하면 서로 다른 `stream_id`의 DATA frame이 시간상 **섞여서** 도착하는 것이 로그에서 보인다 — 직렬이 아니라 인터리빙됨을 확인하는 지점이다.

## 잘못 알고 있던 것

- **"HTTP/2가 HOL blocking을 없앴다"** → 애플리케이션 레벨만 없앴다. 단일 TCP 위 멀티플렉싱이라 **TCP 레벨 HOL blocking은 오히려 더 아프다** — HTTP/1.1은 보통 6개 병렬 연결을 써서 한 연결의 정체가 6분의 1로 격리됐지만, HTTP/2는 한 연결에 다 몰아넣어 유실 하나가 전 stream에 퍼진다. 이게 QUIC/HTTP/3의 존재 이유다.
- **"stream 우선순위는 의존성 트리(weight/dependency)다"** → 그것은 RFC 7540의 방식이고, **RFC 9113은 그 우선순위 스킴을 deprecate**했다. PRIORITY frame과 트리 구조는 복잡하고 구현 호환이 나빠 실무에서 거의 쓰이지 않았으며, 현재는 RFC 9218의 **Extensible Priorities**(urgency/incremental, 헤더 기반)로 대체됐다.
- **"Server Push로 성능이 좋아진다"** → PUSH_PROMISE는 캐시 무효 푸시·과다 전송 문제로 실효성이 낮아 주요 브라우저(Chrome)에서 제거됐다. RFC 9113에도 남아 있지만 사실상 사장된 기능에 가깝다.

## 더 파고들 만한 것

- HTTP/3가 QUIC의 stream별 독립 재전송으로 전송 레벨 HOL blocking을 어떻게 제거하는지 (다음 백로그 항목: HTTP/3 (QUIC) 핵심 차이점 — RFC 9000).
- HPACK 동적 테이블이 압축률과 보안(CRIME류 공격) 사이에서 갖는 트레이드오프, 그리고 HTTP/3의 QPACK이 HOL blocking을 피하려 동적 테이블을 어떻게 다르게 다루는가.

## 참고

- RFC 9113 §4(frame), §5(stream/multiplexing), §5.1(상태 머신), §5.2(flow control), §6(frame 정의)
- RFC 7541 (HPACK), RFC 9218 (Extensible Priorities), RFC 9114 (HTTP/3)
- 관련 노트: `network/tls-1-3-handshake.md`, `network/tcp-handshake-and-teardown-state-machine.md`
