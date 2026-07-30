# 벡터 시계와 버전 벡터: 분산 시스템에서 "동시 쓰기"를 인과관계로 판별하는 법

> **Primary source:** DDIA (Kleppmann) Ch.5 "Detecting Concurrent Writes" / Lamport, "Time, Clocks, and the Ordering of Events in a Distributed System" (CACM 1978) / Dynamo 논문 (SOSP 2007) §4.4
> **Secondary:** Riak "Vector Clocks" docs, Wikipedia Version vector
> **Date:** 2026-07-30
> **Status:** draft

## 왜 봤나

- 멀티리더/리더리스 복제에서 "누가 최신인가"를 벽시계 타임스탬프(last-write-wins)로 정하면 되는 줄 알았는데, 그게 왜 조용히 쓰기를 잃어버리는지, 그리고 실제 시스템(Dynamo/Riak)은 어떻게 "이 둘은 동시 쓰기"라고 **판별**하는지 그 자료구조를 끝까지 보고 싶었다.
- 벡터 시계(vector clock)와 버전 벡터(version vector)를 같은 말로 알고 있었는데, 증가 주체가 다르다는 얘기를 듣고 확인하려고.

## 핵심 한 문장

> 각 노드가 "노드→카운터" 맵을 들고 다니며, 로컬 이벤트/쓰기마다 자기 카운터만 올리고 메시지를 받으면 성분별 max로 병합함으로써, 두 상태의 카운터 벡터를 성분별로 비교해 **한쪽이 다른 쪽의 인과적 조상인지, 아니면 서로 동시(concurrent)인지**를 벽시계 없이 판정한다.

## 내부 동작

### 1. 왜 논리 시계가 필요한가 — Lamport 시계의 한계

Lamport 논리 시계는 스칼라 카운터 하나다. 규칙: 로컬 이벤트마다 `C++`, 메시지 송신 시 `C`를 실어 보내고, 수신 시 `C = max(C, C_msg) + 1`. 이렇게 하면 "a가 b의 원인이면 `C(a) < C(b)`"라는 **happens-before 보존**은 된다.

하지만 역은 성립하지 않는다. `C(a) < C(b)`라고 해서 a가 b의 원인이라는 보장이 없다 — 서로 무관한(동시) 이벤트도 카운터 대소가 생기기 때문이다. 즉 Lamport 시계는 전순서(total order)를 억지로 만들지만 **"동시성"이라는 정보를 지워버린다**. 충돌을 감지하려면 "이 둘은 인과적으로 순서가 없다"를 알아야 하는데, 스칼라로는 불가능하다.

### 2. 벡터 시계 — 성분별 카운터로 동시성 복원

N개 노드면 각 노드는 길이 N의 벡터 `V`를 든다. `V[i]`는 "노드 i에서 일어난 것으로 내가 아는 이벤트 수".

```
규칙 (노드 i 기준):
- 로컬 이벤트/쓰기:      V[i] += 1
- 메시지 송신:          현재 V를 통째로 첨부
- 메시지 수신(V_msg):    for k: V[k] = max(V[k], V_msg[k]);  그다음 V[i] += 1
```

비교(부분순서):

```
V_a ≤ V_b   ⟺  ∀k. V_a[k] ≤ V_b[k]
V_a < V_b   ⟺  V_a ≤ V_b  이고  V_a ≠ V_b      → a happens-before b (a가 조상)
V_a ∥ V_b   ⟺  V_a ≤ V_b 도 아니고 V_b ≤ V_a 도 아님 → 동시(concurrent) = 충돌
```

핵심은 이게 **전순서가 아니라 부분순서(lattice)**라는 점이다. 두 벡터가 서로를 지배하지 못하는 경우가 존재하고, 바로 그 경우가 "동시 쓰기"다. 병합 연산 `join = 성분별 max`는 격자의 least upper bound라서, 두 이력을 합치면 정확히 "둘 다 반영된" 벡터가 나온다.

```
노드 A, B 두 개. 초기 (A:0, B:0)

A: 로컬 쓰기 → (A:1, B:0)  --- x1
B: 로컬 쓰기 → (A:0, B:1)  --- x2      # A소식 못들음
  (A:1,B:0) 와 (A:0,B:1): 서로 ≤ 아님 → x1 ∥ x2  (동시, 충돌!)

A가 B의 x2를 수신·병합 → (A:1,B:1) 로컬쓰기 → (A:2, B:1) --- x3
  (A:1,B:0) ≤ (A:2,B:1)  → x1 < x3  (x1은 x3의 조상, 안전하게 덮어씀)
```

### 3. 버전 벡터 — "이벤트"가 아니라 "복제본의 데이터 버전"을 센다

벡터 시계는 "프로세스에서 일어난 이벤트"를 세지만, **버전 벡터**는 "하나의 데이터 객체(키)에 대해 각 복제본이 만든 버전 수"를 센다. 증가 주체가 다르다:

- 벡터 시계: 각 노드가 자기 이벤트마다 자기 성분 증가(모든 로컬 이벤트).
- 버전 벡터: **그 쓰기를 조율(coordinate)한 복제본**만 자기 성분을 증가. 단순 전달·복제는 증가 아님, 병합(max)만.

Dynamo(§4.4)는 객체마다 버전 벡터를 `context`로 붙여 다닌다. 흐름:

```
1. get(key)  → 서버가 현재 값 + context(버전 벡터) 반환
2. put(key,value,context) → 코디네이터 복제본이 context를 복사한 뒤
                             자기 성분 +1 하여 새 버전에 부착
3. 복제본이 값을 받으면 버전 벡터로 비교:
     - 들어온 것이 내 것의 자손(≥) → 덮어씀
     - 내 것이 들어온 것의 자손    → 무시
     - 서로 ∥(동시)               → 둘 다 보관 (sibling)
4. 다음 get 때 sibling 여러 개를 반환 → 애플리케이션(또는 CRDT)이 병합(reconcile)
                                        후 병합 결과를 put하면 두 벡터의 join으로 수렴
```

