# Raft 합의 알고리즘: 리더 선출과 로그 복제 안전성

> **Primary source:** Diego Ongaro & John Ousterhout, "In Search of an Understandable Consensus Algorithm (Extended Version)" (Raft 논문, 2014) §5
> **Secondary:** raft.github.io (시각화), etcd/raft 구현 노트
> **Date:** 2026-06-25
> **Status:** draft

## 왜 봤나

- Outbox·Saga·CAP 노트를 쓰면서 "그래서 분산 노드들이 *하나의 값*에 어떻게 합의하는가"의 바닥을 한 번도 안 팠다는 걸 깨달았다.
- "리더가 죽으면 가장 최신 노드가 리더가 된다"고 막연히 알고 있었는데, Raft는 "최신"을 term이 아니라 **로그 비교 규칙**으로 정의한다는 걸 정확히 짚고 싶었다.

## 핵심 한 문장

> Raft는 합의 문제를 **리더 선출 / 로그 복제 / 안전성** 세 부분으로 쪼개고, "선출된 리더만 로그를 쓴다 + 자신의 로그에 없는 entry를 가진 후보는 리더가 될 수 없다"는 두 제약으로 복제 상태 기계(replicated state machine)의 일관성을 보장한다.

## 내부 동작

### 1. 세 가지 상태와 term

각 노드는 항상 **Follower / Candidate / Leader** 중 하나다. 시간은 임의 길이의 **term**(논리 시계, 단조 증가 정수)으로 쪼개지고, 각 term은 최대 한 명의 리더만 가진다(선출 실패 시 0명).

```
        timeout, 선거 시작            과반 득표
  ┌──────────────────┐         ┌──────────────────┐
  │                  ▼         │                  ▼
Follower ───────► Candidate ───┘             Leader
  ▲                  │   더 높은 term의 AppendEntries/
  │                  │   투표 발견 → 강등                │
  └──────────────────┴───────────────────────────────┘
     더 높은 term 발견 시 언제나 Follower로 강등
```

term은 **모든 RPC에 실린다**. 노드는 자기 term보다 큰 term을 보면 즉시 currentTerm을 갱신하고 Follower로 강등한다. 이것이 "낡은 리더"를 자동으로 무력화하는 핵심 규칙이다.

논문 Figure 2의 노드 상태 변수(이게 머릿속에 있으면 알고리즘 전체가 풀린다):

| 분류 | 변수 | 의미 |
| --- | --- | --- |
| persistent (디스크 fsync 후 응답) | `currentTerm` | 본 적 있는 최신 term |
| persistent | `votedFor` | 이 term에 표를 준 후보 id |
| persistent | `log[]` | `{term, command}` entry 배열 |
| volatile (전 노드) | `commitIndex` | commit된 최고 index |
| volatile (전 노드) | `lastApplied` | 상태 기계에 적용한 최고 index |
| volatile (리더만) | `nextIndex[]` | 각 팔로워에 보낼 다음 index |
| volatile (리더만) | `matchIndex[]` | 각 팔로워에 복제 확인된 최고 index |

`currentTerm`/`votedFor`/`log`를 **응답 전에 디스크에 내려야** 하는 이유: 재시작한 노드가 같은 term에 두 번 투표하거나 commit된 entry를 잃으면 안전성이 깨진다.

### 2. 리더 선출 (Leader Election)

Follower는 `election timeout`(보통 150~300ms, **노드마다 랜덤**) 동안 리더의 heartbeat(빈 AppendEntries)를 못 받으면:

1. `currentTerm += 1`, 상태를 Candidate로, 자신에게 투표.
2. 모든 노드에 `RequestVote(term, candidateId, lastLogIndex, lastLogTerm)` 발송.
3. **과반(majority)** 표를 모으면 Leader 등극 → 즉시 heartbeat로 권위 선언.

타임아웃을 랜덤화하는 이유: 모두 동시에 후보가 되면 표가 갈려(split vote) 아무도 과반을 못 얻고 term만 올라간다. 랜덤이면 보통 한 노드가 먼저 타임아웃→당선되어 빠르게 수렴한다.

**투표 규칙(safety)**: 노드는 한 term에 **한 표만** 주고(persistent `votedFor`), 후보의 로그가 자기 로그보다 **최신이 아니면 거부**한다. "최신" 비교(§5.4.1):

```
후보 로그가 더 최신이다 ⇔
  (lastLogTerm 이 더 크다)
  OR (lastLogTerm 같고 lastLogIndex 가 더 크거나 같다)
```

term을 인덱스보다 먼저 본다는 점이 중요하다 — 길지만 낡은(과거 term) 로그보다, 짧아도 더 최근 term의 로그가 "최신"이다.

### 3. 로그 복제 (Log Replication)

리더만 클라이언트 쓰기를 받는다. 각 명령은 `{term, index, command}` entry로 로그에 append된 뒤 `AppendEntries` RPC로 팔로워에 복제된다.

