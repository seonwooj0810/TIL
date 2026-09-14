# HTTP/2 흐름 제어: WINDOW_UPDATE 크레딧과 스트림·커넥션 이중 윈도우

> **Primary source:** RFC 9113 §5.2(Flow Control), §5.2.1~5.2.3, §6.9(WINDOW_UPDATE)~§6.9.3
> **Secondary:** 없음
> **Date:** 2026-09-14
> **Status:** draft

## 왜 봤나

- HTTP/2는 하나의 TCP 커넥션 위에서 여러 스트림을 멀티플렉싱한다. 이 저장소의 [멀티플렉싱 노트](./http2-multiplexing.md)와 [HPACK 노트](./http2-hpack-header-compression.md)는 "어떻게 여러 스트림을 한 커넥션에 섞어 보내는가"를 다뤘지만, "한 스트림이 버퍼를 독점해 다른 스트림을 굶기는 문제"는 별도 메커니즘으로 풀어야 한다.
- 흔한 혼동: "TCP 자체가 흐름 제어를 하니 HTTP/2는 멀티플렉싱만 신경 쓰면 된다"는 생각이다. 그러나 TCP의 흐름 제어는 **커넥션 전체**에 대해서만 작동하고, 그 커넥션 안에서 스트림 단위로 대역폭을 배분하는 것은 TCP가 알 수 없는 상위 계층의 일이다. HTTP/2가 자체 흐름 제어 계층을 다시 정의하는 이유가 바로 여기 있다.

## 핵심 한 문장

> HTTP/2 흐름 제어는 수신자가 `WINDOW_UPDATE` 프레임으로 크레딧(옥텟 수)을 발급하는 **credit-based 스킴**이며, 송신자는 **스트림 레벨 윈도우와 커넥션 레벨 윈도우를 동시에** 만족해야만 `DATA` 프레임을 보낼 수 있다.

## 내부 동작

### 1. 두 개의 독립된 윈도우

RFC 9113 §6.9.1은 흐름 제어가 "스트림당 하나, 커넥션 전체에 하나"인 **두 층**에서 동시에 작동한다고 명시한다.

```
Connection window (초기 65,535 octets)
┌───────────────────────────────────────────┐
│  Stream A window   Stream B window   ...   │
│  (초기 65,535)      (초기 65,535)           │
└───────────────────────────────────────────┘
```

송신자가 스트림 A에 `DATA` 프레임을 보내면, **A의 스트림 윈도우**와 **커넥션 윈도우** 둘 다에서 전송한 프레임 페이로드 길이만큼 차감된다(§6.9.1-4). 즉 아무리 스트림 A의 개별 윈도우가 남아 있어도 커넥션 윈도우가 바닥나면 A도 더 보낼 수 없다 — 두 제약의 AND 조건이다.

### 2. 무엇이 흐름 제어 대상인가

§6.9-4에 따르면 이 문서(RFC 9113)에 정의된 프레임 타입 중 **`DATA` 프레임만** 흐름 제어 대상이다. `HEADERS`, `SETTINGS`, `PING`, `WINDOW_UPDATE` 자체 같은 제어 프레임은 윈도우를 소비하지 않는다 — 그렇지 않으면 윈도우가 고갈된 상황에서 그 상황을 알리는 제어 프레임 자체가 막히는 교착이 생기기 때문이다(중요한 제어 프레임이 흐름 제어에 막히지 않게 한다는 취지가 §5.2.1-2.5에도 나온다). 계산 시 9바이트 프레임 헤더는 제외하고 페이로드 길이만 카운트한다(§6.9.1-3).

### 3. WINDOW_UPDATE 프레임 구조

```
WINDOW_UPDATE Frame {
  Length (24) = 0x04,
  Type (8) = 0x08,
  Unused Flags (8),
  Reserved (1),
  Stream Identifier (31),
  Reserved (1),
  Window Size Increment (31),
}
```

