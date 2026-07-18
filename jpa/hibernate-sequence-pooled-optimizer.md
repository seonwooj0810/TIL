# Hibernate 시퀀스 식별자 생성과 pooled 옵티마이저: allocationSize로 INSERT마다의 시퀀스 왕복을 없애는 법

> **Primary source:** Hibernate ORM 7 User Guide — Identifier generators / `org.hibernate.id.enhanced` 소스 (`SequenceStyleGenerator`, `PooledOptimizer`, `PooledLoOptimizer`, `HiLoOptimizer`, `StandardOptimizerDescriptor`)
> **Secondary:** Jakarta Persistence 3.2 §11.1.48 `@SequenceGenerator`, Vlad Mihalcea "pooled vs pooled-lo"
> **Date:** 2026-07-18
> **Status:** draft

## 왜 봤나

- `@GeneratedValue(strategy = SEQUENCE)`를 쓰면 INSERT마다 `SELECT nextval` 왕복이 생긴다고 막연히 알고 있었는데, 실제로는 기본값 `allocationSize=50` 덕에 50건에 한 번만 시퀀스를 친다. 이 "한 번만"이 어떻게 collision 없이 성립하는지가 궁금했다.
- DB 시퀀스를 직접 `INCREMENT BY 1`로 만들어 두고 엔티티엔 기본 allocationSize를 쓰면 왜 중복 키가 터지는지도 같이 정리한다.

## 핵심 한 문장

> pooled 옵티마이저는 DB 시퀀스가 돌려준 값 하나를 **50개짜리 ID 블록의 경계**로 재해석해서, 그 블록을 애플리케이션 메모리에서 소진할 때까지 DB를 다시 치지 않는다 — 단, 이 계약은 "시퀀스의 INCREMENT BY == allocationSize"일 때만 성립한다.

## 내부 동작

### 1. 누가 옵티마이저를 고르나

`SequenceStyleGenerator`는 `allocationSize`(=incrementSize)를 보고 옵티마이저를 결정한다 (`StandardOptimizerDescriptor`).

```
incrementSize <= 1  →  NONE  (NoopOptimizer, 매 호출 nextval)
incrementSize  > 1  →  POOLED (기본; hibernate.id.optimizer.pooled.preferred 로 pooled-lo 전환 가능)
```

JPA `@SequenceGenerator`의 `allocationSize` 기본값은 **50**이다(스펙 §11.1.48). 즉 아무것도 안 건드리면 `pooled` 옵티마이저 + 50 블록이 기본 경로다.

### 2. pooled: 돌려받은 값을 "상한(hi)"으로 본다

`PooledOptimizer.generate()`의 핵심 (Hibernate 소스 기준):

```java
if (state.hiValue == null) {                 // 최초 1회
    state.hiValue = callback.getNextValue();  // DB nextval 1회
    if ((initialValue == -1 && state.hiValue < incrementSize)
            || state.hiValue == initialValue)
        state.value = state.hiValue;                       // 초기값이면 그대로 시작
    else
        state.value = state.hiValue - incrementSize + 1;   // 일반: 하한 계산
}
else if (state.value > state.hiValue) {      // 블록 소진
    state.hiValue = callback.getNextValue();  // 다음 블록 상한
    state.value = state.hiValue - incrementSize + 1;
}
return state.value++;                         // 블록 안에서 메모리 증가
```

돌려받은 값 `hiValue`가 블록의 **상한**이고, 나눠주는 ID는 반개구간이 아니라 닫힌 구간 `[hiValue - incrementSize + 1, hiValue]`이다. 시퀀스가 `INCREMENT BY 50`으로 50, 100, 150…을 돌려준다면:

```
nextval=50  →  ID 1..50   (50 - 50 + 1 = 1 부터 50까지, 메모리 소진)
nextval=100 →  ID 51..100
nextval=150 →  ID 101..150
```

DB에는 딱 3번만 갔는데 150개의 ID를 발급했다. 시퀀스의 현재값(150)은 항상 이미 발급된 마지막 ID와 같거나 그 위의 경계다.

### 3. pooled-lo: 돌려받은 값을 "하한(lo)"으로 본다

`PooledLoOptimizer.generate()`:

```java
if (state.lastSourceValue == null || state.value >= state.upperLimitValue) {
    state.lastSourceValue = callback.getNextValue();
    state.upperLimitValue = state.lastSourceValue + incrementSize; // 상한 = lo + 50
    state.value           = state.lastSourceValue;                 // 하한부터 시작
}
return state.value++;
```

돌려받은 값이 블록의 **하한**이고, ID는 `[lastSourceValue, lastSourceValue + incrementSize)` 반개구간이다. 시퀀스가 1, 51, 101…을 돌려준다면 ID는 1..50, 51..100, 101..150.

pooled와 pooled-lo의 유일한 개념 차이는 **DB 값이 블록의 위 경계냐 아래 경계냐**뿐이다. pooled-lo 쪽이 "DB에 적힌 값 = 이 블록에서 가장 먼저 발급될 ID"라서 외부 시스템이 같은 시퀀스를 읽어 직접 INSERT해도 의미가 겹치지 않아 상호운용성이 낫다(그래서 Vlad Mihalcea가 pooled-lo를 권한다).

```
 시퀀스 반환값 V, allocationSize=N
 pooled    :  발급 ID ∈ [V-N+1, V]      (V = 블록 상한)
 pooled-lo :  발급 ID ∈ [V,   V+N-1]    (V = 블록 하한)
```

