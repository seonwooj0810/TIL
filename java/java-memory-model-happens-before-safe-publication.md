# Java Memory Model의 happens-before 규칙과 안전한 공개

> **Primary source:** Java Language Specification SE 21, Chapter 17.4 Memory Model, 특히 §17.4.4 Synchronization Order / §17.4.5 Happens-before Order
> **Secondary:** JSR-133 FAQ; OpenJDK `java.lang.Thread`, `java.util.concurrent` API docs
> **Date:** 2026-06-19
> **Status:** draft

## 왜 봤나

- `volatile`이나 `synchronized`를 "캐시를 비운다" 정도로 설명하면 실제 보장 범위가 흐려진다.
- 안전한 공개는 생성 중 write와 읽는 쪽 사용 사이에 happens-before 경로를 만드는 일인지 확인하고 싶었다.

## 핵심 한 문장

> JLS에 따르면 happens-before는 실제 시간 순서가 아니라, 프로그램 순서와 synchronizes-with 간선의 전이 폐쇄로 만들어지는 가시성/순서 판정 그래프이며, 안전한 공개는 객체를 초기화한 쓰기가 그 객체를 읽는 동작보다 happens-before가 되도록 공개 지점을 만드는 일이다.

## 내부 동작

### 1) JMM은 "실행 방법"이 아니라 "허용되는 읽기"를 정한다

JLS §17.4에 따르면 Java Memory Model은 프로그램과 실행 trace가 있을 때 각 read가 관찰한 write가 유효한지 검사한다. JMM은 CPU 캐시 구조를 그대로 모델링하지 않는다. 구현체는 JIT 최적화, 명령 재배치, 레지스터 재사용을 자유롭게 쓸 수 있지만, 최종 실행은 JMM이 허용하는 관찰 결과 안에 있어야 한다.

그래서 happens-before를 "실제로 먼저 실행됨"으로 읽으면 틀린 결론이 나온다. JLS §17.4.5는 happens-before 관계가 있어도, 재배치 결과가 합법 실행과 일치한다면 구현에서 반드시 그 순서대로 일어날 필요는 없다고 설명한다. happens-before는 **read가 어떤 write를 볼 수 있는지 판단하기 위한 부분 순서(partial order)** 로 보는 편이 정확하다.

JMM이 다루는 기본 단위는 action이다. JLS §17.4.2의 inter-thread action은 대략 다음 튜플로 볼 수 있다.

```
Action = <thread, kind, variable-or-monitor, unique-id>
```

각 스레드 안에는 program order가 있다. 스레드 내부 의미론은 보존되지만, 다른 스레드가 공유 변수 read/write를 어떻게 관찰하는지는 happens-before와 write-read 유효성 규칙으로 결정된다.

### 2) synchronizes-with 간선이 happens-before 그래프의 다리가 된다

JLS §17.4.4는 synchronization action 위에 synchronization order라는 전역 total order가 있다고 정의한다. 이것은 "모든 volatile read가 물리적으로 한 줄로 실행된다"는 뜻이라기보다, 동기화 action 사이의 선후를 설명하기 위한 규격상의 순서로 이해하는 편이 안전하다.

그 위에서 synchronizes-with 관계가 만들어진다.

```
release                                  acquire
---------------------------------------------------------------
monitor unlock(m)             -> subsequent monitor lock(m)
volatile write(v)             -> subsequent volatile read(v)
Thread.start() action         -> started thread의 첫 action
default write                 -> 각 thread의 첫 action
thread T1 final action         -> T2가 T1 종료를 감지(join/isAlive)
T1 interrupt T2               -> interrupt 감지 지점
```

JLS §17.4.5의 happens-before는 synchronizes-with 간선과 program order를 합친 뒤 전이 폐쇄를 취한 관계다.

```
program order : 같은 thread에서 x가 y보다 앞이면 hb(x, y)
synchronizes-with : sw(x, y)이면 hb(x, y)
transitive : hb(x, y) && hb(y, z)이면 hb(x, z)
```

그림으로 보면 다음과 같다.

```
Thread A                                  Thread B
--------                                  --------
obj.x = 42
obj.y = "ready"
volatile ref = obj   -- sw/hb edge -->    Object r = ref
                                            int n = r.x

program order: 초기화 쓰기 -> volatile write
sw edge     : volatile write -> volatile read
program order: volatile read -> 필드 read
transitive  : 초기화 쓰기 -> 필드 read
```

`obj.x = 42`가 volatile write가 아니어도, program order로 volatile write보다 앞에 있고, 그 volatile write가 읽는 쪽의 volatile read와 synchronizes-with 관계를 만들면, 전이성 때문에 초기화 write가 필드 read보다 happens-before가 된다. 그래서 `volatile` 참조 공개는 그 앞의 일반 필드 write까지 함께 보이도록 하는 공개 지점이 될 수 있다.

### 3) 데이터 레이스와 sequential consistency 보장

JLS §17.4.5에 따르면 같은 variable에 대한 두 접근이 충돌(conflicting)하고, 그 중 하나 이상이 write이며, 두 접근이 happens-before로 ordered 되어 있지 않으면 data race다. 올바르게 동기화된 프로그램은 sequentially consistent하게 보이는 보장을 받는다.

