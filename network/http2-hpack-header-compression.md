# HPACK: HTTP/2가 헤더를 DEFLATE 없이 압축하면서 CRIME을 피하는 법 (정적/동적 테이블·Huffman·인덱스 주소공간)

> **Primary source:** RFC 7541 (HPACK: Header Compression for HTTP/2) §2~§6, Appendix A/B
> **Secondary:** RFC 9113 §4.3 (Field Section Compression), nghttp2 `hpack` 구현
> **Date:** 2026-08-01
> **Status:** draft

## 왜 봤나

HTTP/1.1에서는 요청마다 `Cookie`, `User-Agent`, `Accept` 같은 헤더가 거의 그대로 반복 전송된다. HTTP/2는 한 연결에 수십~수백 스트림을 다중화하므로 이 중복이 곱해져 무시할 수 없다. SPDY는 헤더에 DEFLATE(gzip)를 그냥 씌웠다가 **CRIME 공격**으로 뚫렸다 — 공격자가 주입한 값과 비밀(세션 쿠키)이 같은 스트림에 있을 때 압축 결과 길이만 봐도 비밀을 한 바이트씩 알아낼 수 있었다. HPACK은 "압축은 하되 CRIME이 안 되게" 다시 설계된 스킴이다. 그 구조가 흐릿해서 봤다.

## 핵심 한 문장

> HPACK은 범용 DEFLATE 대신 **연결 단위 인덱스 테이블(정적 61개 + 동적 FIFO) + 정적 Huffman 코드**로 헤더를 필드 단위로 참조/치환하며, 민감 헤더에는 "Never Indexed" 표현을 둬서 압축 문맥 혼합에 의한 비밀 유출을 구조적으로 차단한다.

## 내부 동작

### 1. 인덱스 주소공간: 정적 테이블 + 동적 테이블

HPACK은 (이름, 값) 쌍을 하나의 **단일 인덱스 공간**에 올린다.

```
 index:  1 ......... 61 | 62 .................. 61+k
        [ 정적 테이블   ] [ 동적 테이블 (신→구)       ]
        읽기전용·불변      연결·방향별, FIFO 삽입/축출
```

- **정적 테이블**(§2.3.1, Appendix A): 61개 고정 엔트리. 예) index 2 = (`:method`, `GET`), index 1 = (`:authority`, ""), index 32 = (`cookie`, ""). 값이 비어 "이름만" 참조하는 용도도 많다. 모든 연결이 공유하고 절대 안 변한다.
- **동적 테이블**(§2.3.2): index 62부터. **새 엔트리는 항상 62번에 삽입**되고, 기존 동적 엔트리의 논리 인덱스는 하나씩 밀린다(신→구 정렬). 즉 인덱스는 고정 위치가 아니라 "삽입 이후 나이"에 따라 이동한다.
- 동적 테이블은 **인코더 측·디코더 측이 각각** 유지하며, 요청/응답 방향도 분리된다 → 한 연결에 실질적으로 테이블이 여러 벌 존재한다(단일 공유 테이블이 아님).

### 2. 엔트리 크기 회계와 축출

엔트리 하나의 "크기"는 실제 바이트가 아니라 규약값이다(§4.1):

```
size(entry) = len(name) + len(value) + 32
```

`+32`는 엔트리를 담는 참조/연결 리스트 오버헤드를 정액으로 잡은 값이다. 동적 테이블 총 크기가 `SETTINGS_HEADER_TABLE_SIZE`(기본 4096바이트)를 넘으면 **가장 오래된 엔트리(테이블 끝)부터 축출**한다(FIFO). 그래서 큰 헤더 하나를 넣으면 여러 엔트리가 한꺼번에 밀려날 수 있다. 디코더가 인코더보다 작은 한도를 광고하면 인코더는 "Dynamic Table Size Update" 신호(§6.3)로 자기 테이블을 먼저 줄여 양쪽 상태를 동기화한다.

### 3. 헤더 필드의 6가지 표현 (첫 바이트 상위 비트로 구분)

```
1xxxxxxx  Indexed              — 이름+값 전부 테이블 index로 (7비트 prefix)
01xxxxxx  Literal + Incr Index — 값 리터럴, 동적 테이블에 "추가" (6비트 prefix)
0000xxxx  Literal, no Index    — 추가 안 함 (4비트 prefix)
0001xxxx  Literal, Never Index — 추가 안 함 + 중계기도 추가 금지 (보안)
001xxxxx  Dynamic Table Size Update
```

- `Indexed`: index 2(=GET)면 `0x82` 한 바이트로 `:method: GET` 전체가 끝난다.
- `Incremental Indexing`: 이름은 index 참조 또는 리터럴, 값은 리터럴로 보내고 **동적 테이블 62번에 등록**한다. 다음 요청부터 그 (이름,값)은 1바이트 인덱스로 압축된다.
- `Never Indexed`(§6.2.3): `Authorization`처럼 비밀을 담은 헤더에 쓴다. 캐시(동적 테이블)에 절대 안 올라가므로, 공격자 주입값과 함께 있어도 압축 문맥에 비밀이 섞이지 않는다 → CRIME류 차단의 핵심 장치. 다만 이 표현을 실제로 선택하는 건 **인코더의 재량**이라, 라이브러리가 어떤 헤더를 민감하다고 표시하는지가 방어의 실효를 가른다.

