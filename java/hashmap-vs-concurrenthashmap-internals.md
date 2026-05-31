# HashMap vs ConcurrentHashMap: 내부 구조

> **Primary source:** OpenJDK 21 소스 — `java.util.HashMap`, `java.util.concurrent.ConcurrentHashMap`
> **Secondary:** Java SE 21 API docs (`HashMap`, `ConcurrentHashMap`); Doug Lea, CHM 설계 노트 (overview javadoc)
> **Date:** 2026-05-31
> **Status:** draft

## 왜 봤나

- "ConcurrentHashMap은 Segment로 쪼개서 락을 건다"고 외우고 있었는데, 이건 **Java 7 시절 설명**이고 Java 8부터 구조가 완전히 바뀌었다는 걸 뒤늦게 알았다.
- `HashMap`의 버킷이 링크드 리스트에서 **트리(red-black tree)로 변신**하는 조건을 "리스트가 8개 넘으면" 정도로만 알고 있었는데, 사실 조건이 하나가 아니었다.
- `ConcurrentHashMap.size()`가 왜 "근사값"이라고 하는지, `get()`이 어떻게 락 없이 동작하는지 소스로 따라가 보고 싶었다.

## 핵심 한 문장

> 둘 다 **버킷 배열 + 해시 분산** 골격은 같지만, `HashMap`은 동기화가 없는 단일 스레드용이고(충돌 시 리스트→트리로 최악 O(n)을 O(log n)으로 방어), `ConcurrentHashMap`은 **버킷 단위(bin head) `synchronized` + 빈 버킷 CAS + lock-free `get`**으로 동시성을 쪼개고, 크기는 `LongAdder` 스타일 카운터 분산으로 집계한다.

## 내부 동작

### 1) 공통 골격 — 해시 분산과 버킷 인덱싱

둘 다 `Node[] table`(2의 거듭제곱 크기)을 두고, key의 `hashCode()`를 한 번 더 섞은 뒤 `(n-1) & hash`로 버킷을 고른다. table 크기가 2^k라 `(n-1) & hash`는 하위 k비트만 쓰는 것과 같다 — 그래서 상위 비트가 인덱스에 반영되도록 **spread**한다.

```java
// HashMap.hash — 상위 16비트를 하위로 XOR (high bits를 인덱스에 섞기)
static final int hash(Object key) {
    int h;
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}
// ConcurrentHashMap.spread — 동일 아이디어 + 부호비트 마스킹(0x7fffffff)
static final int spread(int h) {
    return (h ^ (h >>> 16)) & HASH_BITS;  // HASH_BITS = 0x7fffffff
}
```

CHM이 최상위 비트를 0으로 마스킹하는 이유: 일반 노드 hash를 항상 ≥ 0으로 만들어 `MOVED(-1)`, `TREEBIN(-2)` 같은 **특수 노드 표식**과 구분하기 위해서다.

### 2) HashMap — 리스트와 트리, 그리고 treeify 조건

한 버킷에 충돌이 쌓이면 처음엔 단일 연결 리스트다. 길이가 임계치를 넘으면 **red-black tree**로 바꿔 최악 탐색을 O(n)→O(log n)으로 만든다. 단, 조건이 **둘**이다.

```
TREEIFY_THRESHOLD     = 8     // 한 버킷 노드 수가 8 이상이면 트리화 시도
MIN_TREEIFY_CAPACITY  = 64    // 단, table 길이가 64 미만이면 트리화 대신 resize
UNTREEIFY_THRESHOLD   = 6     // resize로 분산돼 6 이하가 되면 다시 리스트로
```

즉 노드가 8개여도 **table이 작으면(<64) 트리로 안 가고 resize**한다 — 작은 테이블의 충돌은 용량 부족일 가능성이 크기 때문. 8/6으로 임계치를 벌린 건 경계에서 트리↔리스트 진동을 막는 히스테리시스다.

```
버킷 상태 전이
  [list, len<8]  --len≥8 & table≥64-->  [red-black tree]
  [list, len≥8 & table<64]  --resize-->  분산되어 len 감소
  [tree]  --resize 후 len≤6-->  [list]
```

