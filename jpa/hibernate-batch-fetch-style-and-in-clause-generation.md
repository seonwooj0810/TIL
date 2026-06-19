# Hibernate 배치 페치의 BatchFetchStyle과 IN 절 생성 방식

> **Primary source:** Hibernate ORM User Guide §12.8 Batch fetching, Hibernate Javadocs `@BatchSize`, Hibernate 5.5 Javadocs `org.hibernate.loader.BatchFetchStyle`
> **Secondary:** Hibernate ORM 6.2 Javadocs `AvailableSettings#BATCH_FETCH_STYLE`
> **Date:** 2026-06-19
> **Status:** draft

## 왜 봤나

- N+1을 줄이려고 `hibernate.default_batch_fetch_size`만 켜면 Hibernate가 알아서 "N개씩 묶는다"고만 알고 있었다.
- 특히 `BatchFetchStyle`의 `LEGACY`, `PADDED`, `DYNAMIC`이 실제 SQL의 `IN` 파라미터 개수와 PreparedStatement 재사용성에 어떤 차이를 만드는지 헷갈렸다.

## 핵심 한 문장

> Hibernate 배치 페치는 현재 `Session`에 남아 있는 미초기화 프록시나 컬렉션 키를 모아 하나의 select로 초기화하는 최적화이고, 5.x의 `BatchFetchStyle`은 그 키 목록을 SQL `IN` 절의 몇 개 placeholder로 쪼개거나 패딩하거나 동적으로 만들지 결정한다.

## 내부 동작

### 1) 배치 페치는 JDBC batch가 아니다

공식 Javadoc의 `@BatchSize` 설명에 따르면, batch fetching이 활성화되면 Hibernate는 하나의 라운드 트립에서 여러 엔티티 인스턴스나 컬렉션을 가져올 수 있다. 보통 id 하나만 조건으로 넣는 select 대신, `where` 절 안의 SQL `in` 조건에 여러 primary key 값을 넣는 방식이다.

여기서 말하는 batch는 insert/update를 묶어 보내는 `hibernate.jdbc.batch_size`와 다르다. JDBC batch는 쓰기 SQL 여러 개를 드라이버에 모아 보내는 기능이고, 이 노트의 batch fetching은 lazy association을 읽을 때 select 횟수를 줄인다.

```
초기 조회
  select * from order_line where ...
        │
        ▼
Session / PersistenceContext
  OrderLine#1 -> product proxy id=10  (uninitialized)
  OrderLine#2 -> product proxy id=11  (uninitialized)
  OrderLine#3 -> product proxy id=12  (uninitialized)
        │
        │ 첫 product 접근
        ▼
BatchFetchQueue에서 같은 타입의 미초기화 id 후보 수집
        │
        ▼
  select * from product where id in (?, ?, ?)
```

자료구조 관점에서는 `Session`의 영속성 컨텍스트가 이미 알고 있는 프록시와 컬렉션 엔트리가 출발점이다. Hibernate Javadoc은 batch fetch 대상 primary key가 "session과 연관된 unfetched entity proxies 또는 collection roles"의 identifier에서 선택된다고 설명한다. 즉 DB에서 임의의 id 범위를 예측해 가져오는 기능이 아니라, 현재 세션 안에 이미 매달린 lazy 참조 중 아직 초기화되지 않은 것들을 모으는 기능으로 이해해야 한다.

### 2) 엔티티 배치와 컬렉션 배치

`@BatchSize`는 엔티티 타입에도 붙고 컬렉션 association에도 붙는다. 엔티티 타입에 붙이면 같은 엔티티 프록시 여러 개를 한 번에 초기화할 수 있고, 컬렉션에 붙이면 여러 owner의 동일한 collection role을 한 번에 초기화할 수 있다.

```java
@Entity
@BatchSize(size = 32)
class Product {
    @Id Long id;
}

@Entity
class Department {
    @OneToMany(mappedBy = "department")
    @BatchSize(size = 16)
    private List<Employee> employees = new ArrayList<>();
}
```

위 설정에서 `Product` 프록시 하나를 처음 건드릴 때 Hibernate는 같은 세션 안의 다른 미초기화 `Product` 프록시 id를 최대 32개까지 함께 고른다. `Department#employees`를 처음 건드릴 때는 아직 초기화되지 않은 다른 `Department#employees` collection key를 최대 16개까지 함께 고른다. 공식 User Guide §12.8의 예제도 부서 여러 개를 조회한 뒤 각 부서의 employees collection을 접근할 때, `Department` id 목록을 `IN` 조건에 넣는 흐름을 보여준다.

