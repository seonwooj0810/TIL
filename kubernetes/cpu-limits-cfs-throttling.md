# Kubernetes CPU limit과 CFS throttling: cgroup quota·period가 컨테이너를 조이는 법

> **Primary source:** Linux Kernel Docs — "CFS Bandwidth Control" (scheduler/sched-bwc.html), cgroup-v2 Documentation (cpu controller)
> **Secondary:** Kubernetes 공식 docs (Resource Management for Pods and Containers), `cgroupfs` 인터페이스
> **Date:** 2026-06-29
> **Status:** draft

## 왜 봤나

- Pod에 `limits.cpu: 1`을 줬는데, CPU 사용률이 100%에 한참 못 미치는데도 응답 지연(p99)이 튀는 현상을 봤다. "limit = 1코어니까 1코어 다 쓸 때까지는 안 막히겠지"라고 막연히 생각했는데, 실제로는 그 전에 throttling이 걸렸다.
- CPU limit이 정확히 어떤 커널 메커니즘으로 강제되는지 — 즉 `limits.cpu` 한 줄이 cgroup의 quota/period로 번역되어 스케줄러가 스레드를 재우는 과정을 끝까지 따라가 보려고 봤다.

## 핵심 한 문장

> Kubernetes CPU limit은 코어 점유율 상한이 아니라, **100ms마다 리필되는 CPU 시간 예산(quota)** 이며, 한 period 안에서 예산을 다 쓰면 멀티코어로 아무리 여유가 있어도 다음 period 경계까지 그 cgroup의 모든 스레드가 강제로 throttle(재워짐)된다.

## 내부 동작

### 1. limit → quota/period 번역

리눅스의 CFS(Completely Fair Scheduler)는 `CONFIG_FAIR_GROUP_SCHED` 위에서 **CFS Bandwidth Control**을 제공한다. 한 cgroup의 CPU 대역폭은 두 값으로 정의된다 (kernel docs):

- `cpu.cfs_period_us`: 한 period의 길이(µs). 기본 **100000µs = 100ms**.
- `cpu.cfs_quota_us`: 한 period 안에서 쓸 수 있는 CPU 시간(µs). 기본 `-1`(무제한).

Kubernetes의 `limits.cpu`는 이 quota로 직접 매핑된다 (period는 기본 100ms 고정):

```
limits.cpu: "1"     → quota = 100000µs  (period 100ms의 100%)
limits.cpu: "500m"  → quota =  50000µs  (50%)
limits.cpu: "2"     → quota = 200000µs  (period 100ms 동안 200ms = 2코어어치)
```

cgroup v2에서는 두 값이 `cpu.max` 한 파일에 `"quota period"`로 합쳐진다:

```
# limits.cpu: "1.5" (cgroup v2)
$ cat /sys/fs/cgroup/.../cpu.max
150000 100000        # quota=150ms / period=100ms
```

중요한 비대칭: **`requests.cpu`는 quota가 아니다.** requests는 `cpu.shares`(v1)/`cpu.weight`(v2)로 매핑되는 **상대적 가중치**일 뿐 — 경합 시 분배 비율만 정하고 상한을 강제하지 않는다. 상한(throttling)을 만드는 건 오직 `limits.cpu`다.

### 2. quota가 소비되고 throttle되는 흐름

quota는 전역 풀에 period 경계마다 리필된다. 스레드가 runnable해지면 전역 풀에서 **slice 단위**로 per-CPU run queue("silo")로 quota를 떼어 온다 (kernel docs: "transferred to cpu-local silos on a demand basis"). 이 batch 전송이 대형 머신에서 전역 락 경합을 줄인다.

```
period 시작 (t=0ms)                          period 끝 (t=100ms)
|---------------------------------------------|
[quota 100ms 리필] → 스레드 실행하며 silo에서 소진
                          ↑
                  quota 0 도달(t=40ms)
                  → 이후 그 cgroup의 모든 스레드 THROTTLED
                  → 다음 period 경계까지 강제 sleep (60ms 놀고 있음)
```

핵심은: **"quota 소진 = throttle"이지 "코어 다 씀 = throttle"이 아니다.** quota는 _벽시계 시간_ 이 아니라 _누적 CPU·시간(cpu-seconds)_ 으로 센다. 멀티스레드 앱이 여러 코어에서 동시에 돌면 quota는 그만큼 빨리 고갈된다.

### 3. 멀티코어 burst가 일으키는 조기 throttling (가장 흔한 함정)

`limits.cpu: "1"` (quota=100ms/period 100ms)인 컨테이너가 **8코어** 노드에서 8개 스레드로 동시에 일을 시작한다고 하자:

```
8 스레드 × 12.5ms 동시 실행 = 누적 100ms CPU 시간 → 12.5ms 만에 quota 소진
→ 남은 87.5ms 동안 8개 스레드 전원 throttle
→ 벽시계 기준 CPU 사용률은 100%의 1/8밖에 안 보이는데 지연은 발생
```

평균 사용률만 보면 "limit 여유 있는데 왜 느리지?"가 된다. 모니터링에서 평균 CPU%가 limit보다 낮아도 throttling이 일어나는 전형적 원인이다. 그래서 latency 민감 워크로드에서는 CPU limit을 일부러 제거하거나(요청/가중치만 사용), period를 줄이는 식의 완화책이 논의된다.

### 4. throttle 관측 — cpu.stat

throttling은 `cpu.stat`으로 직접 측정된다:

```
$ cat /sys/fs/cgroup/.../cpu.stat
nr_periods 50000        # 지금까지 지난 period 수
nr_throttled 1200       # 그 중 throttle이 발생한 period 수
throttled_usec 95000000 # 누적 throttle된 시간(µs)
```

`nr_throttled / nr_periods`(throttle 비율)와 `throttled_usec` 증가분이 진단의 핵심 신호다. (cgroup v1은 필드명이 `throttled_time`(ns), v2는 `throttled_usec`(µs).)

### 5. burst — quota 이월 (커널 신기능)

워크로드는 보통 quota를 매 period 다 쓰지 않는다. `cpu.cfs_burst_us`(기본 0)는 _미사용 quota를 누적_ 했다가 가끔 튀는 peak에서 빌려 쓰게 해준다. kernel docs는 이를 "지금 미래의 underrun을 담보로 시간을 빌린다(bounded)"고 설명한다 — 통계적으로 평균 WCET 아래로 짜되 가끔의 spike를 허용해 조기 throttle을 줄이는 절충이다. 단 시스템 전체로는 안정성(매 overrun은 underrun과 짝지어짐)을 유지한다.

## 검증

cgroup v2 노드에서 quota 매핑을 출처(kernel cgroup-v2 문서의 `cpu.max` 포맷)대로 따라가 확인한 흐름:

```bash
# Pod: limits.cpu="500m" → 기대: cpu.max = "50000 100000"
$ POD_CG=/sys/fs/cgroup/kubepods.slice/.../<container>
$ cat $POD_CG/cpu.max
50000 100000          # quota 50ms / period 100ms = 0.5코어 ✔

# throttling 누적 관측 (period마다 갱신)
$ grep -E 'nr_(periods|throttled)|throttled_usec' $POD_CG/cpu.stat
```

`nr_throttled`가 `nr_periods` 대비 꾸준히 오르면, 평균 CPU%가 limit 미만이어도 burst 패턴 때문에 조기 throttle 중이라는 뜻이다. 이 인과(누적 cpu-time 예산 vs 벽시계 점유율)는 위 §3의 8코어 산수로 재현된다.

## 잘못 알고 있던 것

- **"limits.cpu: 1 이면 1코어를 다 쓸 때까지는 throttle 안 된다."** → 틀렸다. limit은 코어 점유율 상한이 아니라 **100ms period당 누적 CPU 시간 예산**이다. 8코어에서 동시에 돌면 12.5ms 만에 그 예산을 다 쓰고 남은 87.5ms를 강제로 논다. 멀티스레드일수록 더 빨리 막힌다.
- **"requests.cpu도 상한을 만든다."** → 아니다. requests는 `cpu.shares`/`cpu.weight`(상대 가중치)로만 매핑되어 경합 시 분배 비율을 정할 뿐, throttling을 일으키지 않는다. throttle을 만드는 건 오직 `limits.cpu`(quota)다.
- **"CPU 사용률이 limit보다 낮으면 throttling은 없다."** → 평균 사용률은 벽시계 기준이라 짧은 burst 안의 throttle을 숨긴다. 진짜 신호는 `cpu.stat`의 `nr_throttled`/`throttled_usec`다.

## 더 파고들 만한 것

- cgroup v1 `cpu.shares`(상대값, 1024 기준) vs cgroup v2 `cpu.weight`(1~10000) 매핑과 경합 시 실제 분배 계산.
- CFS의 `vruntime` 기반 공정성 스케줄링이 cgroup 계층(`cpu.cfs_quota_us`의 hierarchical 제약)과 어떻게 합쳐지는가.
- period 단축(예: 10ms)이나 burst 활성화가 throttling/지연에 미치는 효과 — 그리고 그 부작용(전역 quota 회계 압력).

## 참고

- Linux Kernel Docs — CFS Bandwidth Control: https://www.kernel.org/doc/html/latest/scheduler/sched-bwc.html
- Linux Kernel cgroup-v2 Documentation — CPU controller (`cpu.max`, `cpu.stat`, `cpu.weight`)
- Kubernetes Docs — Resource Management for Pods and Containers
