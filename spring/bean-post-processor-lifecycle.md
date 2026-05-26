# BeanPostProcessor 라이프사이클과 호출 순서

> **Primary source:** Spring Framework Reference §1.8 "Container Extension Points", `org.springframework.beans.factory.support.AbstractAutowireCapableBeanFactory#doCreateBean / initializeBean` 소스
> **Secondary:** `InstantiationAwareBeanPostProcessor` Javadoc, `AbstractAutoProxyCreator` (AOP 적용 지점)
> **Date:** 2026-05-26
> **Status:** draft

## 왜 봤나

- 이전 AOP 노트가 "프록시는 언제 끼워지나"로 끝났는데 그 답이 결국 `BeanPostProcessor` 라서 이어 정리.
- `@PostConstruct` 가 `afterPropertiesSet` 보다 먼저인지 늦는지, 같은 인터페이스를 구현한 BPP 가 여러 개일 때 순서가 결정적인지 — 매번 헷갈렸다.

## 핵심 한 문장

> `BeanPostProcessor` 는 컨테이너가 빈 인스턴스를 생성한 뒤 **초기화 콜백(`@PostConstruct` / `afterPropertiesSet` / init-method) 직전과 직후**에 끼어들 수 있게 해주는 컨테이너 차원의 훅이고, AOP·`@Async`·`@Autowired` 모두 이 훅 위에 얹혀 있다.

## 내부 동작

### 한 빈에 대한 라이프사이클 (정확한 순서)

`AbstractAutowireCapableBeanFactory#doCreateBean` → `initializeBean` 흐름을 그대로 따라간 것.

```
1. resolveBeforeInstantiation()
     └─ InstantiationAwareBPP.postProcessBeforeInstantiation()   ← ctor 이전
        ※ 여기서 null 아닌 객체를 반환하면 이후 단계 전부 스킵 (프록시 강제 주입에 사용)

2. createBeanInstance()                            ← 생성자 호출
3. applyMergedBeanDefinitionPostProcessors()
     └─ MergedBeanDefinitionBPP.postProcessMergedBeanDefinition()

4. populateBean()
     ├─ InstantiationAwareBPP.postProcessAfterInstantiation()
     └─ InstantiationAwareBPP.postProcessProperties()             ← @Autowired 주입이 여기

5. initializeBean()
     ├─ invokeAwareMethods()                       (BeanNameAware, BeanFactoryAware, ...)
     ├─ applyBeanPostProcessorsBeforeInitialization()
     │     └─ BPP.postProcessBeforeInitialization()                ← @PostConstruct 실행은 이 단계의 BPP 하나
     ├─ invokeInitMethods()                        (afterPropertiesSet → init-method)
     └─ applyBeanPostProcessorsAfterInitialization()
           └─ BPP.postProcessAfterInitialization()                 ← AOP 프록시가 여기서 감싼다
```

핵심: `@PostConstruct` 는 별도 라이프사이클이 아니라 `CommonAnnotationBeanPostProcessor` 가 **before-initialization 단계에서** 리플렉션으로 호출하는 것이다. 그래서 순서가 `@PostConstruct` → `afterPropertiesSet` → init-method 가 된다 — 모두 "init 직전" 안에서 일어나는 일.

### BPP 자체의 호출 순서

같은 콜백을 구현한 BPP 가 여러 개 등록되어 있으면 `PostProcessorRegistrationDelegate` 가 다음 3-tier 로 정렬한다.

| 우선순위 | 조건 | 예시 |
| --- | --- | --- |
| 1 | `PriorityOrdered` 구현 | `AutowiredAnnotationBeanPostProcessor` |
| 2 | `Ordered` 구현 | `CommonAnnotationBeanPostProcessor` (@PostConstruct 처리기) |
| 3 | 둘 다 아님 | 등록 순서대로 |

Spring Reference §1.8.4 에 따르면 같은 tier 안에서는 `getOrder()` 의 정수가 작을수록 먼저 호출된다.

### AOP 와의 접점 — `AbstractAutoProxyCreator`

