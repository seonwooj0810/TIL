# PKCE: 공개 클라이언트의 인가 코드 탈취를 code_verifier로 막는 법

> **Primary source:** RFC 7636 (Proof Key for Code Exchange by OAuth Public Clients) §1, §4.1–4.6, §7.1–7.2
> **Secondary:** RFC 6749 (OAuth 2.0) §4.1 Authorization Code Grant / OAuth 2.0 Security BCP
> **Date:** 2026-07-13
> **Status:** draft

## 왜 봤나

- OAuth 2.0 grant types를 정리하면서 "SPA·모바일은 왜 authorization code + PKCE를 쓰나"를 한 줄로 넘겼는데, PKCE가 정확히 **무엇을 어떻게** 막는지 메커니즘을 따라가 본 적이 없었다.
- "PKCE = client_secret 없는 클라이언트를 위한 secret 대용"이라고만 알고 있었다. 이 요약이 왜 절반만 맞는지 확인하려고 봤다.

## 핵심 한 문장

> PKCE는 매 인가 요청마다 클라이언트가 즉석에서 만든 난수(`code_verifier`)의 **해시**만 인가 요청에 노출하고, 토큰 교환 때 원본 난수를 제시하게 하여 — 리다이렉트로 새어나가는 인가 코드를 훔친 공격자가 원본 난수를 모르면 코드를 토큰으로 바꿀 수 없게 하는, **동적 1회용 증명** 확장이다.

## 내부 동작

### 막으려는 것: authorization code interception (§1)

네이티브/모바일 공개 클라이언트는 redirect URI로 보통 커스텀 URI 스킴(`myapp://cb`)을 쓴다. OS는 이 스킴을 여러 앱이 등록하는 것을 막지 못하므로, 악성 앱이 같은 스킴을 선점하면 인가 서버가 브라우저로 돌려보내는 리다이렉트(= 인가 코드가 실린 단계 (4))를 가로챌 수 있다. 공개 클라이언트는 `client_secret`이 없으므로(있어도 앱 바이너리에서 추출 가능), 공격자는 훔친 코드 + 공개된 `client_id`만으로 토큰 엔드포인트에서 코드를 access token으로 교환해버린다.

```
[정상]  앱 → /authorize(code_challenge) → 로그인 → redirect(code) → 앱 → /token(code, code_verifier) → token
[공격]  앱 → /authorize ─ 로그인 ─ redirect(code) ─╳→ 악성앱이 code 가로챔 → /token(code) → ??? 
                                                        └ code_verifier를 모름 → invalid_grant
```

### verifier / challenge 생성 (§4.1, §4.2)

- `code_verifier`: 클라이언트가 인가 요청 **직전에** 만드는 고엔트로피 난수 문자열.
  - ABNF: `43*128unreserved`, `unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"` — 즉 43~128자, URL-safe 문자만.
  - §7.1: 최소 **256비트 엔트로피** 권장. §4.1: 32바이트(256비트) 난수를 뽑아 base64url 인코딩하면 43자 verifier가 나오는 것이 전형.
- `code_challenge`: verifier를 변환 메서드(`code_challenge_method`)로 가공한 값.
  - `plain`: `code_challenge = code_verifier` (변환 없음)
  - `S256`: `code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`

여기서 세부가 중요하다. `SHA256`의 입력은 verifier 문자열의 **ASCII 옥텟**이고(문자열을 그대로 해시), 출력 32바이트를 **base64url(패딩 `=` 제거, 개행/공백 없음)**로 인코딩한다(§3). 그래서 S256 challenge는 항상 43자 고정.

### 프로토콜 흐름 — 상태가 어디에 묶이나

```
(1) 클라이언트: verifier = random(32B); challenge = S256(verifier)
(2) GET /authorize?response_type=code&client_id=...&redirect_uri=...
        &code_challenge=<challenge>&code_challenge_method=S256
(3) 인가 서버: 발급하는 authorization code에 (challenge, method)를 서버측에 바인딩해 저장
(4) redirect: myapp://cb?code=<code>              ← 여기서 code가 새어도
(5) POST /token  grant_type=authorization_code&code=<code>
        &redirect_uri=...&client_id=...&code_verifier=<verifier>   ← 원본 verifier 제시
(6) 인가 서버 검증:
        method==S256 → BASE64URL(SHA256(ASCII(code_verifier))) == 저장된 challenge ?
        method==plain → code_verifier == 저장된 challenge ?
      같으면 토큰 발급, 다르면 error=invalid_grant (§4.6)
```

핵심은 **바인딩의 방향**이다. 인가 요청에는 해시(challenge)만 실려 나가고, 토큰 요청에는 원본(verifier)이 실린다. 이 둘은 다른 HTTP 트랜잭션이다. 인가 코드를 훔친 공격자는 (4)의 리다이렉트만 보므로 code는 얻지만, verifier는 (5)의 토큰 요청(TLS로 보호됨, 클라이언트 프로세스 내부)에만 존재해 얻을 수 없다. 단방향 해시라 challenge로부터 verifier를 역산할 수도 없다. 결과적으로 코드가 **그 코드를 요청한 바로 그 클라이언트 인스턴스에** 암호학적으로 묶인다(proof-of-possession).

