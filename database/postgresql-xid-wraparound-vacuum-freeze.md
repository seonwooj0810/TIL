# PostgreSQL 트랜잭션 ID(XID) Wraparound과 VACUUM Freeze

> **Primary source:** PostgreSQL 18 공식 문서 §24.1.5 "Preventing Transaction ID Wraparound Failures" (routine-vacuuming.html)
> **Secondary:** PostgreSQL 18 Docs §24.1 Routine Vacuuming (VACUUM-BASICS, VACUUM-FOR-VISIBILITY-MAP)
> **Date:** 2026-09-16
> **Status:** draft

## 왜 봤나

- MVCC를 배우고 나면 "VACUUM = 죽은(dead) 튜플 청소해서 디스크 공간 회수"로만 이해하기 쉽다. 그런데 공식 문서는 VACUUM의 목적을 네 가지로 나열하면서 그중 하나로 "트랜잭션 ID wraparound으로 인한 아주 오래된 데이터 손실 방지"를 별도로 꼽는다. 즉 INSERT만 하고 UPDATE/DELETE가 전혀 없는 테이블도, 회수할 죽은 튜플이 없는데도 반드시 주기적으로 vacuum(freeze)되어야 한다.
- "얼마나 자주" vacuum해야 하는가가 죽은 튜플 비율이 아니라 XID 카운터의 유한성(32bit)에서 나온다는 점이 이 메커니즘의 핵심이며, 자주 오해되는 지점이다.

## 핵심 한 문장

> XID는 32비트 순환 카운터라서 절대 순서가 아니라 modulo-2^32 상대 비교로 "과거/미래"를 가르기 때문에, VACUUM은 이 비교가 뒤집히기 전에 오래된 튜플을 특수 XID인 FrozenTransactionId로 동결시켜 "영원히 과거"로 고정함으로써 wraparound를 막는다.

## 내부 동작

### 1. XID 비교가 순환(circular)인 이유

PostgreSQL의 각 트랜잭션에는 32bit XID가 할당되고, 튜플의 `xmin`(삽입 트랜잭션)과 현재 트랜잭션의 XID를 비교해 가시성을 판정한다. 그런데 32bit 카운터는 유한하므로 40억 개 트랜잭션을 넘기면 반드시 다시 0부터 시작(wraparound)해야 한다. 그래서 공식 문서는 비교를 절대순서가 아니라 **modulo-2^32 산술**로 정의한다: 임의의 정상 XID를 기준으로 그보다 "20억개 더 오래된" XID와 "20억개 더 최신인" XID가 항상 존재하는 원형(circular) 공간이다.

문제는 여기서 발생한다. 어떤 튜플이 특정 XID로 삽입된 뒤 동결(freeze)되지 않은 채로 20억 트랜잭션 이상 살아남으면, 그 XID는 원형 공간을 한 바�퀴 돌아 갑자기 "미래"로 해석된다. 방금 전까지 모든 트랜잭션에 보이던(committed, in the past) 행이 순식간에 "아직 커밋 안 된 미래 트랜잭션의 행"으로 뒤집혀 보이지 않게 된다. 데이터가 물리적으로 사라지는 건 아니지만 더 이상 어떤 쿼리로도 접근할 수 없으므로 문서는 이를 "catastrophic data loss"라고 명시한다.

### 2. Freeze: FrozenTransactionId로 순서 비교에서 탈출

이 문제를 원천 차단하는 방법은 오래된 튜플을 일반 XID 비교 규칙에서 아예 빼버리는 것이다. PostgreSQL은 `FrozenTransactionId`라는 특수 XID를 예약해 두고, 이 값은 항상 다른 모든 정상 XID보다 "더 과거"로 취급되도록 비교 규칙 자체에서 예외 처리한다. 9.4 이전에는 튜플의 실제 `xmin`을 `FrozenTransactionId`(값 2)로 덮어써서 freeze했지만, 이후 버전은 `xmin`을 물리적으로 바꾸지 않고 인포마스크(infomask) 플래그 비트만 세워 "동결됨"을 표시한다 — 포렌식 목적으로 원래 삽입 XID를 보존하기 위해서다.

### 3. 언제 freeze하는가 — 두 종류의 VACUUM

- **일반 VACUUM**은 visibility map을 참조해 "이미 all-visible한 페이지"는 건너뛴다. 이 페이지에는 죽은 튜플이 없으니 청소할 게 없기 때문이다. 하지만 이 스킵 로직 때문에 오래된 XID를 가진 튜플이 계속 freeze되지 않고 방치될 수 있다 — "all-visible이지만 all-frozen은 아닌" 페이지가 쌓인다.
- **aggressive VACUUM**은 `relfrozenxid`의 나이가 `vacuum_freeze_table_age`를 넘으면 발동하며, all-visible-but-not-all-frozen 페이지를 포함해 동결 대상이 될 수 있는 모든 페이지를 강제로 스캔해 freeze한다. `vacuum_freeze_table_age`의 유효 상한은 `0.95 * autovacuum_freeze_max_age`로 캡핑되는데, 이는 그 이상으로 늦추면 어차피 anti-wraparound autovacuum이 발동해버려 의미가 없고, 0.95 배수는 그 전에 수동 VACUUM을 돌릴 여유를 남겨두기 위함이라고 문서는 설명한다.
- 최근 버전은 **eager scanning**(`vacuum_max_eager_freeze_failure_rate`로 튜닝)을 통해 일반 VACUUM도 all-visible-but-not-frozen 페이지 일부를 미리 동결 시도해, 다음 aggressive VACUUM이 스캔해야 할 페이지 수를 줄인다.

