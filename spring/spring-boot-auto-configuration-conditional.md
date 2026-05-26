# Spring Boot 자동 설정 (@Conditional) 동작

> **Primary source:** Spring Boot Reference Documentation §6 "Auto-configuration" / `org.springframework.boot.autoconfigure.AutoConfigurationImportSelector` 소스
> **Secondary:** Spring Framework Reference §1.11 "@Conditional", `ConditionEvaluator` / `OnClassCondition` 소스
> **Date:** 2026-05-26
> **Status:** draft

## 왜 봤나

- `@SpringBootApplication` 한 줄로 DataSource, MVC, Jackson이 자동으로 떠있는 게 "어떤 순서로" "왜" 동작하는지 늘 모호하게 알고 있었다.
- `@ConditionalOnMissingBean`이 동작하는 시점을 `@Bean` 메서드 평가 시점이라고 잘못 알고 있었는데, 실제로는 더 정교하다.

## 핵심 한 문장

> Spring Boot 자동 설정은 `META-INF/spring/.../AutoConfiguration.imports` 파일에 나열된 `@Configuration` 클래스들을 `DeferredImportSelector`로 끌어들이고, 각 클래스/Bean에 붙은 `@Conditional`을 두 단계(`PARSE_CONFIGURATION` → `REGISTER_BEAN`)로 평가해 통과한 것만 BeanDefinition으로 등록한다.

## 내부 동작

### 1. 진입점: `@SpringBootApplication` → `@EnableAutoConfiguration`

`@SpringBootApplication`은 메타 어노테이션으로 `@EnableAutoConfiguration`을 포함하고, 이는 다시 `@Import(AutoConfigurationImportSelector.class)`다. `AutoConfigurationImportSelector`는 일반 `ImportSelector`가 아니라 **`DeferredImportSelector`** 를 구현한다 — 일반 `@Configuration` 파싱이 모두 끝난 뒤(deferred)에 동작해, 사용자 정의 `@Bean`이 먼저 등록되도록 보장한다.

### 2. 후보 클래스 로딩: `AutoConfiguration.imports`

Spring Boot **2.7+** 부터는 `spring.factories`(`EnableAutoConfiguration=...`)가 deprecate되고, 자동 설정 후보는 각 jar의 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 텍스트 파일에서 읽힌다. `ImportCandidates.load(AutoConfiguration.class, classLoader)` 가 모든 jar의 해당 파일을 합쳐 FQCN 리스트를 반환한다.

```
META-INF/spring/
└── org.springframework.boot.autoconfigure.AutoConfiguration.imports
    org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
    org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration
    org.springframework.boot.autoconfigure.jackson.JacksonAutoConfiguration
    ...
```

### 3. 두 단계 조건 평가: `ConfigurationPhase`

`@Conditional`의 `Condition` 구현은 `ConfigurationPhase`를 지정할 수 있다. Spring이 이걸 두 번 본다는 게 핵심이다.

| Phase | 시점 | 사용 예 |
| --- | --- | --- |
| `PARSE_CONFIGURATION` | `@Configuration` 클래스 자체를 파싱할지 결정 | `@ConditionalOnClass` |
| `REGISTER_BEAN` | 클래스 내부 `@Bean` 메서드별 BeanDefinition 등록 직전 | `@ConditionalOnMissingBean`, `@ConditionalOnBean` |

`@ConditionalOnClass`가 PARSE 단계인 이유는, 클래스가 없으면 그 `@Configuration` 본문 자체를 로딩하지 않아야 `NoClassDefFoundError`가 안 나기 때문이다. `@ConditionalOnMissingBean`은 "현재 컨테이너 상태"에 의존하므로 REGISTER_BEAN 단계로 미뤄진다.

### 4. 평가 흐름 (다이어그램)

```
        [SpringApplication.run()]
                  │
                  ▼
   ConfigurationClassParser.parse()
                  │
   ┌──────────────┴────────────────────────┐
   ▼                                       ▼
 user @Configuration         DeferredImportSelector
 (먼저 파싱됨, BeanDef 등록)  AutoConfigurationImportSelector
                                           │
                                           ▼
                           load AutoConfiguration.imports
                           → 130+ FQCN
                                           │
                                           ▼
                           AutoConfigurationSorter
                           (@AutoConfigureOrder /
                            Before / After topological sort)
                                           │
                                           ▼
                           ConditionEvaluator.shouldSkip(
                             metadata, PARSE_CONFIGURATION)
                           → OnClassCondition 등
                                           │
                                           ▼
                           통과한 클래스의 각 @Bean 메서드에 대해
                           ConditionEvaluator.shouldSkip(
                             method, REGISTER_BEAN)
                           → OnBeanCondition 등
                                           │
                                           ▼
                           BeanDefinitionRegistry 에 등록
```

