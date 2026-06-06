# TLS 1.3 handshake 단계 (0-RTT 포함)

> **Primary source:** RFC 8446 (The Transport Layer Security (TLS) Protocol Version 1.3, 2018) §2 Protocol Overview, §2.1 Incorrect DHE Share, §2.2 Resumption and PSK, §2.3 0-RTT Data, §7.1 Key Schedule
> **Secondary:** RFC 5869 (HKDF), `openssl s_client` / Wireshark TLS dissector
> **Date:** 2026-06-06
> **Status:** draft

## 왜 봤나

- TLS 1.2를 "키 교환 2-RTT + ChangeCipherSpec"으로 외우고 있었는데, 1.3에서 **1-RTT가 기본이고 0-RTT까지 가능**하다는 말을 듣고 "그 RTT가 어디서 사라졌는가"를 메시지/키 스케줄 수준에서 정리하고 싶었다.
- 0-RTT를 "그냥 빠른 재접속" 정도로만 알고 있었고, **왜 위험한지**는 흐릿했다.

## 핵심 한 문장

> TLS 1.3은 ClientHello에 키 공유(key_share)를 **미리 실어 보내** 서버 첫 응답에서 곧장 키가 확정되므로 핸드셰이크가 1-RTT로 줄고, ServerHello 직후 모든 메시지가 암호화되며, 이전 세션의 PSK를 쓰면 ClientHello와 동시에 애플리케이션 데이터를 보내는 0-RTT까지 가능하지만 그 early data는 구조적으로 재전송 공격에 노출된다.

## 내부 동작

### 1. 1-RTT full handshake (§2)

TLS 1.3 핸드셰이크는 세 가지 목적을 동시에 수행한다(§2): **(a) 키 교환(key exchange)** — 공유 비밀과 알고리즘 합의, **(b) 서버 파라미터(server parameters)**, **(c) 인증(authentication)**. 1.2와의 결정적 차이는 ClientHello가 자신이 지원하는 그룹의 (EC)DHE **공개 키 공유분을 추측해서 미리 첨부**한다는 점이다.

```
       Client                                     Server

ClientHello
 + key_share          -------->
 + supported_versions
 + signature_algorithms
                                          ServerHello
                                           + key_share
                                 {EncryptedExtensions}
                                 {CertificateRequest*}
                                        {Certificate}
                                  {CertificateVerify}
                                          {Finished}
                      <--------  [Application Data*]
 {Finished}           -------->
 [Application Data]   <------->  [Application Data]

 {} = handshake key 로 암호화   [] = application key 로 암호화
```

- ClientHello의 `key_share`는 선택한 그룹(예: x25519)의 DH 공개값 g^x. 서버는 같은 그룹의 g^y를 ServerHello `key_share`에 담아 응답하면 **이 한 번의 왕복으로 양쪽이 g^xy 를 계산**한다.
- ServerHello **이후 모든 핸드셰이크 메시지는 암호화**된다(`{}`). 1.2에서 평문으로 노출되던 Certificate, 확장 등이 1.3에선 handshake traffic key로 가려진다.
- `CertificateVerify`: 서버가 지금까지의 트랜스크립트 해시에 자기 개인키로 서명 → MITM이 인증서만 베껴도 통과 못 함.
- `Finished`: 트랜스크립트 전체에 대한 HMAC. 양쪽이 같은 키·같은 메시지를 봤음을 증명(핸드셰이크 무결성).

### 2. 키 스케줄 (§7.1)

핵심 자료구조는 HKDF(RFC 5869)의 Extract/Expand를 사다리처럼 쌓은 것이다. 각 단계는 이전 secret을 `Derive-Secret`으로 누른 값을 salt로, 새 입력 키 재료(IKM)를 Extract한다.

```
            0
            |
PSK ->  HKDF-Extract        => Early Secret
            |                  ├─ ext binder / 0-RTT(client_early_traffic_secret)
       Derive-Secret(.,"derived")
            |
(EC)DHE ->HKDF-Extract       => Handshake Secret
            |                  ├─ client/server handshake_traffic_secret
       Derive-Secret(.,"derived")
            |
0    -> HKDF-Extract          => Master Secret
                               ├─ client/server application_traffic_secret
                               └─ resumption_master_secret -> 다음 세션 PSK
```

- **PSK가 없으면** Early Secret 단계의 IKM은 0으로 채운다. 즉 0-RTT/재개를 안 쓰는 첫 접속은 (EC)DHE만으로 Handshake Secret을 만든다.
- handshake_traffic_secret은 ServerHello 직후부터 적용되어 위 `{}` 메시지를 암호화하고, application_traffic_secret은 `Finished` 이후 본 데이터에 쓴다. **단계마다 키를 갈아끼우는** 것이 1.3 보안 모델의 골자다.

### 3. HelloRetryRequest — 키 공유 빗나감 (§2.1)

ClientHello의 key_share는 어디까지나 **추측**이다. 서버가 그 그룹을 지원하지 않으면, ServerHello 자리에 특수한 **HelloRetryRequest(HRR)** 를 보내 "이 그룹으로 다시 보내라"고 지시한다. 클라이언트는 올바른 그룹으로 ClientHello를 재전송한다.

