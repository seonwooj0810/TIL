# Spring 순환참조를 푸는 3-level 캐시: singletonFactories가 조기 참조와 프록시 일관성을 지키는 법

> **Primary source:** Spring Framework 소스 `DefaultSingletonBeanRegistry` (getSingleton / addSingletonFactory), `AbstractAutowireCapableBeanFactory#doCreateBean` / `getEarlyBeanReference`
> **Secondary:** Spring Framework Reference — Core (IoC container), Spring Boot Reference (`spring.main.allow-circular-references`)
> **Date:** 2026-07-02
> **Status:** draft

## 왜 봤나

- 필드 주입 순환참조는 뜨는데 생성자 주입으로 바꾸면 `BeanCurrentlyInCreationException`이 나는 이유가 궁금했다.
- "3-level 캐시"라는 말만 알았지, 왜 2단계로는 안 되고 굳이 3단계인지, 3단계가 왜 객체가 아니라 **팩토리**를 담는지 설명하지 못했다.

## 핵심 한 문장

> Spring은 싱글톤을 **인스턴스화 직후(초기화 전)** 에 "조기 참조를 만들 수 있는 팩토리"로 노출해 두고, 순환 지점에서 그 팩토리를 **딱 한 번** 호출해 (필요하면 프록시로 감싼) 조기 참조를 만들어 캐시함으로써 setter/field 순환참조를 푼다.

## 내부 동작

`DefaultSingletonBeanRegistry`가 들고 있는 세 개의 맵이 핵심이다.

| 레벨 | 필드 | 담는 것 | 의미 |
| --- | --- | --- | --- |
| 1 | `singletonObjects` | 완성된 빈 | 초기화까지 끝난 최종 싱글톤 |
| 2 | `earlySingletonObjects` | 조기 참조(객체) | 노출됐지만 아직 프로퍼티 주입 미완 |
| 3 | `singletonFactories` | `ObjectFactory` | 조기 참조를 **생성**하는 팩토리 (아직 호출 안 함) |

추가로 `singletonsCurrentlyInCreation`(생성 중 빈 이름 Set)이 순환 여부 판정에 쓰인다.

### 조회 순서 — getSingleton

```java
Object singletonObject = this.singletonObjects.get(beanName);          // L1
if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
    singletonObject = this.earlySingletonObjects.get(beanName);        // L2
    if (singletonObject == null && allowEarlyReference) {
        ObjectFactory<?> factory = this.singletonFactories.get(beanName); // L3
        if (factory != null) {
            singletonObject = factory.getObject();          // 여기서 조기 참조 '생성'
            this.earlySingletonObjects.put(beanName, singletonObject); // L3 → L2 승격
            this.singletonFactories.remove(beanName);
        }
    }
}
```

L3에서 팩토리를 호출한 결과는 즉시 L2로 옮기고 L3에서 제거한다. 그래서 **팩토리는 빈당 최대 한 번만** 호출되고, 이후 조기 참조 요청은 전부 L2의 같은 객체를 돌려받는다.

### 순환 시나리오 — A ⇄ B (필드/세터 주입)

```
getBean(A)
 └ createBeanInstance(A)          // 생성자로 raw A 인스턴스화
 └ addSingletonFactory(A, ()->getEarlyBeanReference(A))  // ★ L3 등록 (초기화 前)
 └ populateBean(A) → A는 B 필요 → getBean(B)
      └ createBeanInstance(B)     // raw B
      └ addSingletonFactory(B, ...)                       // L3 등록
      └ populateBean(B) → B는 A 필요 → getBean(A)
           └ getSingleton(A): L1✗ → 생성중O → L2✗ → L3 팩토리 호출!
             → getEarlyBeanReference(A) = (필요시)프록시(A) → L2 승격 → 반환
      └ B가 조기 A를 주입받고 initializeBean(B) 완료 → L1 등록
 └ A가 완성된 B를 주입받고 initializeBean(A) 완료 → L1 등록
```

`addSingletonFactory`가 **인스턴스화 직후·프로퍼티 주입 전**에 실행되는 것이 전부의 열쇠다. raw 객체는 이미 힙에 있으니 참조는 넘길 수 있고, 필드 주입은 나중에 채워지므로 순환이 끊긴다.

### 왜 3단계인가 (2단계로 안 되는 이유)

L3가 객체가 아니라 `ObjectFactory`를 담는 이유는 **AOP 프록시** 때문이다. 일반적으로 프록시는 `AbstractAutoProxyCreator`가 초기화 **후처리**(`postProcessAfterInitialization`)에서 만든다. 그런데 순환 지점에서는 초기화가 끝나기 전에 A의 참조를 내줘야 한다 — 이때 B에 주입될 A는 **최종 프록시와 동일한 객체**여야 한다.

