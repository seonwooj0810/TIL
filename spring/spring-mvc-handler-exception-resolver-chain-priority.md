# Spring MVC HandlerExceptionResolver 체인의 예외 처리 우선순위

> **Primary source:** Spring Framework Reference "Web MVC: Exceptions", `HandlerExceptionResolver` Javadoc, `WebMvcConfigurationSupport#addDefaultHandlerExceptionResolvers`
> **Secondary:** `ExceptionHandlerExceptionResolver`, `ResponseStatusExceptionResolver`, `DefaultHandlerExceptionResolver` Javadoc
> **Date:** 2026-06-20
> **Status:** draft

## 왜 봤나

- `@ControllerAdvice`의 `@ExceptionHandler`가 항상 먼저 잡는다고 외우고 있었는데, 커스텀 `HandlerExceptionResolver`를 추가하면 실제 우선순위가 어디서 결정되는지 헷갈렸다.
- 특히 `configureHandlerExceptionResolvers`와 `extendHandlerExceptionResolvers`의 차이를 잘못 쓰면 기본 resolver 체인을 통째로 잃을 수 있다.

## 핵심 한 문장

> Spring MVC의 예외 처리는 `DispatcherServlet`이 정렬된 `HandlerExceptionResolver` 목록을 앞에서부터 호출하고, 처음으로 "처리했다"고 표시한 resolver에서 체인을 멈추는 선형 탐색이다.

## 내부 동작

### 호출 지점

Spring MVC 요청은 `DispatcherServlet#doDispatch`에서 핸들러 조회, 어댑터 실행, 뷰 렌더링 준비로 이어진다. 컨트롤러 호출 중 예외가 발생하면 `processHandlerException` 흐름으로 들어가고, 이때 등록된 `HandlerExceptionResolver` 목록을 순회한다.

공식 문서에 따르면 여러 `HandlerExceptionResolver` 빈을 선언하고 `order`를 지정해 체인을 만들 수 있다. `order` 값이 높을수록 체인의 뒤쪽에 놓인다. 즉 숫자가 작을수록 먼저 시도된다.

```
HTTP request
   |
DispatcherServlet
   |
HandlerAdapter.invokeHandlerMethod()
   |
exception thrown
   v
processHandlerException()
   |
   +--> resolver[0].resolveException(...)
   |        null? continue
   |        ModelAndView? stop
   |
   +--> resolver[1].resolveException(...)
   |        null? continue
   |        ModelAndView? stop
   |
   +--> resolver[n] ...
```

여기서 자료구조는 정렬된 `List<HandlerExceptionResolver>`에 가깝다. 정렬은 빈 수집 또는 composite 구성 시점에 끝나고, 요청 처리 시점에는 앞에서부터 한 번씩 호출하는 선형 탐색이 된다.

### 반환값이 상태 전이를 만든다

`HandlerExceptionResolver` 계약에서 중요한 것은 반환값이다.

| 반환값 | 의미 | 다음 상태 |
| --- | --- | --- |
| `null` | 이 resolver가 처리하지 않음 | 다음 resolver 호출 |
| 빈 `ModelAndView` | 응답은 resolver가 직접 처리했거나 완료됨 | 체인 중단 |
| view가 있는 `ModelAndView` | 에러 뷰로 렌더링 | 체인 중단 |

따라서 "우선순위"는 단지 먼저 호출된다는 뜻만이 아니다. 앞 resolver가 예외를 처리했다고 표시하면 뒤 resolver는 기회가 없다. 커스텀 resolver가 모든 예외에 빈 `ModelAndView`를 반환하면 `@ExceptionHandler` 기반 처리는 도달하지 못한다. 관찰 목적의 로깅 resolver라면 처리하지 않은 경우 반드시 `null`을 반환해야 뒤 체인이 보존된다.

상태 전이로 보면 다음과 같다.

```
[UNRESOLVED]
    |
    | resolver returns null
    v
[TRY_NEXT]
    |
    | resolver returns ModelAndView
    v
[RESOLVED]
    |
    | no resolver handles
    v
[RETHROW / container error handling]
```

### 기본 resolver 3종의 순서

Spring MVC Java config의 기본 구성은 `WebMvcConfigurationSupport#addDefaultHandlerExceptionResolvers`에서 만들어진다고 알려져 있다. 현재 공식 Javadoc 흐름을 기준으로 기본 목록은 다음 순서로 이해할 수 있다.

| 순서 | resolver | 주 역할 |
| --- | --- | --- |
| 1 | `ExceptionHandlerExceptionResolver` | `@ExceptionHandler` 메서드, `@ControllerAdvice` 탐색 |
| 2 | `ResponseStatusExceptionResolver` | `@ResponseStatus`, `ResponseStatusException` 처리 |
| 3 | `DefaultHandlerExceptionResolver` | Spring MVC 내부 예외를 표준 HTTP 상태로 변환 |

첫 번째 resolver는 컨트롤러 또는 advice의 메서드 매핑을 찾는다. Spring Reference에 따르면 여러 `@ControllerAdvice`가 있으면 order가 높은 advice가 먼저 고려되고, 같은 advice 안에서는 루트 예외 매칭이 cause 매칭보다 선호된다. 다만 높은 우선순위 advice의 cause 매칭이 낮은 우선순위 advice의 root 매칭보다 먼저 선택될 수 있다. 즉 "가장 구체적인 예외 타입이 전역에서 항상 이긴다"가 아니라 advice bean의 order 경계가 먼저다.

