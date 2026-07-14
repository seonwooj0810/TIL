# JVM 이스케이프 분석과 스칼라 치환: 객체를 "스택에 올리는" 게 아니라 아예 없애는 법

> **Primary source:** OpenJDK HotSpot 소스 `src/hotspot/share/opto/escape.cpp` (ConnectionGraph) / `macro.cpp` (PhaseMacroExpand::scalar_replacement) / Choi et al. "Escape Analysis for Java" (OOPSLA 1999)
> **Secondary:** Oracle *Java HotSpot VM Performance Enhancements* 문서, JDK `-XX:+PrintEliminateAllocations` 출력
> **Date:** 2026-07-14
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/escape-analysis-scalar-replacement

## 왜 봤나

- "이스케이프 분석이 켜지면 객체가 힙 대신 스택에 할당된다"는 설명을 오래 믿고 있었다. 그런데 HotSpot 소스에는 "스택 할당" 경로가 안 보인다. 실제로 무슨 일이 일어나는지 끝까지 확인하려고 봤다.
- 부수적으로 "EA는 항상 켜져 있으니 임시 객체는 다 사라진다"는 오해도 있었다.

## 핵심 한 문장

> 이스케이프 분석은 C2 JIT이 객체의 **탈출 상태(NoEscape/ArgEscape/GlobalEscape)** 를 points-to 그래프로 계산하는 분석이고, 그 결과로 실제로 일어나는 최적화는 (통념과 달리) 객체의 스택 할당이 아니라 **스칼라 치환** — 객체를 그 필드들(스칼라)로 분해해 레지스터/스택 슬롯에 흩뿌려 **할당 자체를 제거**하는 것이다.

## 내부 동작

### 1. 탈출 상태 3단계

C2는 각 할당(`new`)에 대해 객체가 얼마나 멀리 "새어나가는지"를 3단계로 분류한다 (`escape.cpp`의 `PointsToNode::EscapeState`).

| 상태 | 의미 | 최적화 가능성 |
| --- | --- | --- |
| `NoEscape` | 메서드 밖으로도, 다른 스레드로도 안 나감 | 스칼라 치환 + 락 제거 |
| `ArgEscape` | 호출된 콜리에 인자로 넘어가지만 힙/스레드로는 안 샘 | 락 제거는 가능, 할당 제거는 불가 |
| `GlobalEscape` | 필드/static에 저장·반환·throw — 다른 스레드가 봄 | 최적화 없음 |

### 2. Connection Graph (points-to 분석)

핵심 자료구조는 **connection graph**다 (Choi 1999 기반). 노드 종류:

```
Object node   : new 로 생긴 객체
LocalVar node : 지역 참조 변수
Field node    : 객체의 필드
```

에지는 참조 관계를 나타낸다. **PointsTo**(참조 변수가 어떤 객체를 가리킴), **Field**(객체→필드 소유), **Deferred**(아직 확정 못 한 복사 관계 — 뒤에 실제 PointsTo로 접힘). Deferred 에지를 두는 이유는 `b = a` 같은 참조 복사를 즉시 펼치지 않고 지연시켜, 분석을 한 번의 전파로 수렴시키기 위해서다. 알고리즘 골자:

```
1. GlobalEscape 시드 표시 (static 필드, 반환값, throw, 다른 스레드 진입점)
2. 그래프에서 GlobalEscape 노드로부터 "도달 가능한" 모든 객체 노드를
   GlobalEscape로 전파 (reachability propagation)
3. 콜에 인자로 넘어가면 ArgEscape로 하향, 콜리 인라인 시 재분석
4. 어느 시드에서도 도달 불가 → NoEscape 확정
```

즉 EA는 본질적으로 **그래프 도달성 계산**이다. "이 객체 참조가 붙잡은 사슬을 따라가면 결국 힙/static/다른 스레드에 닿는가?"를 묻는 것.

### 3. 결과 최적화

`NoEscape`가 확정되면 `PhaseMacroExpand`가 세 가지를 한다:

- **스칼라 치환 (EliminateAllocations)**: 객체를 지우고 그 필드 각각을 SSA 값(레지스터/스택 슬롯)으로 대체. `Point p = new Point(x,y)` 가 있으면 힙에 `Point`는 안 생기고 `x`, `y`라는 두 스칼라만 남는다. **할당·GC·헤더(mark word/klass ptr) 전부 소멸.** 메모리 관점에서:

```
치환 전 (힙)                 치환 후 (레지스터/스택 슬롯)
┌──────────────┐
│ mark word    │  8B
│ klass ptr    │  4~8B         (객체 없음)
│ dx           │  4B     →     %r1 = dx
│ dy           │  4B           %r2 = dy
└──────────────┘  + 정렬 패딩   헤더/패딩/할당 포인터 bump 전부 제거
```

- **락 제거 (EliminateLocks)**: 스레드 밖으로 안 나가는 객체의 모니터 획득/해제는 무의미하므로 삭제. `-XX:+EliminateLocks`.
- **락 병합 (coarsening)**: 같은 객체에 연속된 synchronized 블록을 하나로 합침.

### 4. 인라이닝 의존성 — EA는 인라이닝의 함수다