팩토리(L3)는 `getEarlyBeanReference`를 호출하고, 이는 `SmartInstantiationAwareBeanPostProcessor`(대표적으로 자동 프록시 생성기)에게 "지금 조기 참조를 프록시로 감쌀지" 물어 필요하면 **프록시를 앞당겨 생성**한다. 결과를 L2에 캐시하므로:

- 순환이 **실제로 일어난 빈만** 프록시를 조기 생성한다(모든 빈에 대해 미리 하지 않음 → 지연 평가).
- 여러 빈이 A의 조기 참조를 요청해도 **전부 같은 프록시 인스턴스**를 받는다(팩토리 1회 호출 + L2 캐시).

즉 L2는 "이미 만들어진 조기 객체(재사용용)", L3는 "아직 만들지 않은 생성 로직(프록시 여부 미정)"으로 역할이 갈린다. 두 개를 하나로 합치면 프록시 지연·단일성 중 하나가 깨진다.

### 마지막 정합성 검사

`doCreateBean` 끝에서, 조기 참조가 이미 누군가에게 노출됐는데(`earlySingletonReference != null`) 초기화 후처리가 빈을 **다른 객체로 바꿔치기**했다면(예: 조기 노출 이후 별도 프록시 생성), Spring은 이미 주입된 조기 참조와 최종 빈이 달라지는 위험을 감지해 `BeanCurrentlyInCreationException`을 던진다(`allowRawInjectionDespiteWrapping`이 false인 기본값에서). 조기 노출 경로가 프록시를 일관되게 만들어야 하는 이유가 여기서도 드러난다.

## 검증

Spring 소스를 따라가면 순서가 그대로 보인다.

- `AbstractAutowireCapableBeanFactory#doCreateBean`: `instanceWrapper = createBeanInstance(...)` 다음에
  ```java
  boolean earlySingletonExposure = (mbd.isSingleton() && this.allowCircularReferences
          && isSingletonCurrentlyInCreation(beanName));
  if (earlySingletonExposure) {
      addSingletonFactory(beanName, () -> getEarlyBeanReference(beanName, mbd, bean));
  }
  populateBean(beanName, mbd, instanceWrapper);   // 여기서 순환 주입 발생
  exposedObject = initializeBean(beanName, exposedObject, mbd);
  ```
  → 팩토리 등록이 `populateBean`보다 **앞**, 즉 초기화 전이라는 것이 확인된다.
- `DefaultSingletonBeanRegistry#getSingleton(String, boolean)`: 위의 L1→L2→L3 순서와 승격 로직이 그대로 있다.

생성자 주입으로 A(B), B(A)를 만들면 A의 `createBeanInstance` 자체가 B를 요구 → B의 `createBeanInstance`가 A를 요구 → A는 아직 `singletonsCurrentlyInCreation`에만 있고 L3 팩토리는 **등록 전**(팩토리 등록은 인스턴스화 *후*) → 조기 참조를 못 얻어 `BeanCurrentlyInCreationException`.

## 잘못 알고 있던 것

- **"3-level 캐시가 있으니 생성자 순환참조도 풀린다"** — 아니다. 조기 참조 팩토리는 `createBeanInstance`(생성자 실행) **이후**에 등록된다. 생성자 주입은 인스턴스화 *도중* 의존성을 요구하므로 팩토리가 아직 없어 순환을 못 푼다. setter/field 주입만 풀린다.
- **"L3가 객체를 담는다 / 3단계는 낭비다"** — L3는 객체가 아니라 `ObjectFactory`를 담는다. 프록시 생성을 순환이 실제 발생한 빈에 한해 지연 수행하고, 그 결과의 단일성을 L2 캐시로 보장하기 위한 구조다. 2단계면 이 둘을 동시에 만족시키기 어렵다.
- **"순환참조는 원래 정상 동작이다"** — Spring Boot 2.6+부터 `spring.main.allow-circular-references` 기본값이 false라, 3-level 캐시가 있어도 순환이 감지되면 부팅이 실패한다. 캐시는 "풀 수 있는 메커니즘"일 뿐 권장 설계는 아니다.

## 더 파고들 만한 것

- `getEarlyBeanReference`와 `AbstractAutoProxyCreator`의 조기 프록시 생성 경로, `earlyProxyReferences` 중복 방지 캐시.
- `@Lazy` 주입이 프록시로 순환을 우회하는 방식과 3-level 캐시 경로의 차이.

## 참고

- Spring Framework 소스: `DefaultSingletonBeanRegistry`, `AbstractAutowireCapableBeanFactory`
- Spring Framework Reference — Core Technologies (IoC / circular dependencies)
- Spring Boot Reference — `spring.main.allow-circular-references`
