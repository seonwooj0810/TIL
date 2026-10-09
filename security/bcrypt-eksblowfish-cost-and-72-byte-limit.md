# bcrypt의 cost는 키 스케줄을 2^cost번 다시 돌리는 것이다 — EksBlowfish 구조와 72바이트 한계가 생기는 자리

> **Primary source:** Spring Security `crypto/.../bcrypt/BCrypt.java`(`key`, `ekskey`, `streamtowords`, `crypt_raw`, `hashpw`, `checkpw`), `BCryptPasswordEncoder.java` (spring-projects/spring-security main)
> **Secondary:** Provos & Mazières, "A Future-Adaptable Password Scheme" (USENIX 1999, https://www.openbsd.org/papers/bcrypt-paper.ps — `BCrypt.java`의 `ekskey` 주석이 인용) / Spring Security Advisory CVE-2025-22228
> **Date:** 2026-10-09
> **Status:** draft

## 왜 봤나

- bcrypt는 "느린 해시"로만 소개되는 경우가 많다. 그런데 실제로는 해시 함수가 아니라 **블록 암호(Blowfish)의 키 스케줄을 비싸게 만든 것**이고, cost·salt·72바이트 한계·`$2a$/$2b$/$2y$` 접두사가 전부 이 키 스케줄 구조에서 나온다.
- 앞서 본 Argon2 노트(`security/argon2-memory-hard-password-hashing.md`)의 후속 질문 — "bcrypt의 cost는 왜 메모리는 안 늘리고 시간만 늘리나" — 에 소스로 답한다.

## 핵심 한 문장

> bcrypt는 Blowfish 상태(P 18워드 + S 1024워드)를 비밀번호와 salt로 **2^cost번 번갈아 재키잉**한 뒤, 그 상태로 고정 평문 `"OrpheanBeholderScryDoubt"`를 64번 암호화한 결과를 해시로 쓴다 — 키 재료는 P 배열 18워드(=72바이트)만큼만 소비되므로 그 뒤 바이트는 결과에 영향이 없다.

## 내부 동작

### 1. 상태: 4KB 남짓의 Blowfish 키 스케줄

`BCrypt.java`의 초기 상태는 상수 테이블 두 개다. 소스에서 세어 보면 `P_orig`는 **18개**, `S_orig`는 **1024개**의 32비트 워드(파이 소수부 기반 Blowfish 상수)다. `init_key()`가 이것을 복제해 작업 상태 `P`, `S`를 만든다. 즉 bcrypt 한 인스턴스가 들고 다니는 상태는 약 4KB(S) + 72B(P)로 **고정**이다. cost를 올려도 이 크기는 변하지 않는다.

### 2. `key()` — 표준 Blowfish ExpandKey

```
key(K):
  for i in 0..17:  P[i] ^= streamtoword(K)     // K를 순환하며 4바이트씩
  lr = (0,0)
  for i in 0,2,..,16:   lr = encipher(lr); P[i],P[i+1] = lr   //  9회
  for i in 0,2,..,1022: lr = encipher(lr); S[i],S[i+1] = lr   // 512회
```

핵심은 두 가지다.
- 키는 **P 18워드에 XOR되는 만큼만** 읽힌다. `streamtowords`는 `off = (off + 1) % data.length`로 키 바이트를 **순환** 읽기 때문에, 짧은 키는 반복되고 긴 키는 18×4 = **72바이트 이후가 아예 읽히지 않는다.**
- 그 뒤 P·S 전체를 "현재 상태로 암호화한 출력"으로 덮어쓴다. 상태가 다음 암호화 입력을 결정하므로 **순차 의존 사슬**이다. 한 번의 `key()`에 encipher가 9 + 512 = 521번 돈다.

### 3. `ekskey()` — salt를 섞는 1회성 확장 (EksBlowfishSetup의 첫 단계)

`ekskey(salt, password)`는 `key()`와 같지만 P/S를 채울 때 `lr`에 **salt 워드를 XOR한 뒤** 암호화한다(`lr[0] ^= streamtoword(data, doffp)`). 그래서 같은 비밀번호라도 salt(16바이트, `BCRYPT_SALT_LEN = 16`)가 다르면 초기 상태부터 갈라진다.

### 4. `crypt_raw()` — cost가 들어가는 자리

```
init_key()
ekskey(salt, password)
for i in 0 .. 2^log_rounds - 1:      // roundsForLogRounds = 1L << log_rounds
    key(password)
    key(salt)
repeat 64:  cdata = ECB-encrypt("OrpheanBeholderScryDoubt")   // 6워드 = 3블록
return cdata (24바이트)
```

```
  password ─┐          ┌──────── 2^cost 회 반복 ────────┐
  salt ─────┼─ ekskey ─┤  key(password) → key(salt)      ├─ 64× encrypt(IV) ─ 24B
            │          └─────────────────────────────────┘
       P[18],S[1024]      매 key()마다 encipher 521회
```

- cost(`log_rounds`)는 **지수**다. 소스는 4~31만 허용(`MIN_LOG_ROUNDS = 4`, `MAX_LOG_ROUNDS = 31`)하고 기본값은 10(`GENSALT_DEFAULT_LOG2_ROUNDS`). cost를 1 올리면 루프가 정확히 2배가 된다.
- 반복당 `key()` 2번 = encipher 1042번이므로, cost 10이면 대략 1042 × 1024 ≈ 100만 번의 Blowfish 블록 암호화가 **앞 단계 결과에 의존해 순차적으로** 일어난다. 병렬로 쪼갤 수 없는 지연이다.
- 반면 상태 크기는 4KB 고정이다. 그래서 bcrypt는 "시간은 조절 가능하지만 메모리는 조절 불가"다 — Argon2의 `m` 파라미터 같은 축이 없다.

### 5. 출력 포맷과 `hashpw()`의 전처리

`$2a$10$` + salt 22자 + 해시 31자 = 60자. `encode_base64(hashed, bf_crypt_ciphertext.length * 4 - 1, rs)` — 24바이트 중 **23바이트만** 인코딩한다(마지막 바이트 버림). `BCryptPasswordEncoder`의 정규식 `\A\$2(a|y|b)?\$(\d\d)\$[./0-9A-Za-z]{53}`의 53이 22+31이다.

`hashpw()`는 minor 버전이 `'a'` 이상(`a`,`b`,`x`,`y`)이면 `Arrays.copyOf(passwordb, length + 1)`로 **끝에 NUL 바이트를 붙인다**. C 문자열 종단자까지 키로 쓰던 원 구현과 호환하기 위함이다. 이 NUL도 72바이트 창 안에 들어가야 의미가 있다 — 72바이트 비밀번호면 NUL은 73번째라 읽히지 않는다.

### 6. `$2x$`/`$2y$`와 부호 확장 버그

`streamtowords`는 한 번에 두 워드를 만든다: 올바른 `(data[off] & 0xff)`와 버그 재현용 `data[off]`(byte → int **부호 확장**). 0x80 이상의 바이트(비ASCII)가 있으면 버그 버전에서 상위 비트가 1로 번져 다른 키가 된다. `hashpw`는 `crypt_raw(..., minor == 'x', minor == 'a' ? 0x10000 : 0, ...)`로 호출한다.
- `$2x$`: 버그 동작을 **그대로 재현**(옛 해시 검증용).
- `$2a$`: 올바르게 계산하되, "버그 버전과 정확히 같은 확장 키가 나오면서 비자명한 부호 확장이 있었던" 경우에만 `P[0]`의 16번 비트를 뒤집는 **safety measure**를 건다(`diff`/`sign` 비트 연산). 버그 구현에서 만들어진 여러 비밀번호가 하나의 올바른 해시로 충돌하는 것을 막기 위한 장치라고 소스 주석이 설명한다.
- `$2y$`, `$2b$`: safety 없이 올바른 알고리즘.

## 검증

(a) 72바이트 경계 — Spring Security 6.4.4+/6.3.8+ 기준. JShell에서 `spring-security-crypto`를 클래스패스에 두고:

```java
import org.springframework.security.crypto.bcrypt.BCrypt;

String p72 = "x".repeat(72);
String h   = BCrypt.hashpw(p72, BCrypt.gensalt(4, new java.security.SecureRandom()));
BCrypt.checkpw(p72 + "anything-after", h);   // true  — 73바이트 이후는 키에 안 들어감
BCrypt.hashpw(p72 + "y", BCrypt.gensalt(4, new java.security.SecureRandom()));
// IllegalArgumentException: password cannot be more than 72 bytes  (신규 해싱만 거부)
```

`checkpw`는 내부적으로 `hashpwforcheck`(for_check=true)라 길이 검사를 건너뛰고, 순환 읽기 규칙 때문에 앞 72바이트만으로 같은 해시가 나온다. 이 동작은 커밋 `c1aa99fdd2`("Enforce BCrypt password length for new passwords only")의 테스트 `matchesWhenPasswordOverMaxLengthThenAllowToMatch`가 하위호환 목적으로 명시한다.

(b) cost 지수성 — 같은 JShell에서 `gensalt(10, rnd)`, `gensalt(11, rnd)`, `gensalt(12, rnd)`(`rnd`는 `SecureRandom`)로 `hashpw` 시간을 재면 대략 2배씩 늘어나는 것을 볼 수 있다(절대값은 머신마다 다름).

(c) 소스 포인터: `BCrypt.java`의 `crypt_raw`에서 `for (int i = 0; i < rounds; i++) { key(password, ...); key(salt, false, ...); }` 루프와 `for (int i = 0; i < 64; i++)` 최종 암호화 루프를 직접 확인할 수 있다.

## 잘못 알고 있던 것

- **"bcrypt는 입력을 해시한다."** 실제로는 입력이 **블록 암호의 키**가 되고, 해시값은 고정 평문 `"OrpheanBeholderScryDoubt"`의 암호문이다. 그래서 길이 제한이 해시 함수의 블록 크기가 아니라 Blowfish **P 배열 크기(18워드 = 72바이트)**에서 나온다. 문자 수가 아니라 **UTF-8 바이트** 기준이므로 한글(3바이트)이면 24자 남짓에서 이미 잘린다.
- **"72바이트 넘으면 에러가 나니 안전하다."** CVE-2025-22228 이전 Spring Security(예: 6.4.0~6.4.3)는 아무 경고 없이 잘라 `matches()`가 앞 72자만 같으면 true를 돌려줬다(advisory 원문). 수정 후에도 **`encode()`만** 거부하고 `matches()`는 기존 해시 호환 때문에 여전히 72바이트 이후를 무시한다. "비밀번호 앞에 고정 prefix(예: userId+pepper)를 이어 붙이는" 설계는 그 prefix가 72바이트 예산을 갉아먹는다.
- **"cost를 올리면 GPU 공격도 memory-hard하게 막힌다."** cost는 순차 연산 횟수만 늘린다. 상태는 4KB로 고정이라 메모리 축 방어는 없다. 메모리 비용까지 조절하려면 Argon2/scrypt 계열이 필요하다.

## 더 파고들 만한 것

- Blowfish `encipher`의 F 함수(S-box 4개 조회)가 4KB 상태를 랜덤 접근하는 패턴 — GPU 공유메모리 경합과 bcrypt 크래킹 속도의 관계.
- 72바이트 한계를 우회하는 pre-hash(HMAC/SHA-256 후 base64) 방식과, raw 바이너리를 넘길 때 NUL 바이트로 잘리는 함정.

## 참고

- Spring Security `BCrypt.java` / `BCryptPasswordEncoder.java` (main), 커밋 `46f0dc6dfc`(Enforce BCrypt password length), `c1aa99fdd2`(new passwords only)
- https://spring.io/security/cve-2025-22228
- Provos & Mazières (1999) — https://www.openbsd.org/papers/bcrypt-paper.ps
- 연관 노트: `security/argon2-memory-hard-password-hashing.md` (Argon2: 메모리를 채워야만 계산되게 만들어 GPU 병렬 크래킹을 무력화하는 법)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