`Window Size Increment`는 1~2³¹-1(2,147,483,647) 범위의 부호 없는 정수로, "기존 윈도우에 이만큼 더 보낼 수 있는 크레딧을 추가한다"는 뜻이다(§6.9-6). Stream Identifier가 0이면 커넥션 전체, 0이 아니면 해당 스트림 전용 윈도우를 갱신한다(§6.9-8). increment가 0인 `WINDOW_UPDATE`는 스트림 레벨이면 `PROTOCOL_ERROR` 스트림 에러, 커넥션 레벨이면 커넥션 에러로 처리해야 한다(§6.9-9).

송신자가 받는 데이터 흐름과 수신자가 보내는 `WINDOW_UPDATE`는 **완전히 비동기**다(§6.9.1-8) — 수신자는 데이터를 소비하는 즉시, 송신자의 전송 완료를 기다리지 않고 미리 크레딧을 밀어 넣어(aggressively) 스트림이 멈추지 않게 만들 수 있다. 이게 credit-based 스킴이 stop-and-wait보다 처리량을 잘 내는 이유다.

### 4. 윈도우 오버플로/언더플로 처리

- **상한**: 윈도우는 2³¹-1 옥텟을 절대 넘을 수 없다(§6.9.1-7). 넘기는 `WINDOW_UPDATE`를 받으면 송신자는 스트림 레벨이면 `RST_STREAM(FLOW_CONTROL_ERROR)`, 커넥션 레벨이면 `GOAWAY(FLOW_CONTROL_ERROR)`로 강제 종료해야 한다.
- **음수 허용(단, 전송 금지)**: `SETTINGS_INITIAL_WINDOW_SIZE`가 바뀌면 이미 열려 있는("open" 또는 "half-closed (remote)") 모든 스트림의 윈도우를 **새 값과 이전 값의 차이만큼** 조정해야 한다(§6.9.2-3). 이 조정으로 윈도우가 음수가 될 수 있는데, 스펙은 이를 명시적으로 허용하면서 "송신자는 음수 윈도우를 추적하고, `WINDOW_UPDATE`로 다시 양수가 될 때까지 새 `DATA` 프레임을 보내면 안 된다"고 규정한다(§6.9.2-4).

RFC 본문의 구체적 예시(§6.9.2-5)를 그대로 옮기면: 클라이언트가 커넥션 수립 직후 60KB를 즉시 보냈는데, 서버가 초기 윈도우 크기를 16KB로 설정하는 `SETTINGS`를 보내면, 클라이언트는 `SETTINGS` 수신 시점에 가용 윈도우를 **-44KB**로 재계산한다. 이 음수 윈도우는 이후 `WINDOW_UPDATE`들이 누적되어 다시 양수가 될 때까지 유지되며, 그동안 클라이언트는 새 데이터를 보낼 수 없다.

- **커넥션 윈도우는 SETTINGS로 못 바꾼다**: §6.9.2-6은 "`SETTINGS` 프레임은 커넥션 흐름 제어 윈도우를 변경할 수 없다"고 단정한다. 커넥션 레벨 윈도우를 늘리는 유일한 방법은 스트림 식별자 0번의 `WINDOW_UPDATE`뿐이다.

## 검증

이 repo엔 코드 실행 환경이 없으므로, 독자가 자기 환경에서 직접 확인할 수 있는 두 가지 경로를 제시한다.

**(a) nghttp2 CLI로 실제 프레임 로그 보기** (nghttp2 패키지의 `nghttp` 클라이언트 사용):

```sh
nghttp -nv https://nghttp2.org/ 2>&1 | grep -A2 "WINDOW_UPDATE\|SETTINGS_INITIAL_WINDOW_SIZE"
```

`-v`는 송수신되는 모든 HTTP/2 프레임을 프레임 타입·플래그·페이로드와 함께 로그로 찍는다. 출력에서 `SETTINGS` 프레임의 `SETTINGS_INITIAL_WINDOW_SIZE` 값과, 이후 오가는 `WINDOW_UPDATE` 프레임의 `window_size_increment` 필드가 실제로 나타나는지, 그리고 그 값이 초기 65,535에서 서버 설정값으로 바뀌는지를 확인하면 위 §6.9.2 동작이 실물로 재현된다.