```
ClientHello (key_share: x25519) -->
                                <-- HelloRetryRequest (group: secp256r1)
ClientHello (key_share: secp256r1) -->
                                <-- ServerHello ...
```

이 경우 1-RTT가 아니라 **2-RTT**로 늘어난다. 그래서 클라이언트는 서버가 선호할 만한 그룹을 1순위로 추측하는 것이 중요하다.

### 4. 재개(PSK)와 0-RTT (§2.2, §2.3)

이전 핸드셰이크의 `resumption_master_secret`에서 파생한 PSK를 서버가 `NewSessionTicket`으로 발급해 둔다. 재접속 시 클라이언트는 ClientHello에 `pre_shared_key` 확장을 실어 이 PSK로 재개한다 — 인증서 검증을 건너뛸 수 있다.

여기에 `early_data` 확장을 더하면 **0-RTT**가 된다. 클라이언트는 PSK에서 파생한 client_early_traffic_secret으로 ClientHello **바로 뒤에 애플리케이션 데이터를 즉시** 붙여 보낸다.

```
ClientHello
 + key_share
 + pre_shared_key
 + early_data
(0-RTT Application Data*)   -->        ServerHello + pre_shared_key ...
                                       {EncryptedExtensions + early_data*}
                                       {Finished}
                            <--        [Application Data]
(EndOfEarlyData)
{Finished}                  -->
```

RTT가 0인 이유: 데이터가 **핸드셰이크 첫 패킷에 동승**해 서버의 응답을 기다리지 않는다.

## 검증

`openssl s_client`로 1.3 협상과 early data 사용을 직접 따라갈 수 있다.

```bash
# 프로토콜/암호군 확인
$ openssl s_client -connect example.com:443 -tls1_3 </dev/null 2>/dev/null \
    | grep -E "Protocol|Cipher"
#   Protocol  : TLSv1.3
#   Cipher    : TLS_AES_128_GCM_SHA256

# 세션 티켓 저장 후 재접속 + 0-RTT 전송
$ openssl s_client -connect example.com:443 -tls1_3 -sess_out s.pem </dev/null
$ printf 'GET / HTTP/1.0\r\n\r\n' \
    | openssl s_client -connect example.com:443 -sess_in s.pem -early_data /dev/stdin
#   Early data was accepted   ← 0-RTT 수락됨
```

Wireshark로 보면 1.3은 **ServerHello 이후 핸드셰이크 레코드가 `Application Data(23)` 타입으로 암호화**되어 나타난다 — Certificate가 평문으로 안 보이는 것이 1.2와의 눈에 띄는 차이다.

## 잘못 알고 있던 것

- **"1.3도 ChangeCipherSpec으로 암호화 전환을 알린다"** → 1.3에서 CCS는 **의미가 없고**, 미들박스 호환(중간 장비가 1.2처럼 보이게)을 위한 더미로만 선택적으로 보낸다. 키 전환은 키 스케줄 단계로 암묵적으로 일어난다.
- **"0-RTT는 그냥 빠른 재접속이라 안전하다"** → 0-RTT early data는 **재전송(replay) 공격에 구조적으로 취약**하다(§2.3, §8). 핸드셰이크 신선도(server nonce 교환) 이전에 보내지므로, 공격자가 캡처한 0-RTT 데이터를 그대로 재전송하면 서버가 다시 처리할 수 있다. 그래서 0-RTT는 **멱등(idempotent)한 요청에만** 써야 한다(GET 같은). RFC도 0-RTT 데이터에 대한 별도 anti-replay를 요구한다.
- **"키 공유는 서버가 정한다"** → 클라이언트가 ClientHello에서 **먼저 추측해 보낸다**. 빗나가면 HelloRetryRequest로 1-RTT가 2-RTT가 된다. 키 교환 합의가 1.2보다 한 박자 앞당겨진 것이 1-RTT의 핵심.
- **"재개하면 키가 같다"** → PSK는 재개의 출발점일 뿐, 0-RTT가 아닌 일반 재개는 보통 (EC)DHE를 함께 섞어(`psk_dhe_ke`) 새 공유 비밀로 forward secrecy를 유지한다.

## 더 파고들 만한 것

- 0-RTT anti-replay 구현: single-use ticket vs. ClientHello 기록(strike register) vs. freshness window — 분산 서버에서 어떻게 일관되게 막는가.
- 키 스케줄의 `Derive-Secret`이 트랜스크립트 해시를 어떻게 바인딩하는지, transcript hash가 다운그레이드 공격 방어에 기여하는 방식.

## 참고

- RFC 8446 §2(개요), §2.1(HRR), §2.2(PSK 재개), §2.3(0-RTT), §7.1(키 스케줄), §8(replay 방어)
- RFC 5869 (HKDF Extract-and-Expand)
- 관련 노트: `network/tcp-handshake-and-teardown-state-machine.md`, `network/http2-multiplexing.md`(예정)