`get`의 평균 복잡도는 O(1), 트리 버킷이면 O(log n). resize는 용량 × 2라 한 버킷의 노드는 **"제자리(lo)" 또는 "제자리+oldCap(hi)"** 두 곳으로만 갈라진다(hash의 oldCap 비트로 판정) — 재해시 없이 비트 검사만으로 split. 또 `HashMap`은 `modCount` 기반 **fail-fast**라, 이터레이션 중 구조 변경이 감지되면 `ConcurrentModificationException`을 던진다(best-effort).

### 3) ConcurrentHashMap — Segment는 옛말, 이제 버킷 단위 락

Java 7까지는 `Segment[]`(각 segment = 작은 해시테이블 + `ReentrantLock`)로 나눠 **세그먼트 수만큼의 동시성**이었다. Java 8부터 segment를 버리고 **버킷(bin) 단위**로 내려갔다. 쓰기 경로(`putVal`)는:

```java
for (Node<K,V>[] tab = table;;) {
    int n = tab.length, i = (n - 1) & hash;
    Node<K,V> f = tabAt(tab, i);              // volatile read
    if (f == null) {
        // (a) 빈 버킷: 락 없이 CAS로 첫 노드 삽입
        if (casTabAt(tab, i, null, new Node<>(hash, key, value)))
            break;                            // 성공 → 끝, 실패 → 재시도
    } else if (f.hash == MOVED) {
        tab = helpTransfer(tab, f);           // (b) resize 중 → 거들기
    } else {
        synchronized (f) {                    // (c) 버킷 head 노드에 락
            // 리스트/트리 순회하며 갱신 or 말미 삽입
        }
    }
}
```

세 갈래가 핵심이다:
- **(a) 빈 버킷** → `synchronized` 없이 CAS 한 번. 경합 없으면 락 비용 0.
- **(c) 비어있지 않은 버킷** → 그 버킷 **head 노드**를 모니터로 `synchronized`. 락 범위가 한 버킷이라 다른 버킷 쓰기는 완전 병렬.
- **(b) MOVED** → resize가 진행 중이라는 표식(`ForwardingNode`). 쓰려던 스레드가 **이주(transfer)를 함께 돕는다**.

`get`은 **락이 전혀 없다**. `table`, 각 `Node.val`/`Node.next`가 `volatile`이라 publish된 값을 그대로 읽는다. 그래서 CHM은 **read-mostly에 특히 강하다**.

```
buckets (table)
 ┌───┬───┬───┬───┬───┐
 │ ∅ │ ● │FWD│ ● │ ∅ │   ∅=null(CAS 대상)  FWD=ForwardingNode(MOVED, 이주중)
 └───┴─│─┴─│─┴─│─┴───┘
       ▼   │   ▼
     [head]│ [TreeBin]   ← head/TreeBin 단위로 synchronized
           ▼
       (nextTable로 포워딩)
```

### 4) 협력적 resize — 여러 스레드가 나눠서 이주

CHM의 resize는 한 스레드가 다 하지 않는다. `transfer`가 버킷 범위를 **stride(최소 16)** 단위로 쪼개 할당하고, 다른 스레드가 `MOVED`를 만나면 `helpTransfer`로 빈 구간을 가져가 같이 옮긴다. 이주가 끝난 버킷엔 `ForwardingNode`를 심어 "새 테이블을 봐라"고 가리킨다. `sizeCtl`이 이 상태 머신을 관리한다:

```
sizeCtl 의미
  > 0   : 다음 resize 임계값(초기엔 capacity * 0.75)
  -1    : 테이블 초기화 진행 중
  < -1  : resize 중 — 상위 비트=리사이즈 스탬프, 하위=참여 스레드 수+1
```

### 5) size()가 근사인 이유 — 카운터 분산(LongAdder 스타일)

`put`마다 단일 카운터를 CAS로 올리면 그 한 칸이 핫스팟이 된다. CHM은 `baseCount`(volatile) 하나에 **`CounterCell[]`(스트라이프 배열)** 을 더해 경합을 분산한다 — `LongAdder`와 같은 발상이다.

```java
// size 계산: base + 모든 cell 합산
final long sumCount() {
    CounterCell[] cs = counterCells; long sum = baseCount;
    if (cs != null) for (CounterCell c : cs) if (c != null) sum += c.value;
    return sum;
}
```

