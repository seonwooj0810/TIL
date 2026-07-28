# ForkJoinPool work-stealing deque: 왜 소유자는 top에서 LIFO, 도둑은 base에서 FIFO로 꺼내는가

> **Primary source:** OpenJDK `java.util.concurrent.ForkJoinPool` / `ForkJoinPool.WorkQueue` 소스 (JDK 17) · Doug Lea, "A Java Fork/Join Framework" (2000)
> **Secondary:** Arora–Blumofe–Plumb, "Thread Scheduling for Multiprogrammed Multiprocessors" (SPAA 1998) — work-stealing deque 원형(ABP)
> **Date:** 2026-07-28
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/forkjoinpool-work-stealing-deque

## 왜 봤나

- `CompletableFuture`·`parallelStream`·가상 스레드 캐리어가 전부 공용 `ForkJoinPool` 위에서 돈다는 걸 알고 나서, 정작 그 풀 내부의 "작업 훔치기"가 자료구조 수준에서 어떻게 되는지는 뭉개고 있었다.
- 막연히 "스레드들이 큐 하나를 공유하며 꺼낸다"고 알고 있었는데, 실제로는 정반대에 가깝다.

## 핵심 한 문장

> 워커마다 자기 전용 deque를 두고 **소유자는 한쪽 끝(top)에서 LIFO로** push/pop 하고 **유휴 도둑은 반대쪽 끝(base)에서 FIFO로** 훔쳐서, 경합 지점을 큐가 거의 빌 때의 양 끝 충돌로만 좁힌 락-프리 스케줄러다.

## 내부 동작

### 큐가 하나가 아니다

`ForkJoinPool`은 공유 작업 큐 하나가 아니라 `WorkQueue[] queues` 배열을 가진다. OpenJDK 소스에 따르면 이 배열은 인덱스로 두 종류를 구분한다.

- **홀수 인덱스** = 워커 스레드 전용 큐. `fork()`가 여기 쌓인다.
- **짝수 인덱스** = 외부(풀 바깥 스레드)에서 `submit()`/`execute()`한 작업이 들어가는 submission queue.

즉 워커가 재귀적으로 쪼갠 하위 작업은 **자기 큐**에만 들어가고, 다른 스레드는 그걸 "훔쳐야" 병렬이 된다.

### deque 하나의 레이아웃

`WorkQueue` 한 개는 원형 배열 + 두 인덱스다.

```
WorkQueue
  ForkJoinTask<?>[] array   // 2의 거듭제곱 크기, mask = size-1
  int base                  // 훔치는 끝. 도둑들이 CAS로 전진 (여러 스레드가 씀)
  int top                   // 소유자 끝. 소유자만 push/pop (단일 writer)

  slot 접근:  array[i & mask]
  큐 길이  :  top - base
```

```
       base ──►               ◄── top
        │                        │
   [ t0 ][ t1 ][ t2 ][ t3 ][ t4 ][   ]
        ▲                     ▲
   도둑이 여기서 poll        소유자가 여기서 push/pop
   (오래된 것, FIFO)         (최근 것, LIFO)
```

### 세 연산

- **push (fork)** — 소유자만. `array[top & mask] = task;` 그다음 `top++` 을 release 스토어로 publish. 다른 스레드 눈에 슬롯 쓰기가 top 증가보다 먼저 보이도록 순서를 강제한다.
- **pop (소유자가 자기 것 실행)** — `top-1` 슬롯을 집는다. 방금 fork한 가장 최근 작업 → **LIFO**.
- **poll (steal)** — 도둑은 `base` 슬롯을 읽고 `CAS(base, b, b+1)` 로 전진. 성공한 한 명만 그 작업을 가져간다 → 가장 오래된 작업, **FIFO**.

소유자는 `top`만, 도둑은 `base`만 건드리므로 큐가 넉넉히 차 있는 동안엔 **양쪽이 서로 다른 캐시 라인/인덱스를 만져 경합이 없다.** 충돌은 `top - base <= 1`, 즉 큐가 거의 빌 때 마지막 한 개를 소유자와 도둑이 동시에 노릴 때뿐이고, 이때는 소유자의 pop도 CAS로 내려가 승자를 가린다.

### 왜 소유자 LIFO / 도둑 FIFO 인가 (이 비대칭이 핵심)

1. **소유자 LIFO = 지역성 + 유한 메모리.** 방금 fork한 하위 작업은 그 데이터가 아직 캐시에 뜨겁고, 부모의 지역 변수가 스택에 살아있다. top에서 최근 것을 먼저 처리하면 재귀가 사실상 **깊이 우선(DFS)** 으로 풀려, 순차 실행과 비슷한 순서 → 동시에 살아있는 미완 작업 수가 트리 깊이 수준으로 억제된다.
2. **도둑 FIFO = 큰 덩어리를 훔친다.** base 쪽 = 계산 트리에서 뿌리에 가까운, 아직 안 쪼개진 오래된 작업. 이걸 훔치면 도둑은 **한 번 훔쳐 큰 서브트리**를 가져가 자기 큐에서 다시 쪼갤 수 있다 → steal 빈도가 낮아진다. steal은 CAS+캐시 라인 이동을 동반하는 비싼 연산이라, 횟수를 줄이는 게 이득.
3. **경합 분리.** 소유자가 자주 만지는 top 끝과 도둑이 노리는 base 끝을 반대로 둠으로써, 흔한 경로(소유자 push/pop)와 드문 경로(steal)가 물리적으로 안 부딪친다.