두 번째 resolver는 애너테이션 또는 예외 객체가 이미 HTTP 상태를 담고 있는 경우에 맞다. 예를 들어 `ResponseStatusException`을 던지면 이 resolver가 상태 코드를 응답에 반영한다.

세 번째 resolver는 지원하지 않는 HTTP 메서드, 메시지 변환 실패, 파라미터 바인딩 문제 같은 Spring MVC 내부 예외를 HTTP 상태로 바꾼다. 뒤에 있는 이유는 애플리케이션이 `@ExceptionHandler`나 명시적인 상태 예외로 더 구체적인 응답을 만들 기회를 먼저 주기 위함으로 볼 수 있다.

### `configure`와 `extend`의 차이

`WebMvcConfigurer#configureHandlerExceptionResolvers`의 목록은 처음에 비어 있다. 공식 Javadoc에 따르면 비워두면 프레임워크가 기본 resolver 세트를 구성한다. 반대로 resolver를 하나라도 추가하면 애플리케이션이 전체 목록을 직접 제공하는 것으로 간주되어 기본 resolver 구성이 꺼진다.

그래서 대부분의 경우 커스텀 resolver를 끼워 넣고 싶다면 `extendHandlerExceptionResolvers`가 더 안전하다. 기본 목록이 만들어진 뒤 그 목록을 수정하게 해주기 때문이다.

```java
@Configuration
class WebMvcConfig implements WebMvcConfigurer {

    @Override
    public void extendHandlerExceptionResolvers(List<HandlerExceptionResolver> resolvers) {
        resolvers.add(0, new AuditOnlyExceptionResolver());
    }
}

final class AuditOnlyExceptionResolver implements HandlerExceptionResolver {
    @Override
    public ModelAndView resolveException(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler,
            Exception ex) {

        // logging / metrics only
        return null; // keep @ExceptionHandler and default resolvers reachable
    }
}
```

위 예시는 앞쪽에 resolver를 넣지만 `null`을 반환하므로 체인을 막지 않는다. 특정 예외만 공통 JSON으로 처리한다면 그 예외에서만 응답을 쓰고 빈 `ModelAndView`를 반환해야 한다.

### 우선순위의 두 층

헷갈리는 지점은 우선순위가 한 층이 아니라는 점이다.

```
Resolver chain order
  1. Custom HandlerExceptionResolver?
  2. ExceptionHandlerExceptionResolver
       └─ @ControllerAdvice order
            └─ @ExceptionHandler method matching
  3. ResponseStatusExceptionResolver
  4. DefaultHandlerExceptionResolver
```

외부 체인에서 `ExceptionHandlerExceptionResolver`까지 도달해야 그 안의 `@ControllerAdvice` order가 의미를 갖는다. 앞단 커스텀 resolver가 모든 예외를 처리하면 `@ControllerAdvice`의 `@Order`를 조정해도 호출되지 않는다. 구조를 바꾸려면 resolver 체인 자체를 조정해야 한다.

## 검증

공식 문서와 Javadoc 흐름을 따라가며 세 지점을 확인했다.

1. Spring Reference는 resolver 체인을 만들 수 있고, `order`가 높을수록 뒤에 놓인다고 설명한다.
2. `HandlerExceptionResolver` Javadoc은 `ModelAndView` 또는 `null` 반환을 계약으로 둔다. 빈 `ModelAndView`도 처리 완료를 나타낼 수 있다.
3. `WebMvcConfigurer` Javadoc은 기본 resolver를 유지하며 수정하려면 `extendHandlerExceptionResolvers`를 제공한다.

간단한 실험을 한다면 다음처럼 순서를 찍을 수 있다.

```java
@Override
public void extendHandlerExceptionResolvers(List<HandlerExceptionResolver> resolvers) {
    resolvers.forEach(r -> System.out.println(r.getClass().getName()));
}
```

기본 Spring MVC 구성에서는 `ExceptionHandlerExceptionResolver`, `ResponseStatusExceptionResolver`, `DefaultHandlerExceptionResolver` 순서가 관찰될 것으로 예상된다. Spring Boot는 에러 처리 구성이 더해질 수 있으므로 이 노트는 Spring MVC resolver 체인 자체로 제한한다.

## 잘못 알고 있던 것

- "`@ControllerAdvice`가 전역 예외 처리의 최상위 우선순위다" — 정확하지 않다. `@ControllerAdvice`는 `ExceptionHandlerExceptionResolver` 안에서만 우선순위를 갖는다.
- "`configureHandlerExceptionResolvers`에 하나 추가하면 기본 resolver 뒤에 붙는다" — 틀렸다. 하나라도 추가하면 기본 목록을 애플리케이션이 직접 구성하는 모드가 된다.
- "로깅용 resolver는 빈 `ModelAndView`를 반환해도 된다" — 위험하다. 빈 `ModelAndView`는 처리 완료 신호라서 뒤 resolver를 막는다.

## 더 파고들 만한 것

- `ExceptionHandlerExceptionResolver` 내부의 `ExceptionHandlerMethodResolver`가 예외 타입 계층과 cause chain을 어떻게 비교하는지.
- Spring Boot의 `/error`, `BasicErrorController`, `ErrorAttributes`가 MVC resolver 체인 이후 어떤 위치에서 동작하는지.

## 참고

- Spring Framework Reference: Web MVC, "Exceptions"
- `org.springframework.web.servlet.HandlerExceptionResolver`
- `org.springframework.web.servlet.config.annotation.WebMvcConfigurer`
- `org.springframework.web.servlet.config.annotation.WebMvcConfigurationSupport`
- `org.springframework.web.servlet.mvc.method.annotation.ExceptionHandlerExceptionResolver`
