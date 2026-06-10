# Idempotency Key 설계 패턴

> **Primary source:** Stripe API Reference — Idempotent requests (https://docs.stripe.com/api/idempotent_requests)
> **Secondary:** Stripe Documentation — Advanced error handling / API v2 overview
> **Date:** 2026-06-10
> **Status:** draft

## 왜 봤나

- 결제 API에서 "재시도해도 한 번만 처리된다"는 말을 자주 쓰지만, 실제 보장은 HTTP 메서드의 멱등성만으로 나오지 않는다.
- Idempotency Key를 단순 중복 방지 토큰으로만 봤는데, Stripe 문서를 따라가 보니 **요청 파라미터 검증, 실행 시작 시점, 결과 캐시 TTL**이 함께 있어야 오작동을 줄일 수 있었다.

## 핵심 한 문장

> Idempotency Key는 클라이언트가 "같은 비즈니스 시도"에 같은 키를 붙이고, 서버가 그 키에 대해 최초 실행 결과를 저장한 뒤 동일 키 재시도에는 새 부작용을 만들지 않고 저장된 결과를 돌려주는 API 계층의 재시도 안전장치다.

## 내부 동작

### 1. 풀려는 문제: 응답을 못 받은 성공

네트워크 실패는 "서버가 처리하지 못함"과 "서버는 처리했지만 클라이언트가 응답을 못 받음"을 구분해 주지 않는다. 결제 생성 요청에서 커넥션이 끊기면 클라이언트는 다음 둘 중 무엇인지 모른다.

```text
case A: request never reached server  -> retry should create charge
case B: server created charge, response lost -> retry must not create another charge
```

공식 문서에 따르면 Stripe API v1의 idempotency는 클라이언트가 만든 키를 서버가 재시도 식별자로 사용한다. 같은 키의 첫 요청에서 나온 status code와 body를 저장하고, 이후 같은 키 요청에는 성공뿐 아니라 `500` 오류까지 같은 결과를 돌려준다. 즉 "성공만 캐시"가 아니라 **최초 실행 결과 캐시**에 가깝다.

### 2. 서버 쪽 자료구조

구현을 일반화하면 서버는 idempotency store를 둔다. DB 테이블이나 Redis 같은 저장소일 수 있지만, 핵심 컬럼은 비슷하다.

```text
idempotency_record(
  scope,              -- account / API version / endpoint 같은 격리 범위
  key,                -- Idempotency-Key
  request_fingerprint,-- method + path + normalized params hash
  state,              -- IN_PROGRESS | COMPLETED
  status_code,
  response_body,
  created_at,
  expires_at
)

unique(scope, key)
```

`scope + key`에 unique 제약이 있어야 두 요청이 동시에 들어와도 둘 다 "최초"가 될 수 없다. `request_fingerprint`는 같은 키를 다른 의미의 요청에 재사용하는 실수를 막기 위한 값이다. Stripe 문서도 idempotency layer가 들어온 파라미터를 원래 요청과 비교하고, 같지 않으면 accidental misuse를 막기 위해 오류를 낸다고 설명한다.

### 3. 상태 전이

Idempotency Key 처리는 작은 상태 머신으로 볼 수 있다.

```text
                 same params, completed
       ┌──────────────────────────────────────┐
       │                                      ▼
NEW ──insert──▶ IN_PROGRESS ──execute──▶ COMPLETED
 │                 │              │             │
 │ duplicate       │ conflict     │ save result │ replay saved
 ▼                 ▼              ▼             ▼
WAIT/CONFLICT   retry later     status+body    same status+body

same key + different params ───────────────▶ IDEMPOTENCY_ERROR
expired/pruned key ────────────────────────▶ treated as NEW
```

중요한 분기점은 "언제 결과를 저장하느냐"다. Stripe 문서에 따르면 endpoint execution이 시작된 뒤에만 결과를 저장한다. 들어온 파라미터가 validation에서 실패하거나, 같은 키의 다른 요청이 동시에 실행 중이라 endpoint 실행이 시작되지 않은 경우에는 idempotent result를 저장하지 않는다. 그래서 그런 요청은 다시 재시도할 수 있다.

이 규칙이 없으면 검증 실패 하나가 키를 영구히 오염시킬 수 있다. 반대로 실행이 시작된 뒤의 실패는 저장된다. 이 선택은 클라이언트 입장에서 "서버가 부작용을 만들었을 수도 있는 구간"을 재실행하지 않게 만드는 쪽에 가깝다.

### 4. 요청 처리 알고리즘

의사 코드로 줄이면 다음과 같다.

```java
Response handle(Request req) {
    String key = req.header("Idempotency-Key");
    Fingerprint fp = fingerprint(req.method(), req.path(), req.params());

    IdempotencyRecord r = store.find(scope(req), key);
    if (r != null && r.completed()) {
        if (!r.fingerprint().equals(fp)) throw idempotencyError();
        return new Response(r.statusCode(), r.responseBody());
    }
    if (r != null && r.inProgress()) {
        if (!r.fingerprint().equals(fp)) throw idempotencyError();
        throw concurrentRequestConflict();
    }

    store.insertInProgress(scope(req), key, fp); // unique(scope,key)
    try {
        Response response = executeEndpoint(req);
        store.markCompleted(scope(req), key, response.status(), response.body());
        return response;
    } catch (Throwable t) {
        Response error = mapToHttpResponse(t);
        store.markCompleted(scope(req), key, error.status(), error.body());
        return error;
    }
}
```

실제 구현은 트랜잭션 경계가 더 까다롭다. `insertInProgress`와 endpoint의 비즈니스 DB 변경이 같은 DB에 있지 않으면 dual write 문제가 생긴다. 예를 들어 결제 row는 생성됐는데 idempotency 결과 저장 전에 프로세스가 죽을 수 있다. 그래서 실무 구현은 다음 중 하나로 좁혀진다.

- idempotency record와 비즈니스 변경을 같은 트랜잭션에 넣는다.
- 비즈니스 객체 자체에 `idempotency_key` unique 제약을 둬서 재시도 시 기존 객체를 조회한다.
- 외부 결제 게이트웨이처럼 서버 내부 구현이 감춰진 경우, 클라이언트는 제공자가 문서화한 재시도 보장만 신뢰한다.

Stripe는 내부 저장소를 공개하지 않지만, 문서화된 동작만으로도 설계 방향은 보인다. "키별 최초 결과 저장"과 "파라미터 비교"와 "실행 시작 전 실패는 미저장"이 한 세트다.

### 5. TTL과 키 생성

Stripe 문서에 따르면 idempotency key는 최대 255자이고, 충분한 엔트로피의 random string이나 UUID v4를 권장한다. 민감한 데이터는 키에 넣지 말라고도 한다. 또한 key는 최소 24시간이 지난 뒤 시스템에서 제거될 수 있고, 제거된 뒤 같은 키가 재사용되면 새 요청으로 처리된다.

TTL은 저장소 크기를 제한하는 운영 장치지만, 보장 범위도 함께 정한다. 24시간 이후 재시도까지 "절대 중복 없음"을 기대하면 안 된다. 클라이언트가 같은 주문 생성 시도를 며칠 뒤 재개해야 한다면, Idempotency-Key만 믿기보다 주문 번호 같은 비즈니스 키에 unique 제약을 추가해야 한다.

### 6. HTTP 메서드와 의미

Stripe API v1 문서에 따르면 모든 `POST` 요청은 idempotency key를 받을 수 있고, `GET`과 `DELETE`에는 보내지 말라고 한다. 두 메서드는 정의상 멱등이므로 key가 효과가 없다는 설명이다. 다만 여기서 헷갈리면 안 되는 점은 "HTTP 메서드가 멱등"과 "비즈니스 요청이 재시도 안전"이 다르다는 것이다.

`POST /charges`는 HTTP 관점에서 멱등이 아니지만 key를 통해 같은 생성 시도를 한 번으로 묶을 수 있다. 반대로 `DELETE /resource/1`은 여러 번 호출해도 최종 상태가 삭제로 수렴하므로 멱등으로 분류된다. Idempotency Key는 특히 "생성/갱신이 부작용을 만들고, 응답 손실 후 재시도가 필요한" 경로에서 가치가 크다.

## 검증

출처 흐름을 따라가며 확인한 내용:

1. Stripe API Reference의 Idempotent requests는 첫 요청의 status code와 body를 저장하고, 이후 같은 key에 같은 결과를 반환한다고 설명한다. 실패 응답 중 `500`도 포함된다.
2. 같은 문서는 키 재사용 시 파라미터가 원래 요청과 다르면 오류를 내며, key는 최소 24시간 뒤 제거될 수 있다고 설명한다.
3. 저장 시점은 endpoint execution이 시작된 뒤다. validation 실패나 concurrent conflict처럼 endpoint가 시작되지 않은 경우에는 결과를 저장하지 않아 재시도 가능하다.
4. Advanced error handling 문서는 `POST` 요청에 idempotency key를 포함하면 중복 operation 방지를 위한 record keeping이 수행된다고 설명한다.

이 흐름으로 보면 Idempotency Key 설계의 핵심은 단순한 "중복 요청 무시"가 아니다. **같은 키인지, 같은 요청인지, 실행이 시작됐는지, 결과를 저장했는지**를 구분하는 상태 관리다.

## 잘못 알고 있던 것

- **"멱등키는 성공했을 때만 저장하면 된다"** → Stripe API v1 문서 기준으로는 첫 요청의 결과가 실패여도 저장된다. 특히 실행이 시작된 뒤의 `500`도 같은 키 재시도에 동일하게 반환된다.
- **"같은 키면 항상 같은 요청으로 보면 된다"** → 아니다. 같은 키에 다른 파라미터가 오면 클라이언트 버그일 가능성이 높다. request fingerprint 비교가 없으면 전혀 다른 결제 생성이 이전 응답으로 덮여 보일 수 있다.
- **"TTL은 내부 정리일 뿐 보장과 무관하다"** → 아니다. 키가 pruning된 뒤 재사용되면 새 요청으로 처리될 수 있다. 장기 중복 방지는 별도의 비즈니스 unique key가 필요하다.

## 더 파고들 만한 것

- Idempotency store와 비즈니스 DB가 분리될 때 생기는 dual write 문제를 Outbox/transactional write로 줄이는 방법.
- Kafka idempotent producer의 producer id/sequence number 방식과 HTTP Idempotency-Key 방식의 차이.

## 참고

- Stripe API Reference — Idempotent requests: https://docs.stripe.com/api/idempotent_requests
- Stripe Documentation — Advanced error handling: https://docs.stripe.com/error-low-level
- Stripe API v2 overview — Idempotency differences between API v1 and API v2: https://docs.stripe.com/api-v2-overview