```
index:   1     2     3     4     5
        ┌────┬────┬────┬────┬────┐
Leader  │t1  │t1  │t2  │t3  │t3  │  ← 새 entry append
        └────┴────┴────┴────┴────┘
              ▲ committed (과반 복제 완료)
```

**Commit 조건**: 어떤 entry가 **과반 노드에 복제**되면 리더는 그것을 *committed*로 표시하고 상태 기계에 적용(apply)한다. commit된 entry는 절대 사라지지 않는다(durability).

#### Log Matching Property

AppendEntries는 새 entry 직전 위치의 `(prevLogIndex, prevLogTerm)`을 함께 보낸다. 팔로워는 그 위치의 자기 entry term이 일치할 때만 받아들인다. 불일치면 거부 → 리더는 그 팔로워의 `nextIndex`를 한 칸 내려 재시도한다. 이 귀납이 보장하는 불변식:

> 두 로그가 같은 index·term의 entry를 가지면, **그 이전의 모든 entry도 동일**하다.

즉 한 지점만 맞으면 그 앞은 전부 같다. 불일치 구간은 리더 로그로 **덮어쓴다**(팔로워의 충돌 entry는 잘림). 리더는 절대 자기 로그를 덮어쓰지 않는다(append-only) — 이것이 leader-driven 단방향 흐름의 핵심.

### 4. 안전성: 왜 commit이 안 뒤집히나

리더 선출의 투표 규칙(2)이 "현재 committed된 모든 entry를 가진 노드만 당선 가능"을 강제한다. committed entry는 과반에 있고, 당선도 과반의 표가 필요하니, **두 과반은 반드시 한 노드 이상에서 겹친다**(quorum intersection). 그 겹친 노드가 더 최신 로그를 요구하므로, committed entry가 없는 후보는 과반을 못 얻는다.

#### 과거 term entry의 함정 (§5.4.2)

새 리더는 "과반에 복제됐다"는 이유만으로 **이전 term의 entry를 commit하지 않는다**. 과거 term entry가 과반에 있어도 나중에 다른 리더에게 덮일 수 있기 때문. Raft는 **현재 term의 새 entry를 commit하면서**, Log Matching에 의해 그 앞의 과거 entry까지 함께 commit되게 한다(간접 커밋).

## 검증

논문 Figure 2의 상태 변수로 한 번의 쓰기를 따라가 보면:

```
S1(leader,term=2)  log=[a@1, b@2]   nextIndex={S2:3,S3:3}  commitIndex=1
  → AppendEntries(prevIdx=1,prevTerm=1, entries=[b@2], leaderCommit=1) to S2,S3
S2 응답 success, S3 응답 success → b@2가 S1,S2,S3 (과반 3/3) 복제됨
  → S1: commitIndex=2 로 전진, b를 state machine에 apply
  → 다음 heartbeat의 leaderCommit=2 로 S2,S3도 b를 apply
```

불일치 케이스: S3가 `log=[a@1, x@1]`(낡은 entry x)을 가졌다면 prevLogIndex=1,prevLogTerm=1은 맞지만 index=2의 x@1이 b@2와 충돌 → S3는 x@1을 잘라내고 b@2를 받는다. 리더 로그 기준으로 수렴.

선출 안전성 확인: term=2에서 S3가 먼저 타임아웃해 RequestVote(lastLogTerm=1,lastLogIndex=2)를 보내도, 이미 b@2(term 2)를 가진 S1/S2는 "내 lastLogTerm=2 > 후보의 1"이므로 투표 거부 → 낡은 S3는 리더가 못 된다.

## 잘못 알고 있던 것

- **"가장 로그가 긴 노드가 리더가 된다"** — 틀림. 길이가 아니라 **(lastLogTerm, lastLogIndex)** 사전식 비교다. 짧아도 더 최근 term을 가진 로그가 이긴다. 길지만 낡은 term 로그는 진다.
- **"과반에 복제되면 무조건 commit"** — 과거 term entry엔 적용 안 된다. 리더는 *자기 term의* entry가 과반될 때만 직접 commit하고, 과거 entry는 그에 딸려 간접 commit된다. 이 미묘함을 빼먹으면 commit된 값이 뒤집히는 시나리오(논문 Figure 8)가 생긴다.
- **"리더 선출과 데이터 정합성은 별개"** — 사실 둘은 한 몸이다. 투표 시 로그 최신성 검사가 곧 "commit 불변식"을 떠받친다.

## 더 파고들 만한 것

- Membership change: joint consensus(C-old,new) vs etcd의 single-server 방식.
- Log compaction / snapshot: 무한히 커지는 로그를 어떻게 자르는가, InstallSnapshot RPC.
- Raft vs Multi-Paxos vs ZAB(ZooKeeper)의 리더십·복구 모델 차이.

## 참고

- Raft 논문 (Extended Version) §5 — Ongaro & Ousterhout, 2014
- https://raft.github.io — 상태 전이 시각화
- etcd/raft, HashiCorp raft 구현
