# TLS 1.3 키 스케줄: HKDF-Extract/Expand 사슬로 하나의 (EC)DHE 비밀에서 모든 트래픽 키를 뽑는 법

> **Primary source:** RFC 8446 (The TLS 1.3 Protocol) §4.4.4 (Finished), §7.1 (Key Schedule), §7.2 (Key Update); HKDF는 RFC 5869
> **Secondary:** RFC 8446 §2 (핸드셰이크 개요), §4.2.11 / §2.3 (PSK·0-RTT)
> **Date:** 2026-07-21
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/tls-1-3-key-schedule

## 왜 봤나

- "TLS 핸드셰이크 = 키 교환"이라고 뭉뚱그려 알고 있었는데, 실제로 (EC)DHE로 합의하는 건 **원시 공유 비밀 하나**뿐이고 거기서 핸드셰이크 키·애플리케이션 키·재개(resumption) 비밀이 **어떻게** 파생되는지는 몰랐다.
- TLS 1.2는 핸드셰이크가 평문 → 인증서 검증 후에야 암호화였는데, 1.3은 ServerHello 직후부터 암호문이다. 이게 가능한 이유가 키 스케줄에 있다.

## 핵심 한 문장

> TLS 1.3의 키 스케줄은 `HKDF-Extract`(엔트로피 흡수)와 `HKDF-Expand-Label`(라벨+트랜스크립트 해시로 목적별 분기)을 3단(Early → Handshake → Master)으로 쌓아, **PSK와 (EC)DHE 공유 비밀을 트랜스크립트에 바인딩된 여러 독립 키**로 결정론적으로 펼치는 함수다.

## 내부 동작

### HKDF 두 함수와 라벨 규약

RFC 5869의 HKDF는 두 단계다. **Extract**는 엔트로피가 고르지 않은 입력 키 재료(IKM)를 salt로 흡수해 고정 길이 유사난수 키(PRK)로 만들고, **Expand**는 그 PRK를 원하는 길이·용도로 펼친다. TLS 1.3은 Expand를 라벨로 감싼다:

```
HKDF-Expand-Label(Secret, Label, Context, Length) =
    HKDF-Expand(Secret, HkdfLabel, Length)

struct {
    uint16 length = Length;
    opaque label<7..255> = "tls13 " + Label;   // 모든 라벨에 "tls13 " 접두
    opaque context<0..255> = Context;
} HkdfLabel;

Derive-Secret(Secret, Label, Messages) =
    HKDF-Expand-Label(Secret, Label,
                      Transcript-Hash(Messages), Hash.length)
```

핵심은 `Derive-Secret`이 **Context 자리에 트랜스크립트 해시**(그 시점까지 오간 핸드셰이크 메시지 전체의 해시)를 넣는다는 것. 그래서 같은 상위 비밀이라도 **어느 메시지까지 봤느냐에 따라 다른 키**가 나오고, 중간자가 메시지를 한 바이트라도 바꾸면 양쪽 파생 키가 어긋난다.

### 3단 Extract 사슬 (§7.1)

```
             0
             |
   PSK ->  HKDF-Extract = Early Secret
             |  +-> Derive-Secret(., "ext binder"|"res binder", "") = binder_key
             |  +-> Derive-Secret(., "c e traffic", CH) = client_early_traffic_secret
             |  +-> Derive-Secret(., "e exp master", CH) = early_exporter_master_secret
             v
       Derive-Secret(., "derived", "")
             |
  (EC)DHE -> HKDF-Extract = Handshake Secret
             |  +-> Derive-Secret(., "c hs traffic", CH..SH) = client_handshake_traffic_secret
             |  +-> Derive-Secret(., "s hs traffic", CH..SH) = server_handshake_traffic_secret
             v
       Derive-Secret(., "derived", "")
             |
       0  -> HKDF-Extract = Master Secret
             |  +-> Derive-Secret(., "c ap traffic", CH..server Fin) = client_application_traffic_secret_0
             |  +-> Derive-Secret(., "s ap traffic", CH..server Fin) = server_application_traffic_secret_0
             |  +-> Derive-Secret(., "exp master",  CH..server Fin) = exporter_master_secret
             +-> Derive-Secret(., "res master",  CH..client Fin) = resumption_master_secret
```

읽는 법:
- **Early Secret** = `HKDF-Extract(salt=0, IKM=PSK)`. PSK가 없으면 IKM은 해시 길이만큼의 0. 여기서 0-RTT용 `client_early_traffic_secret`가 나온다.
- 다음 Extract의 salt는 이전 비밀을 그대로 쓰지 않고 `Derive-Secret(., "derived", "")`로 한 번 더 펼친 값이다. 이 `"derived"` 단계는 **단계 간 도메인 분리**를 강제해서, 한 단계 키가 새도 인접 단계로 역산이 안 되게 한다.
- **Handshake Secret** = `HKDF-Extract(salt=derived(Early), IKM=(EC)DHE)`. 여기서 나온 `[c|s] hs traffic`가 ServerHello **직후**부터 EncryptedExtensions·Certificate·Finished를 암호화한다. TLS 1.2와의 결정적 차이가 이 지점 — 인증서조차 암호문이 된다.
- **Master Secret** = `HKDF-Extract(salt=derived(Handshake), IKM=0)`. 여기서 실제 데이터용 `[c|s] ap traffic ..._0`가 나온다.
- 트랜스크립트 범위가 비밀마다 다르다: hs traffic은 `CH..SH`까지, ap traffic은 `CH..서버 Finished`까지, res master는 `CH..클라이언트 Finished`까지. **더 나중 비밀일수록 더 많은 메시지에 바인딩**된다.

