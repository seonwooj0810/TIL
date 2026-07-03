# JPA 낙관적 락(@Version): 버전 컬럼이 lost update를 막는 compare-and-set 메커니즘

> **Primary source:** Jakarta Persistence 3.2 Spec §3.4.2 (Optimistic Locking and Concurrency), §11.1.63 (@Version)
> **Secondary:** Hibernate ORM 6 User Guide — Locking; Hibernate 소스 `EntityVerifyVersionProcess`, `Versioning`
> **Date:** 2026-07-03
> **Status:** draft

## 왜 봤나

- `@Version` 필드 하나 붙였을 뿐인데 동시에 같은 엔티티를 수정하면 한쪽이 `OptimisticLockException`으로 튕긴다. DB에 락을 거는 것도 아닌데 어떻게 충돌을 감지하는지 내부 SQL 수준에서 확인하고 싶었다.
- "낙관적 락은 애플리케이션이 버전을 비교한다"고 막연히 알고 있었는데, 실제 비교가 어디서 일어나는지(자바 vs DB)를 헷갈리고 있었다.

## 핵심 한 문장

> 낙관적 락은 락을 걸지 않고, `UPDATE ... SET version = version + 1 WHERE id = ? AND version = ?` 한 문장의 **영향받은 행 수(row count)** 로 "내가 읽은 뒤 아무도 안 바꿨는가"를 원자적으로 판정하는 compare-and-set이다.

## 내부 동작

### 1. 버전 컬럼과 상태

`@Version`이 붙은 필드(정수 계열 `int`/`long`/`Integer`/`Long`/`short`, 또는 `java.sql.Timestamp`/`java.time.Instant`)는 엔티티의 "세대 번호"다. Jakarta Persistence 스펙 §3.4.2에 따르면 이 값은 **영속성 제공자(Hibernate)가 관리**하며 애플리케이션이 임의로 바꿔선 안 된다. 조회 시 함께 읽히고, flush 때 자동 증가한다.

```
Entity(id=1, name="A", version=3)  ← SELECT로 읽힘, PC에 스냅샷 저장
      │ tx1이 name 수정
      ▼
flush 시점: UPDATE product
            SET name=?, version=4
            WHERE id=1 AND version=3
```

### 2. flush 시 무슨 SQL이 나가는가

flush가 일어나면 Hibernate는 dirty checking으로 바뀐 엔티티를 찾고, 각 `EntityUpdateAction`을 만든다. 버저닝 엔티티의 UPDATE는 일반 UPDATE와 두 곳이 다르다.

- **SET 절**: 변경된 컬럼과 **함께 `version = ?`(기존값+1)** 를 넣는다.
- **WHERE 절**: PK뿐 아니라 **`AND version = ?`(읽어온 옛 버전)** 를 붙인다.

즉 "내가 3번 세대를 읽었으니, 지금도 3번일 때만 4번으로 올린다"는 조건부 갱신이다.

### 3. 충돌 판정은 자바가 아니라 row count로

핵심은 **비교를 애플리케이션 메모리에서 하지 않는다**는 점이다. DB가 `WHERE ... AND version = 3`을 평가해서, 그 사이 tx2가 이미 version을 4로 올려버렸다면 매칭되는 행이 없어 `UPDATE`의 **affected rows = 0** 이 된다.

Hibernate는 JDBC `PreparedStatement.executeUpdate()`의 반환값을 검사한다. 기대 행 수(보통 1)와 다르면:

```
expected rows: 1
actual rows  : 0   → StaleStateException
                     → (JPA 경계) OptimisticLockException / RollbackException
```

`Expectation.ExpectedRowCount`가 이 검사를 담당한다. 그래서 낙관적 락은 **DB 행 잠금(row lock)을 전혀 걸지 않는다** — 오직 조건부 UPDATE의 성공/실패로 충돌을 사후 감지할 뿐이다.

### 4. 두 트랜잭션의 상태 전이 (lost update가 막히는 순간)

```
       tx1                         tx2
   read v=3                     read v=3
       │                            │
   name="A1"                    name="A2"
       │                            │
   commit ──► UPDATE ... WHERE v=3
              rows=1, DB now v=4
       │                            │
       │                        commit ──► UPDATE ... WHERE v=3
       │                                   rows=0  ✗
       │                                   OptimisticLockException
```

락 기반이라면 tx2가 tx1 커밋까지 블로킹됐겠지만, 낙관적 락은 둘 다 자유롭게 진행하다가 **늦게 커밋한 쪽이 진다**(lost update를 예외로 전환). 충돌이 드물다는 낙관적 가정 아래 블로킹을 없앤 설계다.

### 5. dirty field가 없어도 버전을 올리고 싶을 때

기본(암묵적) 버저닝은 실제로 바뀐 컬럼이 있어야 UPDATE가 나가고 버전이 오른다. 그런데 "부모를 읽고 검증만 하는데 그 사이 자식이 안 바뀌었음을 보장"하고 싶은 경우가 있다. 스펙은 `LockModeType`으로 이를 구분한다.