### 3) BatchFetchStyle은 SQL 모양을 결정한다

Hibernate 5.x Javadoc 기준 `BatchFetchStyle`은 세 가지다.

| style | SQL 크기 선택 | 특징 |
| --- | --- | --- |
| `LEGACY` | 미리 계산된 크기 중 현재 후보 수 이하의 크기를 고름 | SQL 모양 수를 제한하지만 여러 번 쿼리할 수 있음 |
| `PADDED` | 미리 계산된 크기 중 현재 후보 수 이상의 크기를 고름 | 한 번에 보내기 쉽지만 남는 placeholder는 id 반복으로 패딩 |
| `DYNAMIC` | 실제 후보 수에 맞춰 SQL 생성 | 불필요한 placeholder는 줄지만 SQL 모양이 더 다양해질 수 있음 |

Javadoc의 예시는 batch size가 32일 때 pre-built batch sizes가 `[32, 16, 10, 9, 8, 7, ..., 1]`처럼 만들어진다고 설명한다. 31개의 id를 초기화하려 할 때:

- `LEGACY`는 다음보다 작은 pre-built 크기를 골라 16, 10, 5처럼 여러 번 나눠 가져온다.
- `PADDED`는 다음보다 큰 크기 32를 고르고, 부족한 1개 placeholder에는 이미 있는 id를 반복해 채운다.
- `DYNAMIC`은 실제 가능한 id 수를 기준으로 SQL을 동적으로 만든다. 그래도 엔티티나 컬렉션에 설정된 batch size 상한은 넘지 않는다.

이 차이는 단순히 "몇 개씩 가져오나"가 아니라 **SQL 텍스트의 shape** 차이다. `LEGACY`와 `PADDED`는 미리 정해진 placeholder 개수의 SQL을 재사용하는 쪽에 가깝고, `DYNAMIC`은 후보 수에 맞춘 SQL을 만드는 쪽에 가깝다. 따라서 같은 batch size라도 DB statement cache, Hibernate loader 생성 비용, 라운드 트립 수가 다르게 나타날 수 있다.

### 4) 상태 전이로 보면 언제 batch가 걸리는가

배치 페치는 lazy 객체가 "초기화 직전" 상태일 때만 의미가 있다.

```
조회 결과 materialize
        │
        ▼
프록시/컬렉션 wrapper 등록
        │  상태: uninitialized, owner/session과 연결
        │
        │ 애플리케이션이 getter 접근
        ▼
BatchFetchQueue 후보 수집
        │
        ├─ 후보 1개뿐이면 일반 select와 거의 같음
        │
        └─ 후보 여러 개면 batch size / style에 따라 id 목록 구성
        ▼
SQL 실행
        │
        ▼
초기화 완료, 1차 캐시에 엔티티/컬렉션 반영
```

여기서 중요한 점은 batch fetching이 join fetch처럼 최초 query의 결과 모양을 바꾸지 않는다는 것이다. 첫 query는 그대로이고, 이후 lazy 초기화 시점의 보조 select가 `id = ?`에서 `id in (?, ?, ...)`로 바뀐다. 그래서 페이징 query와 조합할 때 join fetch보다 결과 행 폭발 위험은 낮지만, 접근 패턴이 실제로 여러 lazy 참조를 연달아 건드릴 때만 이득이 난다.

### 5) IN 절 생성 예시

후보 id가 11개 있고 batch size가 8이라고 가정한다. Hibernate 버전과 dialect에 따라 SQL 표현은 달라질 수 있지만, 전통적인 `IN` placeholder 기준으로 보면 다음처럼 이해할 수 있다.

```
candidate ids in Session: [10,11,12,13,14,15,16,17,18,19,20]
configured batch size: 8

첫 lazy 접근 대상: id=10
선택 후보: [10,11,12,13,14,15,16,17]

select ...
from product
where id in (?, ?, ?, ?, ?, ?, ?, ?)
```

그 다음 id=18에 접근하면 남은 후보 `[18,19,20]`이 style에 따라 달라진다.