```
AbstractAutoProxyCreator
   ├─ implements SmartInstantiationAwareBeanPostProcessor
   ├─ postProcessBeforeInstantiation()   → @Aspect 등록된 빈이면 여기서 가로채기 가능
   └─ postProcessAfterInitialization()   → wrapIfNecessary() → ProxyFactory.getProxy(...)
```

즉 일반 빈의 경우 **초기화가 끝난 직후** 프록시로 갈아치워지고, 이후 `getBean()` 결과는 프록시다. 이 시점이라서 self-invocation 함정이 생긴다 — 생성자에서 `this.someAdvisedMethod()` 를 부르면 아직 프록시가 안 입혀진 상태라 어드바이스가 적용되지 않는다.

### 순환 참조와 3-level 캐시

`SmartInstantiationAwareBeanPostProcessor#getEarlyBeanReference` 는 빈이 생성 직후·초기화 전 단계에서 다른 빈이 참조해야 할 때 "조기 프록시" 를 만들 수 있게 한다. Spring 의 `singletonObjects / earlySingletonObjects / singletonFactories` 3단 캐시가 이 훅과 맞물려 동작한다고 알려져 있다.

## 검증

```java
@Component
class TraceBPP implements BeanPostProcessor, Ordered {

    @Override public Object postProcessBeforeInitialization(Object bean, String name) {
        if (name.equals("orderService"))
            System.out.println("BEFORE_INIT " + bean.getClass().getSimpleName());
        return bean;
    }

    @Override public Object postProcessAfterInitialization(Object bean, String name) {
        if (name.equals("orderService"))
            System.out.println("AFTER_INIT  " + bean.getClass().getSimpleName());
        return bean;
    }

    @Override public int getOrder() { return Ordered.LOWEST_PRECEDENCE; }
}

@Service
class OrderService implements InitializingBean {
    @PostConstruct       void pc()                  { System.out.println("@PostConstruct"); }
    @Override public void afterPropertiesSet()      { System.out.println("afterPropertiesSet"); }
}
```

출력 (대략):

```
BEFORE_INIT OrderService
@PostConstruct
afterPropertiesSet
AFTER_INIT  OrderService
```

`@PostConstruct` 는 `BEFORE_INIT` 안쪽에서 실행되므로 우리가 등록한 BPP 의 `before` 보다 나중에 찍힌다. 이는 `CommonAnnotationBeanPostProcessor.getOrder()` 가 더 높은 우선순위(낮은 정수)를 가져서 먼저 등록되어 있기 때문이라고 알려져 있다.

## 잘못 알고 있던 것

- "`@PostConstruct` 와 `afterPropertiesSet` 은 같은 단계" — **틀림.** 둘 다 init 직전 구간에서 호출되지만 `@PostConstruct` 가 먼저다. JSR-250 처리기가 `before-initialization` 단계의 BPP 로 등록되어 있고, `afterPropertiesSet` 은 그 다음의 `invokeInitMethods` 안에서 호출된다.
- "BPP 는 ApplicationContext 시작 시 한 번만 동작" — **틀림.** 모든 빈 생성마다 모든 BPP 의 두 콜백이 호출된다. 그래서 BPP 안에서 무거운 로직을 돌리면 시작 시간이 선형으로 늘어난다.
- "프록시는 ctor 시점에 입혀진다" — **틀림.** `postProcessAfterInitialization` 단계에서 갈아치워지므로 ctor / `@PostConstruct` 시점의 `this` 는 프록시가 아니다.

## 더 파고들 만한 것

- `BeanFactoryPostProcessor` 와의 차이 — BFPP 는 빈 정의(metadata) 를 만지고, BPP 는 인스턴스를 만진다. `ConfigurationClassPostProcessor` 동작 시점.
- `SmartInstantiationAwareBeanPostProcessor.getEarlyBeanReference` 가 3-level 캐시에서 어떻게 쓰이는지 — 순환 참조 노트로 분리.

## 참고

- Spring Framework Reference §1.8 Container Extension Points
- `org.springframework.beans.factory.support.AbstractAutowireCapableBeanFactory`
- `org.springframework.context.annotation.CommonAnnotationBeanPostProcessor`
- `org.springframework.aop.framework.autoproxy.AbstractAutoProxyCreator`