이 "한쪽 LIFO, 반대쪽 FIFO" 구조가 ABP(1998) work-stealing deque의 원형이고, Doug Lea의 프레임워크가 이를 Java로 구현한 것이다.

### join은 블로킹이 아니라 "도와주기"

`a.fork(); b.fork(); a.join();` 에서 `join()`은 그냥 자는 게 아니다. 대상 작업이 아직 안 끝났으면 워커는:

1. 그 작업이 **자기 큐 top**에 아직 있으면 직접 pop 해서 실행(가장 흔한 경우 — fork 순서상 방금 넣은 것),
2. 아니면 그 작업을 훔쳐간 워커의 큐를 뒤져 그쪽의 다른 작업을 대신 실행(helpJoin)하며 진행을 돕는다.

그래서 join 중에도 스레드가 놀지 않고 다른 작업을 소화한다. 진짜로 막아야 하는 블로킹(`ManagedBlocker`, I/O)은 풀이 **보상 스레드(compensation)** 를 잠깐 늘려 병렬도를 유지한다.

### 유휴 워커의 스캔

훔칠 게 없으면 워커는 `queues` 배열을 (스레드별 probe 값으로) 준랜덤 시작점부터 훑어 non-empty 큐를 찾는다. 그래도 없으면 `ctl` 필드(활성/전체 워커 수를 하나의 long에 팩킹)를 CAS 해 자신을 비활성으로 표시하고 park 한다. 새 작업이 push/submit 되면 signal 받아 깨어난다.

## 검증

소스 로직을 따라 push→steal→pop 시퀀스를 손으로 돌려보면 인덱스가 어떻게 움직이는지가 드러난다 (mask 생략, 개념 흐름):

```java
// 워커 W1이 세 작업을 fork
push(t0);  // array[0]=t0, top=1   (base=0)
push(t1);  // array[1]=t1, top=2
push(t2);  // array[2]=t2, top=3

// 유휴 워커 W2가 steal 시도:  base=0 읽음 → t0, CAS(base,0,1) 성공
//   => W2는 t0(가장 오래된 것)을 가져감.  base=1
// W1이 자기 것 실행:  top-1=2 → t2(가장 최근 것) pop.  top=2
//   => LIFO.  큐엔 t1 하나 남음 (base=1, top=2)

// 이제 top-base==1: W1의 pop과 W2의 poll이 t1을 동시에 노리면
//   둘 다 CAS(base or top)로 내려가 한 명만 성공 → 이중 실행 없음
```

핵심 불변식: **소유자는 top, 도둑은 base**. 그래서 정상 구간엔 서로 다른 정수/슬롯을 만지고, 경계(길이 ≤1)에서만 CAS로 조정한다. 실제 `WorkQueue`는 `base`·`top`과 배열 참조를 `VarHandle`(구버전 `Unsafe`) acquire/release·CAS로 접근하고, false sharing을 막으려 필드에 `@Contended` 패딩을 둔다고 소스에 나온다.

## 잘못 알고 있던 것

- **"ForkJoinPool은 스레드들이 공유 큐 하나에서 꺼낸다."** 아니다. 워커마다 전용 deque가 있고, 공유되는 건 외부 제출용 submission queue(짝수 인덱스)뿐. 워커끼리는 "훔쳐서" 일을 나눈다.
- **"fork()는 곧 새 스레드에서 즉시 병렬 실행이다."** 아니다. `fork()`는 그냥 자기 큐 top에 push 하는 값싼 연산이다. 실제 병렬은 **다른 유휴 워커가 그걸 steal 할 때만** 생긴다. steal 당하지 않으면 소유자가 나중에 pop 해서 그냥 순차로 실행한다 — 그래서 오버헤드가 낮다.
- **"소유자도 도둑도 같은 방향(FIFO)으로 꺼낸다."** 아니다. 소유자는 top에서 LIFO(캐시 지역성·DFS), 도둑은 base에서 FIFO(큰 덩어리·저경합). 이 비대칭이 성능의 핵심이다.
- **"join()은 스레드를 블로킹한다."** 대체로 아니다. join은 대상이나 다른 작업을 대신 실행하며 진행을 돕고, 불가피할 때만 보상 스레드로 병렬도를 메운다.

## 더 파고들 만한 것

- `ManagedBlocker`와 compensation 스레드가 병렬도(target parallelism)를 유지하는 정확한 조건.
- `CountedCompleter`: join 없이 완료 카운트로 트리를 접는 대안 스케줄링.
- `ctl` long 필드 비트 팩킹(active/total/version)과 park/unpark signal 프로토콜.

## 참고

- Doug Lea, "A Java Fork/Join Framework" (2000)
- OpenJDK `java.util.concurrent.ForkJoinPool` / `WorkQueue` 소스 (JDK 17)
- Arora, Blumofe, Plumb, "Thread Scheduling for Multiprogrammed Multiprocessors" (SPAA 1998)