### 5. `@ConditionalOnMissingBean`의 트릭

이게 동작하려면 "내가 평가될 때 컨테이너의 현재 BeanDefinition 상태"를 알아야 한다. `OnBeanCondition`은 `ConfigurableListableBeanFactory`에서 타입·이름으로 이미 등록된 BeanDefinition을 조회한다. 그래서 user `@Configuration`이 먼저 처리되어 사용자 Bean이 BeanDefinition으로 등록된 뒤에야 자동 설정 클래스의 `@Bean`이 평가되도록 `DeferredImportSelector`가 쓰인 것이다. 순서가 뒤집히면 사용자 DataSource가 있어도 Boot의 기본 DataSource가 같이 등록되어 충돌한다.

공식 문서(§8.3.4)에 따르면 `@ConditionalOnMissingBean`은 **선언된 자동 설정 클래스 범위 내에서만 안전하게 동작**하며, 클래스 레벨에서 다른 자동 설정의 Bean을 노릴 경우 그 자동 설정이 아직 처리되지 않았을 수 있어 보장이 약하다고 한다.

### 6. 자동 설정 간 순서

후보 클래스 리스트는 다음 규칙으로 정렬된다(`AutoConfigurationSorter`):

1. 알파벳 순으로 초기 정렬.
2. `@AutoConfigureOrder` 값 기준 정렬 (낮을수록 먼저).
3. `@AutoConfigureBefore` / `@AutoConfigureAfter` 의 위상 정렬(topological sort).

순환이 생기면 `IllegalStateException`. 이 정렬 결과가 BeanDefinition 등록 순서를 사실상 결정하므로, `@ConditionalOnMissingBean`의 평가 결과도 여기에 의존한다.

## 검증

`DataSourceAutoConfiguration` 소스에 두 단계 평가가 그대로 드러난다.

```java
@AutoConfiguration(before = SqlInitializationAutoConfiguration.class)
@ConditionalOnClass({ DataSource.class, EmbeddedDatabaseType.class }) // PARSE_CONFIGURATION
@ConditionalOnMissingBean(type = "io.r2dbc.spi.ConnectionFactory")
@EnableConfigurationProperties(DataSourceProperties.class)
@Import(DataSourcePoolMetadataProvidersConfiguration.class)
public class DataSourceAutoConfiguration {

    @Configuration(proxyBeanMethods = false)
    @Conditional(EmbeddedDatabaseCondition.class)
    @ConditionalOnMissingBean({ DataSource.class, XADataSource.class }) // REGISTER_BEAN
    @Import(EmbeddedDataSourceConfiguration.class)
    protected static class EmbeddedDatabaseConfiguration { }
}
```

조건 평가 로그를 직접 보고 싶으면 다음을 application.properties에 추가하면 `ConditionEvaluationReport`가 출력된다(`debug=true`도 같은 효과).

```properties
logging.level.org.springframework.boot.autoconfigure=DEBUG
```

리포트는 `Positive matches` / `Negative matches` / `Exclusions` 세 섹션으로, 각 자동 설정이 왜 통과/탈락했는지 조건별로 줄 단위로 적힌다 — `@ConditionalOnClass did not find required class 'javax.jms.ConnectionFactory'` 같은 식.

## 잘못 알고 있던 것

- **"@ConditionalOnMissingBean은 user Bean과 동시에 한 단계에서 평가된다"** — 아니다. user `@Configuration`의 모든 BeanDefinition이 먼저 등록되도록 `DeferredImportSelector`로 지연되고, 그 뒤에 REGISTER_BEAN 단계에서 평가된다. 한 단계가 아니라 **두 단계** 흐름이고, 그래서 `@ConditionalOnClass`는 `NoClassDefFoundError` 없이 안전하게 클래스 본문 로딩 자체를 막을 수 있다.
- **"자동 설정 후보는 여전히 `spring.factories`에서 읽힌다"** — Spring Boot 2.7부터는 `AutoConfiguration.imports`로 분리되었고, 3.0+에서는 `EnableAutoConfiguration` 키가 `spring.factories`에서 완전히 제거되었다.

## 더 파고들 만한 것

- `ConditionEvaluationReportLoggingListener`가 ApplicationFailedEvent와 정상 시작에서 다른 로그 레벨로 리포트를 찍는 메커니즘.
- `@AutoConfiguration` 어노테이션이 `@Configuration(proxyBeanMethods = false)` 를 강제하는 이유와 lite mode 동작.

## 참고

- Spring Boot Reference §6 "Auto-configuration", §8.3 "Condition Annotations"
- `AutoConfigurationImportSelector`, `ConditionEvaluator`, `OnBeanCondition` 소스