| LockModeType | 동작 |
| --- | --- |
| `OPTIMISTIC` (=`READ`) | 커밋 시 버전을 **다시 읽어 변하지 않았는지 검증**(SELECT version). 변경은 안 함 |
| `OPTIMISTIC_FORCE_INCREMENT` (=`WRITE`) | 엔티티가 안 바뀌었어도 **버전을 강제로 +1** 시켜 UPDATE |

`OPTIMISTIC`은 flush 끝에 `EntityVerifyVersionProcess`가 `SELECT version WHERE id=?`로 현재 버전이 읽었던 값과 같은지 확인하고 다르면 예외를 던진다. `OPTIMISTIC_FORCE_INCREMENT`는 `EntityIncrementVersionProcess`로 버전을 밀어올려, 논리적으로 연관된 애그리거트 전체의 무결성을 한 버전선에 묶을 때 쓴다.

### 6. detached 엔티티와 merge

detached 상태로 클라이언트까지 갔다 온 엔티티(예: 폼 화면에 실린 version)를 `merge()`하면, **그 안에 실린 version이 그대로 WHERE 절에 쓰인다**. 그래서 화면을 연 뒤 오래 붙들고 있다가 저장하면, 그 사이 남이 수정한 경우 version 불일치로 충돌이 잡힌다 — 낙관적 락이 HTTP 요청-응답처럼 트랜잭션 경계를 넘는 "긴 대화"에서 특히 유용한 이유다.

## 검증

Jakarta Persistence 스펙 §3.4.2와 Hibernate가 생성하는 SQL을 따라가 흐름을 확인했다. `show_sql`을 켜면 실제로 다음 형태가 관찰된다는 것이 문서/다수 사례로 알려져 있다.

```java
@Entity
class Product {
    @Id Long id;
    String name;
    @Version long version;   // 정수 버전
}

// tx1
Product p = em.find(Product.class, 1L);  // SELECT ... version=3
p.setName("A1");
// commit → flush 시 생성되는 SQL:
//   UPDATE product SET name=?, version=4 WHERE id=1 AND version=3
```

DB에서 직접 재현하면 판정 원리가 그대로 보인다.

```sql
-- 현재 version = 3 인 상태에서
UPDATE product SET name='A2', version = 4 WHERE id = 1 AND version = 3;
-- 다른 세션이 먼저 커밋해 version이 이미 4라면 → "0 rows affected"
-- Hibernate는 이 0을 보고 StaleStateException으로 전환
```

`version + 1`과 `WHERE version = old`가 **하나의 UPDATE 문 안**에 있으므로, 비교와 증가가 DB 레벨에서 원자적으로 처리된다(read-modify-write race가 없다).

## 잘못 알고 있던 것

- **"낙관적 락도 DB에 락을 건다"** → 아니다. 낙관적 락은 어떤 행 락/테이블 락도 걸지 않는다. 조건부 UPDATE의 row count가 0이면 충돌로 간주할 뿐이다. 실제 잠금은 비관적 락(`PESSIMISTIC_WRITE` → `SELECT ... FOR UPDATE`)의 몫이다.
- **"버전 비교를 자바 코드가 if로 한다"** → 아니다. 비교는 `WHERE version = ?` 로 **DB가** 수행한다. Hibernate가 하는 건 실행 결과 행 수를 보고 예외로 바꾸는 일뿐이다. 그래서 여러 노드가 붙어도 DB 한 곳에서 일관되게 판정된다.
- **"충돌하면 자동으로 재시도된다"** → 아니다. `OptimisticLockException`은 던져질 뿐, 재시도(다시 읽고 다시 적용)는 애플리케이션 책임이다.
- **"타임스탬프 버전이 정수 버전보다 안전하다"** → 오히려 반대일 수 있다. 시계 해상도(같은 밀리초)나 시계 되돌림이면 두 갱신이 같은 타임스탬프를 가져 충돌을 놓칠 여지가 있다. 스펙도 정수 계열을 권장 뉘앙스로 둔다.

## 더 파고들 만한 것

- 비관적 락(`PESSIMISTIC_WRITE`/`PESSIMISTIC_READ`)이 만드는 `FOR UPDATE`/`LOCK IN SHARE MODE`와 낙관적 락의 처리량·데드락 트레이드오프.
- `OPTIMISTIC` 검증 SELECT가 트랜잭션 격리 수준(REPEATABLE READ의 스냅샷)과 어떻게 상호작용하는지.

## 참고

- Jakarta Persistence 3.2 Specification §3.4.2, §11.1.63
- Hibernate ORM 6 User Guide — Locking (Optimistic / `LockModeType`)
- Hibernate 소스: `Versioning`, `EntityVerifyVersionProcess`, `EntityIncrementVersionProcess`, `Expectation.ExpectedRowCount`