EA는 **절차 내(intraprocedural)** 분석이다. 그래서 콜리가 인라인되지 않으면 인자로 넘어간 객체는 최소 `ArgEscape`로 강등되고, 콜리가 그걸 필드에 저장하면 `GlobalEscape`가 된다. C2는 인라이닝을 먼저 하고 그 뒤 확장된 IR 위에서 EA를 돌리므로, **핫 메서드가 인라인 한계(`-XX:MaxInlineSize` 등)에 걸리면 EA도 같이 무력화**된다. "왜 이 임시 객체가 안 사라지지?"의 답은 대개 "그 경로가 인라인이 안 됐다"이다.

### 5. 역최적화(deopt)와의 안전성 — 재구체화(rematerialization)

스칼라로 흩어진 객체가 있는데 C2 가정이 깨져 deopt가 일어나면? 인터프리터는 "진짜 객체"를 기대한다. HotSpot은 deopt 지점에 각 스칼라화 객체를 다시 힙에 **재할당하고 필드를 채워 넣는(reallocate & reassign)** 코드를 심어둔다. 이 재구체화 덕분에 스칼라 치환이 관찰 가능한 의미를 바꾸지 않는다 — 최적화가 sound한 이유다.

```
[C2 컴파일 코드]  x, y 스칼라만 존재
       │ deopt (가정 붕괴)
       ▼
[deopt 핸들러]   new Point 재할당 → p.x=x, p.y=y 복원
       ▼
[인터프리터]     진짜 Point 객체로 계속 실행
```

### 6. 한계

- **C2 전용**: C1(tier 1~3)엔 EA가 없다. 티어드 컴파일레이션에서 tier 4(C2)까지 승격돼야 효과가 난다 → 워밍업 전에는 임시 객체가 그대로 힙에 쌓인다.
- **배열**: 스칼라 치환은 인덱스가 상수로 접혀 길이가 컴파일 타임에 작고 확정될 때만 가능. 가변 인덱스 배열은 제외.
- `-XX:+DoEscapeAnalysis`는 기본 on이지만 "분석을 켠다"일 뿐 "할당이 반드시 사라진다"가 아니다.

## 검증

HotSpot 소스와 진단 플래그를 따라가며 확인한 흐름:

```java
// NoEscape 예시 — p는 메서드 밖으로 안 샌다
int dist2(int x1, int y1, int x2, int y2) {
    Point p = new Point(x2 - x1, y2 - y1); // 이 할당이 사라져야 정상
    return p.dx * p.dx + p.dy * p.dy;      // p.dx, p.dy 는 스칼라로 대체
}
```

- `-XX:+PrintEliminateAllocations`(fastdebug JVM)를 켜면 위 할당에 대해 `Scalar  replaced ... Point` 류의 로그가 뜬다 — 힙 할당이 실제로 제거됐다는 신호.
- 릴리스 JVM에선 간접 확인: 위 루프를 충분히 돌려 tier 4 승격 후 `-XX:+PrintGC`로 할당 압력을 본다. `-XX:-DoEscapeAnalysis`로 끄면 Young GC 빈도가 눈에 띄게 오르고, 켜면 거의 무할당으로 수렴한다.
- `escape.cpp`의 `ConnectionGraph::compute_escape()`가 위 도달성 전파를, `macro.cpp`의 `PhaseMacroExpand::scalar_replacement()`가 실제 노드 치환을 담당함을 소스에서 확인.

## 잘못 알고 있던 것

- **"EA가 켜지면 객체가 스택에 할당된다."** — HotSpot은 객체 전체를 스택에 올리는 **스택 할당을 하지 않는다.** 실제 최적화는 스칼라 치환 — 객체를 필드 스칼라들로 분해해 레지스터/스택 슬롯에 흩뿌리고, 객체라는 실체 자체를 없앤다. "스택에 올린다"는 다른 언어(Go 등)나 제안 단계 프로토타입 얘기고, 프로덕션 HotSpot의 시그니처 동작은 "할당을 통째로 지운다"이다. 헤더도, 연속된 메모리 블록도 안 생긴다.
- **"EA는 늘 켜져 있으니 지역 임시 객체는 다 사라진다."** — EA는 C2 전용이라 워밍업 전엔 무효고, 인라인이 끊기면 `ArgEscape`/`GlobalEscape`로 강등돼 할당이 남는다. 배열은 인덱스가 상수여야 하고, 조금만 복잡한 참조 사슬도 GlobalEscape로 번진다. 켜져 있다 ≠ 항상 제거된다.

## 더 파고들 만한 것

- C2 인라이닝 정책(`MaxInlineSize`, `FreqInlineSize`, late inlining)이 EA 성공률에 미치는 영향.
- 락 제거(`EliminateLocks`)와 락 병합이 실제 바이트코드/IR에서 사라지는 과정, biased locking 폐지 이후의 상호작용.

## 참고

- OpenJDK HotSpot `opto/escape.cpp`, `opto/macro.cpp`
- Choi, Gupta, Serrano, Sreedhar, Midkiff, "Escape Analysis for Java", OOPSLA 1999
- Oracle, *Java HotSpot Virtual Machine Performance Enhancements* (Escape Analysis 절)