**(b) Wireshark로 필드 단위 확인**: `http2.type == 8` 필터로 `WINDOW_UPDATE` 프레임만 골라내면, 각 프레임의 `Stream Identifier`(0이면 커넥션 레벨)와 `Window Size Increment` 필드를 그대로 볼 수 있다. 같은 캡처에서 `http2.type == 4`(`SETTINGS`)를 걸어 `SETTINGS_INITIAL_WINDOW_SIZE` 파라미터가 포함된 프레임을 찾으면, 그 프레임 전후로 활성 스트림들의 데이터 전송 재개 시점이 지연되는지(음수 윈도우 회복 대기) 비교할 수 있다.

## 잘못 알고 있던 것

- **오해 1: "TCP가 흐름 제어를 하니 HTTP/2는 멀티플렉싱만 하면 된다."** 실제로는 TCP의 흐름 제어는 커넥션(소켓) 단위로만 작동해서, 한 커넥션 안에 여러 스트림이 공존하는 HTTP/2에서는 "어느 스트림이 얼마나 보낼 수 있는가"를 표현할 수 없다(이 TCP와의 대비는 스펙 문구가 아니라 위 §6.9.1의 스트림·커넥션 이중 윈도우 구조로부터 나오는 추론이다). RFC는 스트림 레벨과 커넥션 레벨 윈도우가 별개로 존재한다고만 명시할 뿐(§6.9.1-2), TCP와 직접 비교하지는 않는다. 실무에서 한 스트림이 느린 클라이언트에게 대량 응답을 보내면, 커넥션 윈도우가 그 스트림에 묶여 같은 커넥션의 다른 스트림까지 지연되는("head-of-line blocking at the flow-control layer") 현상이 이 이중 구조 때문에 생긴다.
- **오해 2: "`SETTINGS_INITIAL_WINDOW_SIZE`를 올리면 커넥션 레벨 윈도우도 같이 커진다."** §6.9.2-6이 명시적으로 부정한다 — `SETTINGS_INITIAL_WINDOW_SIZE`는 **스트림 레벨**(신규 스트림의 초깃값 + 이미 열린 스트림들의 차분 조정)에만 적용되고, 커넥션 레벨 윈도우는 오직 스트림 ID 0의 `WINDOW_UPDATE`로만 늘어난다. 이 둘을 같은 메커니즘으로 오해하면, 서버 쪽에서 `SETTINGS`만 크게 잡아놓고 커넥션 레벨 `WINDOW_UPDATE`를 충분히 안 보내는 구현 버그로 이어질 수 있다.

## 더 파고들 만한 것

- 스펙은 흐름 제어 **알고리즘**(언제, 얼마나 `WINDOW_UPDATE`를 보낼지)을 의도적으로 규정하지 않는다(§5.2.1 일곱 번째 항목, "any algorithm that suits their needs"). gRPC-Java나 Netty가 실제로 쓰는 BDP(bandwidth-delay product) 추정 기반 동적 윈도우 확장 알고리즘을 다음 노트로 다뤄볼 만하다.
- QUIC/HTTP-3([기존 노트](./http-3-quic-key-differences.md))는 흐름 제어를 스트림별로 별도 프레임(`MAX_STREAM_DATA`/`MAX_DATA`)으로 옮기면서 head-of-line blocking을 어떻게 다르게 처리하는지 비교하면 좋은 후속 주제가 된다.

## 참고

- RFC 9113 (HTTP/2), §5.2 Flow Control, §6.9 WINDOW_UPDATE — https://www.rfc-editor.org/rfc/rfc9113.html
- 이 repo의 관련 노트: [http2-multiplexing.md](./http2-multiplexing.md), [http2-hpack-header-compression.md](./http2-hpack-header-compression.md)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