`baseCount` CAS가 실패(경합)하면 스레드별 해시로 고른 `CounterCell`을 올린다. 합산은 락 없이 여러 셀을 순회하므로 그 사이 다른 스레드가 갱신하면 **스냅샷이 어긋날 수 있다** → `size()`는 정확값이 아니라 근사다(`mappingCount()`가 long 반환 권장 API).

### 6) null 금지

`HashMap`은 null 키 1개와 null 값을 허용하지만, **CHM은 둘 다 금지**(`NullPointerException`)다. 이유는 모호성: 동시 맵에서 `get(k) == null`이 "값 없음"인지 "null로 매핑됨"인지 락 없이 구별할 수 없고, `containsKey` 재확인 사이에 다른 스레드가 끼어들 수 있다. 그래서 아예 null을 배제했다.

```
                HashMap            ConcurrentHashMap
동기화          없음               버킷 단위 sync + 빈 버킷 CAS, get은 lock-free
충돌 처리       list→RB tree        list→TreeBin(RB tree), 동일 임계치(8/6/64)
resize          단일 스레드         다중 스레드 협력(transfer + helpTransfer)
size            필드 1개(정확)      baseCount+CounterCell 합산(근사)
null            key/val 1개 허용    key/val 모두 금지
iterator        fail-fast(예외)     weakly consistent(예외 안 던짐)
```

## 검증

소스 흐름과 작은 코드로 확인.

```java
// (1) treeify는 table≥64일 때만 — hashCode 고정 key를 한 버킷에 8개 넣어도
//     초기 table(16)에선 트리화 대신 resize가 먼저다(treeifyBin → resize 분기).

// (2) CHM의 get은 락 없음 — 쓰기 중에도 막힘 없이 읽힘
ConcurrentHashMap<Integer,Integer> m = new ConcurrentHashMap<>();
m.put(1, 100);
// 다른 스레드가 put(2,...)로 버킷2를 synchronized 잡고 있어도
m.get(1);   // 버킷1을 volatile 읽기로 즉시 반환, 대기 없음

// (3) null 금지 확인
m.put(null, 1);   // → NullPointerException
m.put(3, null);   // → NullPointerException
```

CHM 이터레이터는 `weakly consistent`라 생성 이후 변경을 반영할 수도/안 할 수도 있지만 `ConcurrentModificationException`은 던지지 않는다(HashMap의 fail-fast와 대비).

## 잘못 알고 있던 것

- "ConcurrentHashMap은 Segment로 락을 나눈다" → **Java 7까지의 이야기.** Java 8+는 segment를 제거하고 버킷 head 노드 `synchronized` + 빈 버킷 CAS로 더 잘게 쪼갰다.
- "버킷 리스트가 8개 넘으면 무조건 트리가 된다" → **아니다.** `table` 길이가 64 미만이면 트리화 대신 **resize**가 먼저다(`MIN_TREEIFY_CAPACITY`).
- "CHM의 `size()`는 정확하다" → 동시 환경에선 `baseCount + CounterCell` 합산이라 **근사값**이다. 정확한 스냅샷을 보장하지 않는다.
- "CHM은 모든 연산을 락으로 막는다" → `get`은 `volatile` 읽기만으로 **lock-free**다. 쓰기조차 빈 버킷이면 CAS로 락 없이 끝난다.

## 더 파고들 만한 것

- `TreeBin`의 동시성: 트리 버킷에서 read는 락 없이 하면서 write는 어떻게 직렬화하나(lockState, 읽기/쓰기 표식).
- `LongAdder`/`Striped64`의 셀 스트라이핑과 false sharing 회피(`@Contended` 패딩) — CHM 카운터가 빌려 쓰는 구조.

## 참고

- OpenJDK 21 소스 — `HashMap.java`(`hash`, `treeifyBin`, `resize`), `ConcurrentHashMap.java`(`putVal`, `transfer`, `helpTransfer`, `sumCount`, `spread`).
- Java SE 21 API docs — `ConcurrentHashMap` 클래스 javadoc(weakly consistent, null 금지, size 근사 명시).