```sql
-- DYNAMIC에 가까운 모양: 실제 후보 수만큼
where id in (?, ?, ?)

-- PADDED에 가까운 모양: 더 큰 pre-built 크기를 쓰고 반복 id로 채움
where id in (?, ?, ?, ?, ?, ?, ?, ?)
-- bind values: [18, 19, 20, 20, 20, 20, 20, 20] 처럼 반복될 수 있음

-- LEGACY에 가까운 모양: 더 작은 pre-built 크기들을 골라 여러 번
where id in (?, ?)
where id = ?
```

공식 문서가 보장하는 핵심은 "여러 primary key를 `IN` 조건으로 보낸다"는 점이고, 정확한 SQL 텍스트는 Hibernate major version과 dialect에 따라 달라질 수 있다. 예를 들어 Hibernate 7 소개 문서는 PostgreSQL에서 SQL array와 `= any (?)` 형태가 나올 수 있음을 보여준다. 그래서 운영 로그를 볼 때도 `IN (?, ?)`만 찾기보다, dialect가 batch id 목록을 어떤 표현으로 바꾸는지 같이 봐야 한다.

## 검증

이 노트에서는 코드 실험 대신 출처 흐름을 직접 따라갔다.

1. Hibernate ORM User Guide §12.8은 `@BatchSize`를 사용해 uninitialized entity proxy나 collection을 batch fetching하는 예제를 든다.
2. `@BatchSize` Javadoc은 batch fetching이 여러 엔티티나 컬렉션을 한 번의 DB round trip으로 가져오며, `where` 절에 SQL `in` 조건과 primary key 목록을 둔다고 설명한다.
3. Hibernate 5.5 `BatchFetchStyle` Javadoc은 `LEGACY`, `PADDED`, `DYNAMIC`의 차이를 pre-built batch size, padding, dynamic SQL 생성으로 나눈다.
4. Hibernate 6.2 `AvailableSettings#BATCH_FETCH_STYLE` Javadoc은 이 설정이 6.0부터 deprecated 되었고 적절한 batch-fetch style이 자동 선택된다고 설명한다.

따라서 Hibernate 5.x 설정을 읽을 때는 `hibernate.batch_fetch_style`의 의미를 봐야 하지만, Hibernate 6.x 이후 새 코드에서는 이 설정을 직접 튜닝 대상으로 보기보다 `@BatchSize`, `hibernate.default_batch_fetch_size`, 실제 SQL 로그, dialect 동작을 먼저 보는 편이 자연스럽다.

## 잘못 알고 있던 것

- "batch size가 32면 항상 `IN` 안에 32개 id가 들어간다." → 틀림. 공식 Javadoc 기준 `DYNAMIC`은 실제 id 수에 맞출 수 있고, `LEGACY`는 더 작은 pre-built size로 쪼갤 수 있으며, `PADDED`만 더 큰 크기를 쓰면서 반복 id로 채울 수 있다.
- "배치 페치는 조회 query 자체를 join으로 바꾼다." → 틀림. batch fetching은 lazy select fetching의 최적화다. 최초 조회 결과에 join row를 붙이는 것이 아니라, 나중에 lazy 초기화 select를 여러 id 조건으로 묶는다.
- "큰 batch size가 무조건 좋다." → 단정하기 어렵다. round trip은 줄 수 있지만 `IN` 목록 크기, statement cache hit, DB parameter limit, Hibernate loader/SQL shape 비용이 같이 움직인다. 공식 문서가 말하는 것은 최대 batch size와 style의 동작이지, 모든 시스템에 맞는 최적값은 아니다.

## 더 파고들 만한 것

- Hibernate 6.x의 자동 batch-fetch style 선택과 dialect별 multi-key binding 방식.
- `FetchMode.SUBSELECT`와 batch fetching의 차이: 같은 N+1 완화라도 후보 집합을 "현재 세션의 미초기화 키"에서 고르는지, "직전 query의 subselect"에서 고르는지.

## 참고

- Hibernate ORM User Guide §12.8 Batch fetching.
- Hibernate Javadocs `org.hibernate.annotations.BatchSize`.
- Hibernate ORM 5.5 Javadocs `org.hibernate.loader.BatchFetchStyle`.
- Hibernate ORM 6.2 Javadocs `org.hibernate.cfg.AvailableSettings#BATCH_FETCH_STYLE`.