### 4. 강제 발동 임계값과 추적 컬럼

`autovacuum_freeze_max_age`(기본 2억 트랜잭션)에 도달하면, autovacuum이 전역적으로 꺼져 있어도 **해당 테이블에 한해 강제로 autovacuum이 발동한다** — 문서 원문 그대로 "This will happen even if autovacuum is disabled." 각 테이블의 `pg_class.relfrozenxid`는 가장 최근 성공한 aggressive VACUUM이 끝난 시점의 "가장 오래된 미동결 XID"를 기록하고, `pg_database.datfrozenxid`는 그 데이터베이스 내 모든 `relfrozenxid`의 최솟값이다.

### 5. 위기 단계별 상태 전이

```
정상 운영
  │  autovacuum_freeze_max_age(기본 2억 tx) 도달
  ▼
강제 autovacuum 발동 (autovacuum 꺼져 있어도)
  │  그래도 못 따라잡으면...
  ▼
wraparound까지 4천만 tx 남음
  → WARNING: database "mydb" must be vacuumed within N transactions
  │  경고 무시하면...
  ▼
wraparound까지 3백만 tx 남음
  → ERROR: 새 XID 발급 거부 (읽기 전용 트랜잭션만 시작 가능,
    진행 중이던 트랜잭션은 계속되지만 쓰기/TRUNCATE는 실패)
  │
  ▼
복구: postmaster 중단·single-user mode ✗ (구버전 권고, 현재는 비권장)
  대신 온라인 상태에서
   1) pg_prepared_xacts의 오래된 in-doubt 트랜잭션 commit/rollback
   2) pg_stat_activity의 장기 실행 트랜잭션 종료
   3) pg_replication_slots의 죽은 복제 슬롯 삭제
   4) 데이터베이스 전체 VACUUM (시스템 카탈로그까지 진행하려면 superuser 필요)
```

VACUUM FULL은 자체적으로 새 XID를 소비하므로 이 비상 상황에서 오히려 wraparound 위험을 키워 사용을 피해야 하고, VACUUM FREEZE도 최소한의 복구에 필요한 것보다 더 많은 작업을 하므로 권장되지 않는다고 문서는 명시한다.

## 검증

문서가 제시하는 진단 쿼리를 자신의 PostgreSQL 인스턴스에서 그대로 실행해 각 테이블/데이터베이스가 wraparound까지 얼마나 남았는지 확인할 수 있다:

```sql
-- 테이블별 relfrozenxid 나이 (age가 클수록 위험에 가깝다)
SELECT c.oid::regclass AS table_name,
       greatest(age(c.relfrozenxid), age(t.relfrozenxid)) AS age
FROM pg_class c
LEFT JOIN pg_class t ON c.reltoastrelid = t.oid
WHERE c.relkind IN ('r', 'm')
ORDER BY age DESC;

-- 데이터베이스별 datfrozenxid 나이
SELECT datname, age(datfrozenxid) FROM pg_database;
```

관련 GUC 현재 값도 함께 확인하면 임계 구조가 보인다:

```sql
SHOW autovacuum_freeze_max_age;   -- 기본 200000000
SHOW vacuum_freeze_min_age;
SHOW vacuum_freeze_table_age;
```

`VACUUM (VERBOSE)`로 특정 테이블을 수동 실행하면 `relfrozenxid`가 어디까지 전진했는지, 새로 freeze된 페이지 수가 얼마인지 로그로 직접 볼 수 있다 — `log_autovacuum_min_duration`을 켜 두면 autovacuum이 수행한 VACUUM에서도 같은 정보가 서버 로그에 남는다.

## 잘못 알고 있던 것

- **"VACUUM은 죽은 튜플을 청소하는 용도일 뿐이다"** — 틀렸다. 공식 문서는 VACUUM의 이유를 4가지로 나열하는데(공간 회수, 플래너 통계 갱신, visibility map 갱신, wraparound 방지), wraparound 방지는 죽은 튜플과 무관하다. INSERT-only 테이블(삭제·갱신이 전혀 없어 회수할 공간이 없는 테이블)도 오직 이 이유 때문에 주기적으로 vacuum되어야 한다.
- **"autovacuum을 꺼두면 이 문제는 그냥 방치된다"** — 아니다. `autovacuum_freeze_max_age`에 도달하면 전역 autovacuum 설정과 무관하게 해당 테이블에 한해 강제로 autovacuum이 발동한다.
- **"wraparound 위기가 닥치면 single-user mode로 내려가서 VACUUM해야 한다"** — 과거 버전의 권고였고 현재 문서는 이를 명시적으로 비권장한다. postmaster를 내릴 필요 없이, 온라인 상태에서 prepared transaction·장기 트랜잭션·죽은 복제 슬롯을 정리한 뒤 VACUUM을 돌리는 것이 정석이며, single-user mode는 오히려 wraparound 안전장치 자체를 무력화해 더 위험하다고 명시되어 있다.

## 더 파고들 만한 것

- MultiXact ID wraparound: XID와는 별도로 관리되는 `relminmxid`/`datminmxid` 카운터와 그 freeze 메커니즘
- eager freeze scanning(`vacuum_max_eager_freeze_failure_rate`)의 내부 스캔 실패율 판단 알고리즘

## 참고

- PostgreSQL 18 공식 문서 §24.1 Routine Vacuuming / §24.1.5 Preventing Transaction ID Wraparound Failures (https://www.postgresql.org/docs/current/routine-vacuuming.html)

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
