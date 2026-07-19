# cgroup v2 메모리 컨트롤러와 OOM: memory.high 스로틀링과 memory.max OOM 킬의 경계

> **Primary source:** Linux Kernel Documentation — Control Group v2 §Memory (memory.min/low/high/max/events) / 소스 `mm/memcontrol.c`(try_charge, mem_cgroup_handle_over_high), `mm/oom_kill.c`(oom_badness, mem_cgroup_out_of_memory)
> **Secondary:** kernel-internals.org memcg-oom / cgroup-v2.rst
> **Date:** 2026-07-19
> **Status:** draft

## 왜 봤나

- 컨테이너가 "메모리 한도"에 닿았을 때 무슨 일이 벌어지는지 — 무조건 죽는(OOM Kill) 건지, 아니면 느려지는(throttle) 건지 — 를 뭉뚱그려 알고 있었다.
- `memory.limit`이 하나뿐이라고 생각했는데, cgroup v2에는 보호선(min/low)과 상한(high/max)이 **네 개의 서로 다른 축**으로 나뉘어 있고, 그중 OOM 킬러를 부르는 건 `memory.max` 하나뿐이라는 걸 몰랐다.

## 핵심 한 문장

> `memory.high`는 "넘으면 강제 회수 + 할당자 스로틀"의 **소프트 상한**(절대 OOM 안 냄, 초과 허용)이고, `memory.max`는 "회수해도 못 줄이면 memcg OOM 킬러 호출"의 **하드 상한**이다 — 둘은 죽이느냐/느리게 하느냐로 갈리는 별개의 벽이다.

## 내부 동작

### 인터페이스 파일: 하나의 한도가 아니라 네 개의 축

cgroup v2 non-root 그룹의 메모리 컨트롤러는 usage를 아래 네 값으로 규율한다. 아래로 갈수록 강한 제약이다.

```
   memory.min   ── 하드 보호. 이 밑으로는 어떤 상황에서도 회수(reclaim) 안 함.
   memory.low   ── 베스트에포트 보호. 다른 곳에 회수할 게 없을 때만 회수.
 ───────────────  (usage가 여기를 넘어가기 시작)
   memory.high  ── 소프트 상한. 넘으면 heavy reclaim + 할당자 스로틀. OOM 안 냄.
   memory.max   ── 하드 상한. 회수 실패 시 memcg OOM 킬러 호출.
```

- `memory.current`: 그룹 + 하위 그룹이 지금 쓰는 총량(read-only).
- `memory.min`/`memory.low`: **상한이 아니라 하한 보호선**이다. 시스템이 메모리 압박을 받아 페이지를 회수할 때, min 이하로는 절대 뺏지 않고(min), low는 "정말 다른 데서 뺏을 게 없을 때만" 뺏는다. 즉 회수 대상 우선순위를 정하는 값이다.
- `memory.high`/`memory.max`: 실제 상한. 이 둘의 차이가 이 노트의 핵심이다.

### charge 경로: 모든 페이지 할당은 조상 트리로 올라가며 검사된다

프로세스가 페이지를 얻을 때마다 `mm/memcontrol.c`의 `try_charge()`가 호출되어, 해당 cgroup부터 **루트까지 조상 각각의 한도**를 확인하며 usage를 누적(charge)한다. 어느 조상에서 한도에 걸리면 그 그룹 범위 안에서 회수를 시도한다 — 페이지 캐시, 회수 가능한 slab, (스왑이 있으면) 익명 페이지를 대상으로. 익명 페이지는 스왑 없이는 회수 불가라, `memory.swap.max=0`인 컨테이너에서 힙이 커지면 회수할 게 파일 캐시밖에 없어 곧장 OOM으로 직행하기 쉽다. 이 charge가 조상까지 올라간다는 점이, 개별 컨테이너는 한도 안이어도 **상위 그룹(Pod/노드 슬라이스) 한도에서 걸려** 스로틀/OOM이 나는 이유다.

### memory.high — "넘어도 안 죽는다. 대신 느려진다"

`memory.high`를 초과하면:

1. 그룹의 프로세스들이 **heavy reclaim pressure** 아래 놓인다 — 할당 시 direct reclaim을 직접 수행하게 된다.
2. 그래도 usage가 high 위에 머물면, 커널은 **할당자 스로틀(penalty stall)**을 건다. 초과분에 비례해 계산된 지연을 `mem_cgroup_handle_over_high()`가 유저스페이스 복귀 직전에 `schedule_timeout_killable()`로 재운다. 이 페널티는 상한이 있어(대략 최대 2초/`MEMCG_MAX_HIGH_DELAY_JIFFIES`) 한 번에 무한정 재우진 않지만, 초과가 지속되면 반복 부과되어 애플리케이션은 "간헐적 지연/멈칫"으로 체감한다.
3. **절대 OOM 킬러를 부르지 않는다.** 극단적 상황에선 high를 넘어서까지 usage가 breach되는 것도 허용한다.

즉 high는 "죽이지 않고 압력으로 눌러 스스로 줄이게 만드는" 소프트 상한이다. `memory.events`의 `high` 카운터가 스로틀 횟수다.

