# Spring Data JPA는 인터페이스만으로 어떻게 리포지토리 빈을 만드나 — 프록시 + 쿼리 룩업

> **Primary source:** Spring Data Commons 소스 `RepositoryFactorySupport` / `QueryExecutorMethodInterceptor` / `QueryLookupStrategy` / `query.parser.PartTree`, Spring Data JPA 소스 `JpaRepositoryFactory` / `SimpleJpaRepository` / `PartTreeJpaQuery`
> **Secondary:** Spring Data JPA Reference (Core concepts, Query Methods, Query Lookup Strategies)
> **Date:** 2026-07-16
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/spring-data-jpa-repository-proxy

## 왜 봤나

- `interface UserRepository extends JpaRepository<User, Long>` — 구현 클래스를 한 줄도 안 썼는데 `findByEmailAndActiveTrue(...)`가 동작한다. 대체 그 구현체는 누가, 언제, 어떻게 만드는가.
- 막연히 "Spring이 런타임에 구현 클래스를 바이트코드로 생성한다"고 알고 있었는데, 실제로는 그렇지 않았다.

## 핵심 한 문장

> 리포지토리 빈은 새로 생성된 구현 바이트코드가 아니라 **JDK 동적 프록시(디스패처)** 이고, 이 프록시는 호출을 세 갈래 — 기존 `SimpleJpaRepository` 인스턴스(CRUD) / 부트스트랩 때 미리 만들어둔 `RepositoryQuery` 객체(쿼리 메서드) / 사용자 커스텀 프래그먼트 — 로 나눠 위임할 뿐이다.

## 내부 동작

### 1. 등록: 인터페이스 → FactoryBean BeanDefinition

`@EnableJpaRepositories`(부트에선 auto-config)가 `RepositoryConfigurationDelegate`로 스캔을 돌려, 마커 인터페이스 `Repository`를 상속한 인터페이스를 찾는다. 각 인터페이스마다 실제로 컨테이너에 등록되는 빈 클래스는 그 인터페이스가 아니라 **`JpaRepositoryFactoryBean`** — 즉 `FactoryBean`이다. 컨테이너는 이 FactoryBean의 `getObject()`가 돌려주는 프록시를 `UserRepository` 타입 빈으로 노출한다.

### 2. 프록시 조립: `RepositoryFactorySupport.getRepository()`

`FactoryBean.afterPropertiesSet()` 단계에서 `RepositoryFactorySupport`가 프록시를 만든다. 골격:

```
getRepository(interface, fragments):
  target  = getTargetRepository(...)      // = SimpleJpaRepository 인스턴스 (CRUD 실제 구현)
  ProxyFactory pf = new ProxyFactory()
  pf.setInterfaces(repositoryInterface, Repository, TransactionalProxy, ...)
  pf.setTarget(target)
  pf.addAdvice(ImplementationMethodExecutionInterceptor)  // 커스텀 프래그먼트
  pf.addAdvice(QueryExecutorMethodInterceptor)            // 쿼리 메서드 라우팅
  return pf.getProxy()   // JDK 동적 프록시
```

즉 CRUD의 실체는 **이미 존재하는 클래스** `SimpleJpaRepository`(base class)의 인스턴스다. Spring은 그걸 새로 만들지 않는다.

### 3. 호출 시 3-way 디스패치

프록시에 메서드가 들어오면 우선순위대로 판정된다.

```
proxy.someMethod()
  ├─ (a) 커스텀 프래그먼트에 있는 메서드?  → ImplementationMethodExecutionInterceptor → 사용자 구현체
  ├─ (b) 쿼리 메서드(선언만 있고 base엔 없음)? → QueryExecutorMethodInterceptor → RepositoryQuery.execute()
  └─ (c) 그 외(save/findById/delete...)       → target(SimpleJpaRepository)로 그냥 위임
```

핵심은 **(b)의 라우팅 테이블이 부트스트랩 때 이미 채워져 있다**는 점이다. `QueryExecutorMethodInterceptor`는 생성 시점에 인터페이스의 모든 쿼리 메서드를 `QueryLookupStrategy`에 넘겨 `Map<Method, RepositoryQuery>`를 만들어 둔다. 런타임 호출은 이 맵에서 꺼내 `execute(args)`를 부르는 O(1) 조회일 뿐, 그때그때 파싱하지 않는다.

### 4. 쿼리는 어디서 오나: `QueryLookupStrategy`

전략은 셋이고 기본은 `CREATE_IF_NOT_FOUND`:

| 전략 | 동작 |
| --- | --- |
| `USE_DECLARED_QUERY` | `@Query` 또는 named query만 사용. 없으면 예외 |
| `CREATE` | 메서드 **이름을 파싱**해 쿼리 파생. `@Query` 무시 |
| `CREATE_IF_NOT_FOUND`(기본) | 선언된 쿼리(@Query/named) 먼저, 없으면 이름 파싱으로 파생 |

선언 쿼리는 `SimpleJpaQuery`(JPQL) / `NativeJpaQuery`(nativeQuery=true)로, 이름 파싱은 `PartTreeJpaQuery`로 감싼다.

### 5. 메서드 이름 파싱: `PartTree`

`CREATE` 경로에서 `PartTree`가 이름을 두 조각으로 쪼갠다.