이 말은 "동기화가 있으면 JVM이 최적화를 안 한다"가 아니다. 프로그래머가 관찰하는 결과가 순차 일관 실행처럼 보여야 한다는 뜻이다. 반대로 data race가 있으면 이상한 결과가 가능하다. 예를 들어 다음 코드는 `ready`와 `holder` 사이에 happens-before 경로가 없다.

```java
class BrokenPublication {
    static class Holder { int value = 42; }
    static Holder holder;
    static boolean ready;

    static void writer() { holder = new Holder(); ready = true; }
    static int reader() {
        return ready ? holder.value : -1;
    }
}
```

직관적으로는 `ready == true`를 봤다면 `holder.value`도 초기화되어 보일 것 같지만, `ready`가 일반 boolean이면 `ready = true`와 `if (ready)` 사이에 synchronizes-with 간선이 없다. 공식 문서의 data race 정의에 비추면 `ready` 자체가 race이고, `holder` 참조와 필드 write의 가시성도 보장되지 않는다.

### 4) 안전한 공개의 알고리즘: release 지점과 acquire 지점을 연결한다

안전한 공개를 그래프로 생각하면 절차는 단순하다.

```
1. 객체의 불변식(invariant)을 만족시키는 write들을 끝낸다.
2. 그 뒤에 release 성격의 공개 action을 둔다.
3. 다른 스레드는 대응되는 acquire 성격의 action으로 참조를 얻는다.
4. program order + sw + transitivity로
   "초기화 write -> 참조 사용 read" hb 경로가 생기는지 확인한다.
```

대표적인 경로는 다음과 같다.

```
패턴                       hb 경로
------------------------- ----------------------------------------
volatile 참조 저장        초기화 write -> volatile write/read -> 사용
synchronized 전달         초기화 write -> unlock(m)/lock(m) -> 사용
Thread.start() 전 설정    초기화 write -> start() -> started thread action
BlockingQueue put/take    j.u.c memory consistency effect를 통한 전달
static final 초기화       class initialization 규칙을 통한 공개
final 필드                JLS §17.5 final field semantics가 별도 보강
```

`final` 필드는 JLS §17.5의 별도 규칙이다. 생성자 안에서 `this`가 빠져나가지 않고 final 필드를 설정하면, final 필드 값은 일반 필드보다 강한 초기화 가시성 보장을 받는 것으로 알려져 있다. 다만 final이 참조하는 객체의 내부 mutable 상태까지 자동으로 불변이 되는 것은 아니다.

### 5) double-checked locking이 volatile을 필요로 하는 이유

double-checked locking은 Java 5 이후 `instance`가 volatile일 때 안전한 lazy initialization 패턴으로 알려져 있다. 내부 상태 전이로 보면 `instance`는 다음 상태를 지난다.

```
UNPUBLISHED(null)
  -> CONSTRUCTING(new Service 내부 write 진행)
  -> PUBLISHED(instance volatile write)
  -> OBSERVED(instance volatile read 후 사용)
```

`volatile`이 없으면 `PUBLISHED -> OBSERVED` 사이에 synchronizes-with 간선이 없다. non-null 참조 획득과 생성자 필드 write 관찰 사이의 순서가 모델상 확보되지 않는다. `volatile`이 있으면 생성자 write들이 program order로 volatile write 앞에 있고, 그 write가 이후 volatile read와 synchronizes-with가 되어 `port` read까지 전이된다.

## 검증

이번 노트는 코드 실험보다 출처 흐름을 직접 따라갔다.

1. JLS §17.4.2에서 volatile read/write, lock/unlock, thread start/termination 감지 등이 synchronization action에 포함됨을 확인했다.
2. JLS §17.4.4에서 unlock/lock, volatile write/read, start, join/isAlive, interrupt 감지가 synchronizes-with 간선을 만든다는 점을 확인했다.
3. JLS §17.4.5에서 happens-before가 program order, synchronizes-with, transitivity로 정의되고, data race는 conflicting access가 happens-before로 ordered 되어 있지 않은 경우임을 확인했다.

따라서 안전한 공개를 판단할 때는 "객체 참조를 어디에 저장했나"만 보면 부족하다. 생성 중 일반 write에서 공개 action의 release, 소비 action의 acquire, 실제 필드 read까지 이어지는 happens-before 경로를 그려봐야 한다.

## 잘못 알고 있던 것

- "happens-before는 실제 실행 시간 순서다" → JLS 기준으로는 가시성과 순서를 판단하는 모델상의 partial order다. 구현이 반드시 그 순서로 물리 실행해야 한다는 뜻은 아니다.
- "`volatile`은 해당 변수 하나만 최신으로 만든다" → volatile write/read가 synchronizes-with 간선을 만들면, 그 앞의 일반 write도 읽는 쪽에 보이도록 공개할 수 있다.
- "생성자가 끝난 객체 참조를 넘기면 안전하다" → 참조 전달 자체가 안전한 공개는 아니다. volatile, monitor, thread start, class initialization 같은 hb 경로가 필요하다.

## 더 파고들 만한 것

- JLS §17.5 final field semantics: final 필드는 어떤 freeze action으로 가시성을 얻는가.
- VarHandle acquire/release/opaque/volatile 모드 차이.

## 참고

- Java Language Specification SE 21, Chapter 17.4: https://docs.oracle.com/javase/specs/jls/se21/html/jls-17.html
- JSR-133 Java Memory Model FAQ: https://www.cs.umd.edu/~pugh/java/memoryModel/jsr-133-faq.html
- Java SE API docs, `java.util.concurrent` package memory consistency effects.

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