### memory.max — "회수해도 못 줄이면 죽인다"

`memory.max`에 usage가 닿고 회수로도 못 줄이면, **그 cgroup 안에서** OOM 킬러(`mem_cgroup_out_of_memory()`)가 발동한다. 이것이 memcg OOM이며, 시스템 전체 global OOM과 구분된다 — 다른 컨테이너는 멀쩡한데 한도 넘긴 그룹 안에서만 프로세스가 죽는다.

한 가지 예외: `memory.max`를 `O_NONBLOCK`으로 열어 쓰면 동기 reclaim과 oom-kill이 **바이패스**된다. 그래서 관리 프로세스가 한도를 낮출 때 자기 자신을 죽이지 않고 조정할 수 있다.

### 희생자 선정: oom_badness()

memcg OOM에서 누구를 죽일지는 `mm/oom_kill.c`의 `oom_badness()`가 프로세스별 점수로 정한다. 공식은 대략:

```
score = rss_anon + rss_file + rss_shmem + swapents + pgtables_pages
        + (oom_score_adj * totalpages / 1000)
```

- 기본은 **메모리를 많이 쓰는 놈이 높은 점수 → 먼저 죽는다**.
- `oom_score_adj`(-1000..+1000)로 편향을 준다. -1000이면 점수가 음수로 눌려 사실상 면제.
- 결정적 포인트: memcg OOM에서 `totalpages`는 **시스템 전체 RAM이 아니라 그 그룹의 memory.max(또는 그에 준하는 값)**다. 그래서 "전체 대비 몇 %"가 아니라 "이 컨테이너 한도 대비 몇 %"로 점수가 매겨진다.

`memory.oom.group=1`을 켜면 개별 프로세스가 아니라 **그룹 전체를 하나의 단위로** 죽여, 워크로드가 절반만 죽어 좀비처럼 남는 걸 막는다.

### PSI: 죽기 전에 압력을 관측

`memory.pressure`(PSI)는 "메모리 부족으로 작업이 지연된 시간 비율"을 준다. some/full 지표로 OOM에 이르기 전 압력을 조기 감지해, 오케스트레이터가 미리 스케일아웃하거나 트래픽을 뺄 수 있다.

## 검증

Linux 커널 문서(cgroup-v2 §Memory)와 소스 흐름을 따라가 확인했다. 개념적 시나리오로 정리하면:

```
# 어떤 컨테이너 그룹
memory.high = 512M
memory.max  = 600M

usage 480M → 정상. 스로틀 없음.
usage 520M → high 초과. direct reclaim 시작 + 페널티 지연 부과.
             회수로 490M까지 떨어지면 스로틀 해제. (프로세스는 안 죽음)
usage 601M로 튐 → max 초과. reclaim 시도.
             회수 성공해 580M 되면 계속 실행.
             회수 실패로 못 줄이면 → 그룹 내 oom_badness 최고 점수 프로세스 kill.
             memory.events: oom_kill += 1
```

`memory.events` 파일의 `high`/`max`/`oom`/`oom_kill` 카운터를 읽으면, 이 그룹이 "스로틀만 당했는지"(high↑, oom_kill=0) "실제 죽었는지"(oom_kill↑)를 사후에 구분할 수 있다.

## 잘못 알고 있던 것

- **오해 1: "메모리 한도에 닿으면 무조건 OOM으로 죽는다."**
  실제로는 `memory.high`는 절대 OOM을 내지 않는다 — 넘겨도 죽이지 않고 회수 압력과 할당자 스로틀로 눌러 스스로 줄이게 한다. OOM 킬은 오직 `memory.max`에서 회수마저 실패했을 때만. 그래서 컨테이너가 "안 죽는데 이상하게 느리다"면 high 스로틀을 의심해야 한다.

- **오해 2: "OOM 점수는 시스템 전체 RAM 대비 사용량으로 매겨진다."**
  memcg OOM에서 `oom_badness()`의 기준 총량(`totalpages`)은 시스템 RAM이 아니라 **그 cgroup의 한도**다. 128GB 머신이라도 512MB 한도 컨테이너 안에서 죽을 프로세스는 512MB 기준으로 점수화된다.

- **오해 3: "memory.min/low도 상한이다."**
  이 둘은 상한이 아니라 **회수로부터의 하한 보호선**이다. usage를 막는 게 아니라, 메모리 압박 시 이 그룹의 페이지를 얼마나 늦게 뺏을지를 정한다.

## 더 파고들 만한 것

- global OOM(시스템 전역) vs memcg OOM의 트리거·희생자 선정 차이, `oom_score_adj`와 컨테이너 런타임(kubelet)의 QoS 클래스 매핑.
- `memory.high` 페널티 지연 계산식(초과분↔jiffies)과 cgroup v1 memory controller의 (스로틀 없는) 하드 리밋 차이.

## 참고

- Linux Kernel Documentation — Control Group v2, Memory Controller (memory.min/low/high/max/events, memory.oom.group)
- `mm/memcontrol.c` — try_charge, mem_cgroup_handle_over_high, mem_cgroup_out_of_memory
- `mm/oom_kill.c` — oom_badness
- kernel-internals.org — Cgroup OOM / memcg 정리