디코더가 index를 만나면 `index <= 61`이면 정적 테이블, 그 이상이면 `index - 61`번째 동적 엔트리를 꺼낸다. **index 0은 불법**이며(§6.1), 삽입 순서가 인코더와 1개라도 어긋나면 서로 다른 헤더로 복원돼 연결이 `COMPRESSION_ERROR`로 죽는다 — HPACK이 "상태 있는" 프로토콜인 이유이자, 스트림별 독립 복원이 불가능한(그래서 HTTP/3에서 QPACK으로 갈린) 지점이다.

### 4. 정수 인코딩 (prefix N비트)

인덱스·길이는 모두 "N비트 prefix 정수"로 인코딩한다(§5.1):

```
값 < 2^N - 1 : prefix 안에 그대로
그 외        : prefix 비트를 전부 1로 채우고, (값 - (2^N-1))을
              7비트씩 리틀엔디언 continuation 옥텟으로.
              각 옥텟 MSB=1이면 "더 있음", 0이면 끝.
```

예: 5비트 prefix로 1337 인코딩 → prefix=31(=2^5-1), 나머지 1306 = 0x51A → `10011010 00001010`. 작은 값은 1바이트, 큰 값만 늘어난다.

### 5. 문자열 리터럴과 Huffman

리터럴 이름/값은 `[H][length][octets]`. 첫 비트 `H`가 1이면 **정적 Huffman 코드**(§5.2, Appendix B) 적용. 이 코드표는 대량의 실제 HTTP 헤더 통계로 만든 canonical Huffman이라 흔한 문자가 짧다. 남는 비트는 **EOS 심볼의 prefix(전부 1)**로 패딩한다. 단, Huffman이 원문보다 길어지면 인코더는 `H=0`으로 그냥 보낸다 — Huffman이 항상 이득은 아니다.

## 검증

RFC 7541 Appendix C.3.1의 흐름을 따라가 본다. 두 연속 요청:

```
요청1 헤더:  :method: GET      -> 0x82 (정적 index 2, Indexed)
             custom-key: custom-value
               -> 0x40 (Literal+Incr Index, 이름 리터럴)
                  이름 "custom-key" 길이+옥텟, 값 "custom-value" 길이+옥텟
               => 동적 테이블 62 = (custom-key, custom-value), size=10+12+32=54
요청2 헤더:  custom-key: custom-value
               -> 0xBE (Indexed, index 62)  ← 1바이트로 끝
```

첫 요청에서 등록(54바이트)해 두면, 같은 헤더가 이후엔 단일 바이트로 압축됨을 스펙 예제가 그대로 보여준다. `nghttp -v`의 `recv (stream_id=...) header ... (indexed)` 로그로도 실제 인덱스 참조 여부를 확인할 수 있다.

## 잘못 알고 있던 것

- **"HPACK은 헤더용 gzip이다"** — 아니다. DEFLATE의 슬라이딩 윈도우 문맥 혼합이 바로 CRIME의 원인이었고, HPACK은 그걸 버리고 필드 단위 인덱스 + 고정 Huffman으로 갈아탄, 보안 목적이 명시된 별도 스킴이다.
- **"인덱스는 고정 좌표다"** — 동적 엔트리 인덱스는 삽입/축출마다 이동한다. 그래서 인코더와 디코더가 **연산을 완전히 동일 순서로 재현**해야 하고, 상태가 어긋나면 연결 전체가 깨진다(HPACK은 상태 있는 프로토콜).
- **"테이블은 양방향 공유"** — 인코더/디코더, 요청/응답이 각각 자기 테이블을 갖는다. 공유되는 건 정적 테이블(불변)뿐이다.
- **"Never Indexed면 압축이 안 된다"** — 값 자체는 Huffman으로 여전히 압축될 수 있다. 단지 동적 테이블 **캐싱만** 금지된다.
- **"Huffman 패딩은 아무 비트나 채운다"** — 패딩은 반드시 EOS 심볼의 prefix(전부 1)여야 하고, 7비트를 초과하거나 전부 1이 아닌 패딩이 오면 디코딩 오류로 처리해야 한다(§5.2). 이 규칙이 없으면 패딩에 데이터를 숨기는 우회가 생긴다.

## 더 파고들 만한 것

- QPACK(HTTP/3): HPACK의 순서 의존성이 QUIC의 스트림 독립성과 충돌 → 별도 encoder/decoder 스트림과 "blocked" 처리, 절대 인덱스+base 상대 인덱싱으로 재설계된 구조.
- 정적 Huffman 코드표(Appendix B)가 실제 HTTP 헤더 통계로 어떻게 만들어졌는지, 그리고 이 고정 코드가 임의 바이너리 값에는 오히려 팽창을 일으키는 경계.
- 동적 테이블 크기 튜닝이 압축률 vs 메모리/HOL에 주는 영향, `SETTINGS_HEADER_TABLE_SIZE=0`으로 동적 테이블을 끄는 선택.

## 참고

- RFC 7541 §2~§6, Appendix A(정적 테이블)·B(Huffman 코드)·C(예제)
- RFC 9113 §4.3 Field Section Compression
- CRIME (Rizzo & Duong, 2012) — DEFLATE 기반 헤더 압축의 사이드채널