여기서 벽시계는 어디에도 안 쓰인다. "최신"은 시각이 아니라 **인과 지배 관계**로 정의된다.

### 4. 자료구조와 메모리 — 왜 벡터가 무한정 못 자라나

버전 벡터는 `Map<노드ID, counter>`다. 문제는 쓰기에 관여하는 복제본/클라이언트가 많아질수록 벡터 성분 수가 늘어나 객체 하나에 붙는 메타데이터가 커진다는 것. Dynamo는 각 (노드, 카운터)에 **타임스탬프**를 같이 저장하고, 벡터가 임계 크기(예: 논문에서 10개)를 넘으면 **가장 오래된 성분부터 잘라낸다(truncation)**. 이건 이론적으로 "거짓 동시" 오판(실제로는 조상인데 잘려서 concurrent로 보임)을 만들 수 있지만, 실무에선 거의 안 걸린다고 알려져 있다.

Riak은 노드ID를 클라이언트가 아니라 서버 vnode로 잡고, actor 수·시간·크기 기준으로 벡터를 프루닝(pruning)한다. 어느 쪽이든 "성분 = 쓰기 관여 주체 수"라서 **주체를 클라이언트로 잡으면 폭발**하고, 서버 복제본으로 잡으면 유계가 된다 — 이 설계 선택이 성능을 좌우한다.

## 검증

DDIA Ch.5의 "shopping cart" 예제(두 클라이언트가 같은 장바구니에 동시에 담는 시나리오)를 버전 벡터 규칙대로 손으로 따라가 확인했다. 아래는 그 규칙을 코드로 옮긴 최소 스니펫이다.

```java
// 성분별 비교로 인과관계 판정 (벽시계 없음)
enum Ord { BEFORE, AFTER, EQUAL, CONCURRENT }

static Ord compare(Map<String,Long> a, Map<String,Long> b) {
    boolean aLess = false, aGreater = false;
    Set<String> keys = new HashSet<>(a.keySet()); keys.addAll(b.keySet());
    for (String k : keys) {
        long va = a.getOrDefault(k, 0L), vb = b.getOrDefault(k, 0L);
        if (va < vb) aLess = true;
        if (va > vb) aGreater = true;
    }
    if (aLess && aGreater) return Ord.CONCURRENT;   // ∥  → 충돌, sibling 보관
    if (aLess)  return Ord.BEFORE;
    if (aGreater) return Ord.AFTER;
    return Ord.EQUAL;
}

// join: 두 이력 병합 = 성분별 max (격자의 LUB)
static Map<String,Long> join(Map<String,Long> a, Map<String,Long> b) {
    Map<String,Long> r = new HashMap<>(a);
    b.forEach((k,v) -> r.merge(k, v, Math::max));
    return r;
}
```

`compare((A:1,B:0),(A:0,B:1))` → 한 성분은 작고 다른 성분은 크므로 `CONCURRENT`. `compare((A:1,B:0),(A:2,B:1))` → 모두 ≤이고 같지 않으므로 `BEFORE`. 예제의 대소 판정과 일치했다.

## 잘못 알고 있던 것

- **"타임스탬프로 최신 쓰기를 고르면 된다(LWW)."** 벽시계는 노드마다 어긋나고(clock skew), 무엇보다 **인과관계를 표현하지 못한다.** 서로 동시인 두 쓰기 중 벽시계가 큰 쪽을 남기면 다른 쪽 쓰기는 조용히 소실된다(lost update). 버전 벡터는 "이 둘은 애초에 순서가 없다"를 먼저 감지하고, LWW로 버릴지 병합할지는 그다음 애플리케이션이 정하는 것. LWW는 충돌 감지가 아니라 충돌 해소 정책일 뿐이다.
- **"벡터 시계 = 버전 벡터."** 구조는 같은 맵이지만 **증가 주체가 다르다.** 벡터 시계는 모든 로컬 이벤트에서 자기 성분을 올리고, 버전 벡터는 그 쓰기를 조율한 복제본만 올린다(단순 복제는 max 병합만). 그래서 버전 벡터 성분 수는 "복제본 수"에 유계지만, 클라이언트를 성분으로 잡으면 무한정 커진다.
- **"두 벡터를 비교하면 어느 쪽이 최신인지 항상 나온다."** 아니다. 벡터 비교는 **부분순서**라서 `≤`도 `≥`도 아닌 동시(∥) 상태가 존재하고, 그 경우가 곧 충돌이다. 전순서를 기대하고 "더 큰 벡터"를 고르려 하면 그 지점에서 로직이 깨진다.

## 더 파고들 만한 것

- **CRDT** (특히 state-based CvRDT): join이 격자의 LUB라는 성질이 버전 벡터와 같다. 병합이 교환·결합·멱등이면 자동 수렴 — sibling 수동 병합을 없애는 방향.
- **Dotted Version Vector**: Riak이 버전 벡터의 "false concurrency(같은 복제본의 연속 쓰기가 sibling으로 갈라지는 문제)"를 dot으로 고친 개선판.

## 참고

- DDIA (Kleppmann) Ch.5 — "Detecting Concurrent Writes", version vectors
- Lamport, "Time, Clocks, and the Ordering of Events" (CACM 1978) — happens-before, 논리 시계
- Dynamo 논문 (DeCandia et al., SOSP 2007) §4.4 — vector clock as context, truncation
- Riak Docs — Vector Clocks / Dotted Version Vectors