### 4. 왜 "INCREMENT BY == allocationSize"가 계약인가

옵티마이저는 **한 번의 nextval이 곧 N개의 ID를 예약한 것**이라고 가정한다. 그래서 스키마 자동 생성 시 Hibernate는 시퀀스를 `INCREMENT BY N`으로 만든다. 이 두 숫자가 어긋나면:

- DB 시퀀스 `INCREMENT BY 1`, Hibernate `allocationSize=50`이면: 인스턴스 A가 nextval=1을 받아 ID 1..50을 쓰는 동안, 인스턴스 B가 nextval=2를 받아 ID 2..51을 쓴다 → **범위가 겹쳐 중복 키**.
- 반대로 큰 increment에 작은 allocationSize면 ID에 큰 구멍이 생긴다.

즉 allocationSize는 "성능 튜닝 숫자"가 아니라 **DB 시퀀스 정의와 반드시 일치해야 하는 계약값**이다.

### 5. IDENTITY와의 결정적 차이 (배치 INSERT)

`GenerationType.IDENTITY`는 auto-increment 컬럼이라 **INSERT가 실행돼야 비로소 PK를 안다**. Hibernate는 영속화 시점에 ID가 필요하므로(1차 캐시 키) IDENTITY는 INSERT를 미룰 수 없고, 그 결과 **JDBC 배치 INSERT가 비활성화**된다. 반면 SEQUENCE+pooled는 flush 전에 메모리에서 ID를 다 알 수 있어 여러 INSERT를 배치로 묶을 수 있다. "SEQUENCE는 왕복이 많아 느리다"는 통념과 정반대로, allocationSize가 있으면 SEQUENCE가 대량 삽입에 유리하다.

## 검증

Hibernate 소스 `PooledOptimizer`/`PooledLoOptimizer`의 `generate()`를 직접 따라가 경계 공식을 확인했다(pooled: `value = hiValue - incrementSize + 1`, pooled-lo: `upperLimit = lastSourceValue + incrementSize`). 인라인으로 시퀀스 반환값 → 발급 ID 매핑을 손으로 전개해 두 옵티마이저가 같은 반환값 V에 대해 서로 다른 구간(`[V-N+1,V]` vs `[V,V+N-1]`)을 채움을 대조했다.

`allocationSize`≠`INCREMENT BY` 충돌은 두 인스턴스 시나리오로 재현 가능하다. 하나의 nextval이 예약하는 개수(Hibernate 가정 N)와 DB가 실제로 건너뛰는 폭(INCREMENT BY M)이 다르면 발급 구간이 오프셋만큼만 벌어져 반드시 교집합이 생긴다.

```sql
-- Hibernate가 스키마 생성 시 만드는 형태 (allocationSize=50과 일치)
CREATE SEQUENCE order_seq START WITH 1 INCREMENT BY 50;
```

```java
@Entity
class Order {
  @Id
  @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "order_gen")
  @SequenceGenerator(name = "order_gen", sequenceName = "order_seq",
                     allocationSize = 50) // ← 시퀀스 INCREMENT BY와 동일해야 함
  Long id;
}
```

## 잘못 알고 있던 것

- **"SEQUENCE는 INSERT마다 nextval을 쳐서 IDENTITY보다 느리다."** 반대다. 기본 `allocationSize=50`의 pooled 옵티마이저는 50건당 nextval 1회고, 게다가 flush 전에 ID를 확보하므로 **JDBC 배치 INSERT**가 살아 있다. IDENTITY야말로 매 행 왕복 + 배치 불가다.
- **"시퀀스의 현재값과 방금 저장된 엔티티 ID가 같다."** pooled에선 시퀀스가 50, 100…으로 뛰지만 ID는 그 사이를 채운다. DBA가 시퀀스만 보고 "지금 ID가 100번대"라고 단정하면 틀린다. pooled는 시퀀스값이 블록 상한, pooled-lo는 하한이라 해석이 또 다르다.
- **"allocationSize는 그냥 성능 옵션이라 아무 값이나 키우면 된다."** DB 시퀀스 `INCREMENT BY`와 어긋나면 다중 인스턴스에서 발급 구간이 겹쳐 중복 키가 난다. 키우려면 시퀀스 정의도 같이 바꿔야 한다. (레거시 `hilo`는 DB값을 블록 번호로 곱해 써서, 외부 시스템이 같은 시퀀스를 직접 쓰면 충돌 — 그래서 pooled/pooled-lo가 도입됐다.)

## 더 파고들 만한 것

- `SequenceStyleGenerator` vs 구형 `SequenceGenerator`/`TableGenerator`, 그리고 `@TableGenerator`의 행 잠금 비용.
- 다중 인스턴스에서 pooled 블록 예약이 만드는 ID 구멍(재시작 시 미사용 블록 유실)과 그 허용 근거.

## 참고

- Hibernate ORM 7 User Guide — Identifier generators
- `org.hibernate.id.enhanced.PooledOptimizer` / `PooledLoOptimizer` / `HiLoOptimizer` / `StandardOptimizerDescriptor` 소스
- Jakarta Persistence 3.2 §11.1.48 `@SequenceGenerator`
- Vlad Mihalcea — "Hibernate hidden gem: the pooled-lo optimizer"