### plain의 한계와 다운그레이드 공격 (§7.2)

`plain`은 challenge == verifier라서, 공격자가 인가 **요청**까지 관찰할 수 있으면(예: OS 로그, 프록시) challenge=verifier를 그대로 획득해 방어가 무너진다. S256은 요청에서 해시만 보이므로 요청을 관찰해도 verifier를 복원 못 한다.

그래서 §7.2는 다운그레이드를 명시적으로 막는다:
- 클라이언트는 S256을 시도한 뒤 **plain으로 내려가면 안 된다(MUST NOT)**.
- **PKCE를 지원하는 서버는 S256을 반드시 지원(required)**. 따라서 S256 요청에 서버가 에러를 내는 상황은 "서버 결함"이거나 "MITM이 다운그레이드를 시도 중"이라는 뜻 — 클라이언트는 이를 신뢰 신호로 삼을 수 있다.

## 검증

RFC 7636의 §4.2/§4.6 정의를 그대로 따라가면 S256 검증이 결정적(deterministic)임을 손으로 확인할 수 있다. verifier가 정해지면 challenge는 유일하고, 서버는 저장한 challenge와 재계산 값을 바이트 비교만 하면 된다.

```java
// RFC 7636 §4.1-4.2를 그대로 구현한 클라이언트측 생성
byte[] octets = new byte[32];
new SecureRandom().nextBytes(octets);                 // 256비트 엔트로피 (§7.1)
String verifier = Base64.getUrlEncoder().withoutPadding()
                        .encodeToString(octets);       // 43자 URL-safe

byte[] digest = MessageDigest.getInstance("SHA-256")
                 .digest(verifier.getBytes(StandardCharsets.US_ASCII)); // ASCII(verifier)
String challenge = Base64.getUrlEncoder().withoutPadding()
                         .encodeToString(digest);      // §4.2 S256, 43자 고정

// 서버측 검증 (§4.6) — 저장한 challenge와 재계산 비교
boolean ok = MessageDigest.isEqual(
    challenge.getBytes(),                              // 인가 때 저장한 값
    sha256Base64Url(receivedVerifier).getBytes());    // 토큰 요청의 verifier 재해시
// ok == false → error=invalid_grant
```

- 입력 대칭성 확인: `verifier`가 같으면 `challenge`도 같다(SHA-256 결정성). 다르면 눈사태 효과로 완전히 다른 43자가 나와 비교가 실패한다.
- 길이 확인: SHA-256 출력은 32바이트 → base64url 무패딩 시 ⌈32/3⌉×4 − 패딩 = 43자. RFC가 말하는 "S256 challenge는 항상 43자"와 일치.

## 잘못 알고 있던 것

- **"PKCE는 client_secret의 대용품이다."** — 절반만 맞다. client_secret은 *클라이언트의 신원*을 정적으로 증명하는 장기 비밀이고, PKCE는 *이 인가 코드가 그것을 시작한 인스턴스의 것*임을 동적으로 증명하는 1회용 값이다. secret은 재사용되지만 verifier는 요청마다 새로 만들어 버린다. 그래서 OAuth 2.0 Security BCP는 confidential 클라이언트(secret 있음)에게도 PKCE를 권장한다 — 둘은 대체재가 아니라 다른 축의 방어다.
- **"S256이든 plain이든 해시를 쓰니 안전하다."** — plain은 해시를 안 쓴다(challenge==verifier). 인가 요청을 관찰당하면 그대로 뚫린다. §7.2가 plain 다운그레이드를 MUST NOT으로 막는 이유다.
- **"code_challenge를 훔치면 코드를 교환할 수 있다."** — 아니다. 토큰 교환에 필요한 건 challenge가 아니라 원본 verifier다. 단방향 해시라 challenge→verifier 역산이 불가능해, 리다이렉트에서 보이는 challenge(요청)나 code(응답)를 훔쳐도 소용없다.

## 더 파고들 만한 것

- OAuth 2.0 Security BCP가 `state` 파라미터(CSRF 방지)와 PKCE의 역할을 어떻게 분리·중복시키는가 — PKCE가 state의 CSRF 방어까지 흡수하는지.
- OpenID Connect의 `nonce`와 PKCE의 차이: ID token 재생 방지 vs 인가 코드 바인딩, 두 축이 겹치는 지점.

## 참고

- RFC 7636 §1(위협 모델), §4.1–4.6(파라미터·검증), §7.1–7.2(엔트로피·다운그레이드)
- RFC 6749 §4.1 Authorization Code Grant
- OAuth 2.0 Security Best Current Practice (draft) — confidential 클라이언트 PKCE 권장

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
