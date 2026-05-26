# AOP — JDK Dynamic Proxy vs CGLIB 내부 차이

> **Primary source:** Spring Framework Reference §6.8 "Proxying Mechanisms", `org.springframework.aop.framework.{JdkDynamicAopProxy, CglibAopProxy}` 소스
> **Secondary:** `java.lang.reflect.Proxy` Javadoc, CGLIB `Enhancer` 소스 (Spring 재패키지: `org.springframework.cglib.proxy.Enhancer`)
> **Date:** 2026-05-26
> **Status:** draft

## 왜 봤나

- `@Transactional` 이 붙은 메서드가 `private` 이거나 같은 클래스 내부에서 호출되면 왜 동작하지 않는지 — 결국 프록시 메커니즘에 닿는다.
- "Spring AOP는 런타임 프록시" 라는 한 줄로 외워왔지만 JDK / CGLIB 분기점과 각 경로의 실제 비용을 설명하지 못해 다시 정리.

## 핵심 한 문장

> Spring AOP는 빈을 두 가지 방식으로 감싼다 — **인터페이스가 있으면 JDK `Proxy.newProxyInstance`** 로 인터페이스 구현체를 만들고, **없으면 CGLIB이 ASM으로 바이트코드 서브클래스를 생성**해서 메서드를 `MethodInterceptor` 로 라우팅한다.

## 내부 동작

### 분기 결정 (`DefaultAopProxyFactory#createAopProxy`)

Spring Reference §6.8 에 따르면 분기는 세 가지 입력으로 결정된다.

```
ProxyConfig
 ├─ optimize           (default false)
 ├─ proxyTargetClass   (true 면 무조건 CGLIB)
 └─ hasNoUserSuppliedProxyInterfaces?
        ├─ true  → CGLIB
        └─ false → JDK Dynamic Proxy
```

Spring Boot 2.0+ 부터는 `proxyTargetClass=true` 가 기본값이라 실무에서는 대부분 CGLIB 경로로 흐른다고 알려져 있다 (`spring.aop.proxy-target-class`).

### 자료구조 / 메모리 레이아웃

| 구분 | JDK Dynamic Proxy | CGLIB |
| --- | --- | --- |
| 베이스 | `java.lang.reflect.Proxy` | ASM 바이트코드 생성 |
| 생성물 | 인터페이스 구현 클래스 `$Proxy0`, `$Proxy1` ... | 타깃의 서브클래스 `Target$$EnhancerBySpringCGLIB$$xxx` |
| 디스패치 | `InvocationHandler#invoke(proxy, Method, args[])` | `MethodInterceptor#intercept(obj, Method, args[], MethodProxy)` |
| 호출 비용 | 매 호출마다 `Method.invoke` (리플렉션) | `MethodProxy.invokeSuper` 가 내부적으로 **FastClass** 인덱스 디스패치 |
| 인스턴스당 비용 | 인터페이스 메타 + 핸들러 참조 | 부모 클래스 필드 전부 + Enhancer 메타 |

CGLIB이 빠르다고 알려진 이유는 **FastClass** 메커니즘이다. Enhancer는 타깃 클래스의 메서드 시그니처 각각에 정수 인덱스를 부여한 보조 클래스를 또 하나 만들고, 호출 시 리플렉션 대신 `switch(index)` 로 바로 분기시킨다고 알려져 있다.

### 호출 흐름 (시퀀스)

```
caller.method()
   │
   ▼
proxy instance  ─── intercept / invoke ────► AOP Alliance Chain
                                              │
                                              ├─ MethodInterceptor #1
                                              ├─ MethodInterceptor #2  (e.g. TransactionInterceptor)
                                              ▼
                                            target.method()  ← this 는 target, 프록시 아님
```

`ReflectiveMethodInvocation#proceed()` 가 인터셉터 체인을 인덱스로 순회하며 마지막에 타깃 메서드를 실행한다. 이 흐름은 JDK / CGLIB 양쪽에서 동일하다.

### 메서드 디스패치 차이 (개념도)

```
JDK:
  proxy.foo()
     → InvocationHandler.invoke(proxy, Method foo, args)
        → Method.invoke(target, args)        ※ Method.invoke = native + 액세스 체크

CGLIB:
  proxy.foo()  (override)
     → MethodInterceptor.intercept(this, Method foo, args, MethodProxy mp)
        → mp.invokeSuper(this, args)
           → FastClass.invoke(int idx, target, args)  ※ switch-case
```

## 검증

### 1) 프록시 클래스 이름으로 분기 확인

```java
@Service
class OrderService {                 // 인터페이스 X
    @Transactional public void place() { }
}

interface PaymentService { void pay(); }

@Service
class PaymentServiceImpl implements PaymentService {
    @Transactional public void pay() { }
}

@Component
class ProxyInspector {
    ProxyInspector(OrderService o, PaymentService p) {
        System.out.println(o.getClass().getName());
        // → com.example.OrderService$$SpringCGLIB$$0   (CGLIB 경로)
        System.out.println(p.getClass().getName());
        // → jdk.proxy3.$Proxy42                         (JDK 경로, JDK 17+)
    }
}
```

`AopUtils.isCglibProxy(bean)` / `AopUtils.isJdkDynamicProxy(bean)` 로도 확인 가능하다.

### 2) self-invocation 함정

`OrderService` 가 자기 메서드를 `this.other()` 로 부르면 프록시를 우회한다 — `this` 는 target 인스턴스이지 프록시가 아니기 때문. Spring Reference §6.6.1 에서 명시한다. 해결: `AopContext.currentProxy()` 활용 또는 빈 분리.

## 잘못 알고 있던 것

- "CGLIB은 final 클래스도 프록시한다" — **틀림.** CGLIB은 서브클래스를 만들기 때문에 `final` 클래스/메서드는 프록시 불가. JDK 동적 프록시도 인터페이스 기반이라 같은 한계.
- "JDK Proxy 가 항상 느리다" — 호출 비용은 CGLIB 이 보통 빠르지만, 생성 비용은 JDK 가 더 가볍다고 알려져 있다. 빈이 적고 호출이 드물면 차이는 무시 가능.
- "private 메서드도 `@Transactional` 만 붙이면 동작" — 서브클래스가 override 할 수 없으므로 CGLIB 도 `private` 은 못 가로챈다.

## 더 파고들 만한 것

- AspectJ load-time weaving (LTW) 로 프록시 한계를 우회하는 경우의 트레이드오프.
- `BeanPostProcessor` 가 프록시를 끼워넣는 정확한 시점 (`AbstractAutoProxyCreator#postProcessAfterInitialization`).

## 참고

- Spring Framework Reference §6.8 Proxying Mechanisms
- `org.springframework.aop.framework.DefaultAopProxyFactory`
- `org.springframework.aop.framework.JdkDynamicAopProxy` / `CglibAopProxy`
- `java.lang.reflect.Proxy` Javadoc