### 트래픽 키와 nonce (§7.3, §5.3)

트래픽 "secret"은 그 자체로 AEAD 키가 아니다. 레코드 보호용 key/iv를 한 번 더 펼친다:

```
[sender]_write_key = HKDF-Expand-Label(Secret, "key", "", key_length)
[sender]_write_iv  = HKDF-Expand-Label(Secret, "iv",  "", iv_length)
```

레코드마다의 nonce는 새로 뽑지 않는다. **write_iv를 레코드 시퀀스 번호와 XOR**해서 만든다(§5.3). 시퀀스는 키가 바뀔 때 0으로 리셋된다.

### Finished: MAC으로 트랜스크립트를 봉인 (§4.4.4)

Finished는 핸드셰이크 무결성의 마지막 잠금이다. MAC 키는 해당 방향 **handshake traffic secret**에서 파생하고, 그걸로 트랜스크립트 해시에 HMAC을 건다:

```
finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
verify_data  = HMAC(finished_key, Transcript-Hash(핸드셰이크 컨텍스트 .. CertificateVerify*))
```

서버 Finished가 검증되면 클라이언트는 "지금까지의 모든 메시지가 위조되지 않았고, 상대가 (EC)DHE 비밀을 실제로 안다"를 동시에 확인한다.

### 1-RTT 흐름과 0-RTT (§2)

```
1-RTT:
Client                                Server
ClientHello + key_share  ------->
                                 ServerHello + key_share   (여기서 Handshake Secret 확정)
                            {EncryptedExtensions}
                            {Certificate}{CertificateVerify}{Finished}
                         <------- [Application Data 가능]
{Finished}               ------->
[Application Data]       <------> [Application Data]
```

`{...}`는 handshake traffic 키로, `[...]`는 application traffic 키로 보호된다. 0-RTT는 이전 세션의 `resumption_master_secret`로 만든 PSK를 재사용해, ClientHello와 함께 `client_early_traffic_secret`로 암호화한 데이터를 **첫 왕복에** 실어 보낸다. 대신 그 데이터는 **(EC)DHE 이전**이라 순방향 비밀성이 없고, 서버가 재생(replay)을 자체적으로 막지 못한다 — RFC가 명시적으로 경고하는 트레이드오프다.

## 검증

RFC 8446 §7.1의 다이어그램을 위→아래로 따라가며, 각 `HKDF-Extract`의 salt가 직전 비밀의 `Derive-Secret(., "derived", "")` 결과라는 점을 확인했다. 라벨 문자열(`"c hs traffic"`, `"s ap traffic"`, `"res master"`, `"derived"`, `"key"`, `"iv"`, `"finished"`)은 §7.1·§4.4.4에 나온 그대로다. 개념 스니펫으로 파생 순서를 정리하면:

```text
Early    = Extract(0,   PSK|0)
Hs       = Extract(Derive-Secret(Early, "derived", ""), (EC)DHE)
Master   = Extract(Derive-Secret(Hs,    "derived", ""), 0)
c_hs     = Derive-Secret(Hs,     "c hs traffic", CH..SH)
c_ap_0   = Derive-Secret(Master, "c ap traffic", CH..serverFin)
c_key    = HKDF-Expand-Label(c_ap_0, "key", "", key_len)
nonce_n  = c_iv XOR seq_n
```

Master의 IKM이 `(EC)DHE`가 아니라 **0**이라는 점(엔트로피는 이미 Handshake 단계 salt로 들어옴), Early의 salt가 0이라는 점이 헷갈리기 쉬워 원문에서 두 번 확인했다.

## 잘못 알고 있던 것

- **"세션 키 하나를 (EC)DHE로 합의한다."** → 합의하는 건 원시 (EC)DHE 비밀 하나뿐이고, 방향별(client/server)·단계별(handshake/application)·용도별(exporter/resumption) 키는 전부 그 비밀에서 HKDF로 **파생**된다. 그래서 방향마다 키가 다르다.
- **"트래픽 secret이 곧 암호화 키다."** → secret은 중간 재료다. 실제 AEAD는 `HKDF-Expand-Label(secret, "key"/"iv", ...)`로 한 겹 더 펼친 write_key/write_iv를 쓴다. Key Update(§7.2)는 `"traffic upd"` 라벨로 secret을 굴려 앞선 키를 폐기한다.
- **"트랜스크립트 해시는 그냥 무결성 체크섬이다."** → 그것이 `Derive-Secret`의 Context로 들어가 **키 자체를 트랜스크립트에 바인딩**한다. 메시지가 변조되면 MAC이 아니라 파생 키부터 어긋나 복호화가 실패한다.

## 더 파고들 만한 것

- Key Update 메커니즘(§7.2)과 `"traffic upd"` 라벨의 forward secrecy 효과, 시퀀스 번호 리셋.
- PSK binder(`"ext binder"`/`"res binder"`)가 0-RTT ClientHello를 어떻게 인증하는지, 재생 방지(single-use ticket, freshness window) 전략.

## 참고

- RFC 8446 §7.1 Key Schedule, §4.4.4 Finished, §5.3 Per-Record Nonce, §7.2 Key Update, §2/§2.3 핸드셰이크·0-RTT 개요
- RFC 5869 HKDF (Extract-then-Expand)