```
findByEmailAndAgeGreaterThanOrderByCreatedAtDesc
└subject┘└──────── predicate ────────┘└── order ──┘

subject   : find|read|get|query|count|exists|delete (+Distinct, +First/Top N)
predicate : "By" 뒤. Or 로 OrPart 분해 → 각 OrPart를 And 로 Part 분해
Part      : 프로퍼티 + 키워드(GreaterThan/Like/Between/In/IsNull/After...)
order     : OrderBy 프로퍼티 + Asc/Desc
```

각 `Part`는 프로퍼티명을 엔티티 메타모델에 대고 검증한다. `AgeGreaterThan` → 프로퍼티 `age` + 키워드 `GREATER_THAN`. 카멜케이스 경계로 프로퍼티를 먼저 시도하고, 실패하면 점진적으로 짧게 잘라 **중첩 프로퍼티**(`address.city`)로 폴백한다. 이 파싱과 프로퍼티 검증이 **부트스트랩 때** 일어나므로, 오타(`findByEmial`)는 앱 기동 시점에 `PropertyReferenceException`으로 터진다 — 런타임이 아니라.

파생된 `PartTree`는 실행 시 JPA Criteria API(`CriteriaBuilder`)로 조립돼 `TypedQuery`가 된다. 즉 문자열 JPQL 연결이 아니라 Criteria 트리로 만들어진다.

### 6. 반환 타입 어댑팅

`RepositoryQuery.execute()`가 돌려준 원시 결과(대개 `List`)는 `QueryExecutionResultHandler`가 메서드 선언 타입으로 변환한다: `Optional`, 단건, `Stream`, `Page`(별도 count 쿼리 실행), `Slice`(limit+1로 hasNext 판정) 등. `Page`일 때 total count 쿼리가 추가로 나가는 것도 여기서 결정된다.

```
[부트스트랩]  인터페이스 스캔 → JpaRepositoryFactoryBean 등록
                 → getRepository(): SimpleJpaRepository target + ProxyFactory
                 → QueryExecutorMethodInterceptor 생성 시 Map<Method,RepositoryQuery> 구축
                     (QueryLookupStrategy: @Query? 아니면 PartTree 파생 — 프로퍼티 검증)
[런타임 호출]  proxy.findByEmail(x)
                 → 맵에서 RepositoryQuery 조회 → Criteria/JPQL 실행 → ResultHandler 변환
```

## 검증

Spring Data Commons 소스를 따라가 확인한 흐름:

- `RepositoryFactorySupport#getRepository(...)`가 `ProxyFactory`에 `QueryExecutorMethodInterceptor`를 어드바이스로 추가하고 target으로 `getTargetRepository(...)` 결과를 세팅하는 것 → CRUD가 위임임을 확인.
- `QueryExecutorMethodInterceptor` 생성자가 `mappingContext`/`QueryLookupStrategy`로 쿼리 메서드를 순회하며 미리 `RepositoryQuery`를 만들어 보관 → "매 호출 파싱 아님" 확인.

간단 재현 — 오타는 기동 시점에 터진다:

```java
interface UserRepository extends JpaRepository<User, Long> {
    List<User> findByEmial(String email);   // 오타: emial
}
// 애플리케이션 기동 중:
// org.springframework.data.mapping.PropertyReferenceException:
//   No property 'emial' found for type 'User'
// → 컨텍스트 로딩 실패. 이 메서드를 "호출"하지 않아도 앱이 안 뜬다.
```

이 조기 실패는 파싱/검증이 부트스트랩에 있다는 증거다.

## 잘못 알고 있던 것

- **"Spring이 리포지토리 구현 클래스를 런타임에 바이트코드로 생성한다."** → 아니다. 리포지토리 빈은 JDK **동적 프록시(디스패처)** 이고, CRUD는 이미 존재하는 `SimpleJpaRepository` 인스턴스에 위임, 쿼리 메서드는 부트스트랩 때 만들어둔 `RepositoryQuery` 객체를 꺼내 실행할 뿐이다. 새 구현 바이트코드를 찍어내는 게 아니다.
- **"메서드 이름 파싱이 매 호출마다 일어난다."** → 아니다. `PartTree`/`RepositoryQuery`는 기동 시 1회 만들어져 `Map<Method, RepositoryQuery>`에 캐시된다. 그래서 메서드 이름 오타·존재하지 않는 프로퍼티는 첫 호출이 아니라 **앱 기동 실패**로 드러난다.

## 더 파고들 만한 것

- `Page` 반환 시 나가는 count 쿼리 최적화(`countQuery`, `@Query(countQuery=...)`)와 count 프로젝션 유도 로직.
- 커스텀 프래그먼트 조합(`UserRepositoryCustom` + `UserRepositoryImpl`) 우선순위와 `RepositoryComposition`.

## 참고

- Spring Data Commons: `RepositoryFactorySupport`, `QueryExecutorMethodInterceptor`, `repository.query.QueryLookupStrategy`, `repository.query.parser.PartTree`
- Spring Data JPA: `JpaRepositoryFactory`, `SimpleJpaRepository`, `repository.query.PartTreeJpaQuery`
- Spring Data JPA Reference — Query Methods / Query Lookup Strategies / Defining Query Methods
