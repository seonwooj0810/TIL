# Outbox Pattern: Polling vs CDC (Debezium)

> **Primary source:** Microservices Patterns (Chris Richardson) Ch.3 — "Transactional messaging" (§3.3 Transactional outbox, Polling publisher, Transaction log tailing)
> **Secondary:** Debezium Documentation (Outbox Event Router, MySQL/Postgres connector), Kafka Connect docs
> **Date:** 2026-06-09
> **Status:** draft

## 왜 봤나

- "이벤트는 트랜잭션 커밋되면 발행하면 되지 않나"라고 막연히 생각했는데, **DB 커밋과 메시지 발행이 별개 트랜잭션**이라는 점이 dual write 문제의 핵심이라는 걸 정리하고 싶었다.
- Outbox를 "그냥 테이블에 쌓고 읽어서 보내는 것"으로만 알았는데, 그 "읽어서 보내는" 부분이 Polling이냐 CDC(log tailing)냐로 갈리고 보장 수준·부하가 완전히 다르다.

## 핵심 한 문장

> 비즈니스 데이터 변경과 "발행할 이벤트"를 **하나의 로컬 DB 트랜잭션**으로 같은 DB의 OUTBOX 테이블에 함께 쓰고(원자성 확보), 그 테이블을 별도 프로세스가 Polling 혹은 트랜잭션 로그 tailing(CDC)으로 읽어 브로커에 발행하는 패턴 — dual write 문제를 "단일 DB 트랜잭션 + 비동기 relay"로 분해한다.

## 내부 동작

### 0. 풀려는 문제 — dual write

서비스가 주문을 저장하고 `OrderCreated`를 카프카에 보내야 한다고 하자. 순진한 코드는:

```java
orderRepository.save(order);        // (1) DB commit
kafkaTemplate.send("orders", evt);  // (2) broker send
```

(1)과 (2)는 서로 다른 저장소에 대한 별개 쓰기다. (1) 직후 프로세스가 죽으면 주문은 있는데 이벤트는 없다. (2)가 먼저 나가고 (1)이 롤백되면 유령 이벤트가 나간다. Richardson은 이를 **dual write problem**으로 부르고, 분산 트랜잭션(2PC)은 브로커·DB가 XA를 지원해야 하고 가용성을 떨어뜨려 마이크로서비스에서 기피한다고 정리한다.

### 1. Transactional Outbox — 원자성 확보

해법은 (2)를 같은 DB 안으로 끌어오는 것이다. 발행할 메시지를 같은 트랜잭션에서 OUTBOX 테이블에 INSERT 한다.

```
BEGIN;
  INSERT INTO orders(...)  VALUES (...);
  INSERT INTO outbox(id, aggregate_type, aggregate_id, type, payload, created_at)
         VALUES (...);
COMMIT;          -- 두 INSERT가 원자적. 둘 다 커밋되거나 둘 다 롤백.
```

이제 "주문 존재 ⟺ outbox 레코드 존재"가 DB 한 트랜잭션의 원자성으로 보장된다. 남은 일은 outbox의 행을 브로커로 옮기는 **Message Relay**다. 여기가 두 갈래로 갈린다.

### 2. 방법 A — Polling Publisher

별도 프로세스가 주기적으로 outbox를 폴링한다.

```sql
SELECT * FROM outbox ORDER BY id ASC LIMIT 100;   -- 미발행분 조회
-- 각 행을 브로커에 publish
DELETE FROM outbox WHERE id IN (...);             -- 또는 processed 플래그 UPDATE
```

자료구조 관점에서 outbox 테이블은 **id(또는 created_at) 기준 정렬된 FIFO 큐**처럼 동작하고, relay는 그 위를 커서로 훑는다. 단순하고 어떤 DB에서도 되지만 단점이 분명하다.

- **폴링 주기 ↔ 지연 트레이드오프**: 주기를 짧게 하면 부하↑, 길게 하면 이벤트 지연↑.
- 처리 후 DELETE 대신 `processed` 컬럼을 UPDATE 하는 변형은 테이블이 비대해져 인덱스 스캔 비용↑.
- 멀티 인스턴스 relay 시 같은 행 중복 처리 방지를 위해 `SELECT ... FOR UPDATE SKIP LOCKED` 같은 잠금이 필요.

### 3. 방법 B — Transaction Log Tailing (CDC, Debezium)

Richardson이 "Polling의 비효율을 피하는" 방식으로 드는 것이 **transaction log tailing**이다. 폴링 대신 DB의 **커밋 로그**(MySQL binlog, PostgreSQL WAL)를 구독한다. Debezium이 이 구현체다.

핵심은 outbox 테이블에 발생한 INSERT가 **커밋 로그에 물리적 변경 이벤트로 기록**된다는 점이다. Debezium 커넥터는:

1. DB에 복제 클라이언트로 붙는다 (MySQL: binlog dump 프로토콜로 replica인 척, Postgres: logical replication slot).
2. 로그를 스트리밍하며 outbox 테이블의 INSERT row 이벤트를 디코딩.
3. **Outbox Event Router** SMT(Single Message Transform)가 그 행의 `aggregate_type`/`payload` 컬럼을 읽어 적절한 카프카 토픽·키로 라우팅.
4. 처리 위치(binlog offset / LSN)를 Kafka Connect의 offset topic에 커밋해 재시작 시 그 지점부터 재개.

```
  App TX                  DB                    Debezium               Kafka
   │  INSERT order+outbox  │                       │                     │
   ├──────────────────────▶│ commit → WAL/binlog   │                     │
   │                       │ ────────로그 append────│                     │
   │                       │      (tail/stream)    │                     │
   │                       │ ─────row event───────▶│  SMT route          │
   │                       │                       │ ───produce(key)────▶│
   │                       │                       │  offset commit      │
```

폴링이 없으므로 추가 쿼리 부하가 0에 가깝고, 지연은 로그가 쓰이는 즉시 → near-real-time. 대신 운영 복잡도(Kafka Connect, 커넥터, 복제 권한)가 올라간다.

### 4. 전달 보장 — 왜 at-least-once인가

두 방식 모두 relay는 "발행 → 진행 위치 기록" 순서로 동작한다. 발행 성공 후 위치 기록 전에 죽으면 재시작 시 같은 메시지를 다시 보낸다. 따라서 둘 다 기본적으로 **at-least-once**다. exactly-once가 아니다. 결과적으로:

- 메시지에 안정적인 ID(outbox row id)를 실어 **소비자가 멱등 처리**(idempotent consumer)하도록 설계해야 한다 — Richardson도 이 조합을 권한다.

### 5. 비교 표

| 항목 | Polling Publisher | Log Tailing (CDC/Debezium) |
| --- | --- | --- |
| 트리거 | 주기적 SELECT | 커밋 로그 스트림 |
| 지연 | 폴링 주기에 종속 | near-real-time |
| DB 부하 | 폴링 쿼리 반복 | 복제 스트림 1개 (낮음) |
| 추가 인프라 | 거의 없음 | Kafka Connect + 커넥터 |
| 순서 보장 | 정렬 쿼리에 의존 | 로그 순서 그대로 |
| 전달 보장 | at-least-once | at-least-once |
| 운영 난이도 | 낮음 | 중~높음 |

## 검증

출처 흐름을 따라가 본 경로:

1. Richardson Ch.3 §3.3.1 "dual write" → 단일 DB 트랜잭션으로 묶을 수 없는 두 저장소가 문제의 근원.
2. §3.3.4 Polling publisher → outbox를 주기 쿼리로 훑고 발행 후 삭제/마킹.
3. §3.3.5 Transaction log tailing → 로그를 읽어 발행, 폴링 부하 제거.
4. Debezium 문서의 **Outbox Event Router** 예제 → outbox 테이블 스키마(`aggregateid`, `type`, `payload`)와 토픽 라우팅 규칙이 Richardson의 추상 패턴과 1:1로 대응함을 확인.

즉 "원자성은 로컬 트랜잭션이, 발행은 relay가, 멱등은 소비자가" 책임지는 3단 분해 구조다.

## 잘못 알고 있던 것

- **"Outbox를 쓰면 exactly-once가 된다"** → 아니다. Outbox가 보장하는 것은 "비즈니스 변경과 이벤트 기록의 원자성"일 뿐, 발행 자체는 relay 재시작으로 중복될 수 있어 **at-least-once**다. 정확히 한 번 처리는 소비자 멱등성으로 만든다.
- **"CDC면 outbox 테이블이 필요 없다"** → CDC로 비즈니스 테이블을 직접 캡처할 수도 있지만, 그러면 발행할 이벤트의 형태가 테이블 스키마에 종속되고 도메인 이벤트 의미를 표현하기 어렵다. Debezium도 "Outbox Event Router"를 별도로 두는 이유가 이것 — outbox는 **의도된 이벤트 페이로드**를 명시적으로 담는 안티커럽션 계층이다.
- **"Polling은 구식이라 항상 CDC가 낫다"** → 운영 인프라가 없거나 트래픽이 적으면 Polling이 더 단순하고 충분하다. CDC는 Kafka Connect/복제 슬롯 운영 비용을 동반한다.

## 더 파고들 만한 것

- Debezium Postgres 커넥터의 **logical replication slot**이 소비되지 않을 때 WAL이 무한정 쌓이는 문제와 운영 모니터링.
- Idempotent Consumer 구현 — 처리한 message id를 별도 테이블에 기록하는 방식과 그 정리(GC) 전략.

## 참고

- Microservices Patterns (Chris Richardson) Ch.3 — Transactional outbox / Polling publisher / Transaction log tailing
- Debezium Documentation — Outbox Event Router (SMT), MySQL & PostgreSQL connectors
- Kafka Connect — offset management
