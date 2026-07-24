# 2PC(Two-Phase Commit): 원자적 커밋은 왜 코디네이터 한 대가 죽으면 멈추는가

> **Primary source:** Gray & Reuter, *Transaction Processing: Concepts and Techniques* §7.5 (Two-Phase Commit) / X/Open XA Specification (Distributed TP) / DDIA (Kleppmann) Ch.9 "Atomic Commit and Two-Phase Commit"
> **Secondary:** PostgreSQL Docs §PREPARE TRANSACTION (2PC 구현 사례)
> **Date:** 2026-07-24
> **Status:** draft

## 왜 봤나

- Saga·Outbox 노트를 쓰면서 "그럼 그냥 2PC 쓰면 안 되나?"라는 질문을 스스로에게 던졌다. 답이 "블로킹 때문에 안 쓴다"인데, 정작 **어디서 왜 블로킹되는지**는 뿌옇게 알고 있었다.
- 나는 오래 2PC를 "합의(consensus) 알고리즘의 일종"으로 뭉뚱그렸다. 실제로는 합의와 **결정적으로 다른 실패 특성**을 가진다는 걸 이 노트에서 바로잡는다.

## 핵심 한 문장

> 2PC는 모든 참여자가 "커밋 가능"을 약속(prepare)한 뒤 코디네이터가 단 하나의 결정을 내려 전파하는 **원자적 커밋 프로토콜**이며, 참여자가 yes를 투표한 순간부터 코디네이터의 결정을 들을 때까지는 스스로 abort도 commit도 할 수 없는 **in-doubt(불확실) 상태에 묶인다** — 그래서 코디네이터가 이 구간에서 죽으면 참여자는 무한정 기다린다.

## 내부 동작

### 등장 인물과 로그

- **Coordinator(TM, transaction manager)**: 결정을 내리는 단일 주체. 자신의 결정을 **durable log**에 먼저 쓴다.
- **Participant(RM, resource manager)**: 각 DB/자원. 자신의 상태 전이를 역시 로그에 남긴다.
- 핵심은 **"로그에 먼저 쓰고(force-write, fsync) 그 다음 메시지를 보낸다(write-ahead)"**. 어떤 노드가 죽었다 살아나도, 로그를 읽어 자신이 어디까지 갔는지 복원할 수 있어야 한다.

### 두 단계

```
        Coordinator                     Participants
Phase 1  ──  prepare?  ───────────────▶  각자 로컬로 commit 가능한지 검사
 (voting)                                 가능하면: <prepared> 로그 force-write
        ◀── yes(vote-commit) ─────────    (여기서부터 in-doubt, 락 유지)
             또는 no(vote-abort)

  ── 코디네이터가 모든 표를 모음 ──
  ── 하나라도 no거나 타임아웃 → ABORT, 전부 yes → COMMIT ──
  ── 결정을 <commit>/<abort> 로그에 force-write (★ commit point) ──

Phase 2  ──  commit! / abort!  ───────▶  결정대로 반영, <done> 로그
(completion)                              ack 회신
        ◀── ack ──────────────────────
  ── 모든 ack 수신 후 코디네이터 로그 정리 ──
```

**Commit point는 코디네이터가 `<commit>`을 자기 로그에 fsync한 순간**이다. 이 한 줄이 디스크에 닿는 순간 트랜잭션의 운명이 확정된다. 이 이전이면 크래시 복구 시 abort, 이후면 commit으로 밀어붙인다(재전송).

### 참여자 상태 머신

```
 INIT ──prepare?/vote-yes+force<prepared>──▶ PREPARED(=in-doubt)
   │                                              │
   │ prepare?/vote-no                             │ commit!/apply+<commit>
   ▼                                              ▼
 ABORTED ◀── abort! ──────────────────────── COMMITTED
```

여기서 **PREPARED 상태의 성질**이 2PC의 전부다:

1. 참여자는 yes를 투표하기 전에 이미 로컬 트랜잭션의 **모든 제약(유니크·FK·트리거)을 검사하고 락을 잡고, 커밋에 필요한 리두 로그까지 준비**해 둔다. 즉 "이후에 커밋하라고 하면 **절대 실패하지 않겠다**"는 약속이다.
2. 약속했으므로 참여자는 **독단적으로 abort할 수 없다**(다른 참여자는 이미 commit했을 수 있으니 원자성이 깨진다). **독단적으로 commit할 수도 없다**(다른 참여자가 no를 던졌을 수 있다).
3. 따라서 코디네이터의 Phase 2 메시지가 올 때까지 **락을 쥔 채로 기다릴 수밖에 없다.** 이 대기 구간이 in-doubt window.

### 블로킹은 정확히 어디서 생기나

코디네이터가 **commit point를 찍은 직후(= `<commit>` fsync 후) Phase 2 메시지를 보내기 전에 크래시**했다고 하자.

- 참여자는 PREPARED에 묶여 있다. 결정을 모른다. 스스로 결정하면 원자성이 깨질 수 있으니 못 한다.
- 살아있는 다른 참여자에게 물어봐도, 그들도 PREPARED면 답을 모른다(termination protocol이 실패하는 경우).
- 결국 **코디네이터가 복구되어 로그를 읽고 `<commit>`을 재전파할 때까지 무한정 대기.** 그동안 잡은 락 때문에 그 로우/테이블을 건드리는 다른 트랜잭션도 줄줄이 막힌다.

이것이 2PC가 **blocking protocol**이라 불리는 이유다. 단일 코디네이터가 **단일 장애점(SPOF)**이며, 하필 in-doubt 구간에서 죽으면 다른 노드가 대신 진행시킬 방법이 프로토콜 안에 **없다**.

### 복구(recovery) 규칙

크래시 후 로그를 읽어 상태를 되살린다:

| 로그 마지막 레코드 | 복구 시 행동 |
| --- | --- |
| 코디네이터에 `<commit>` 있음 | 참여자들에게 commit 재전송 (presumed nothing) |
| 코디네이터에 `<abort>` 있음 | abort 재전송 |
| 코디네이터에 아무 결정 없음 | **presumed abort** — 결정 안 했으니 abort로 간주, 로그도 안 남김 |
| 참여자에 `<prepared>`만 있음 | 코디네이터에게 "이 tx 어떻게 됐냐" 문의(in-doubt 조회) |
| 참여자에 결정 있음 | 그대로 재적용 |

**Presumed abort** 최적화: 코디네이터가 결정 전에 죽으면 어차피 abort이므로, abort는 로그/ack를 아낄 수 있다(참여자가 물어봤을 때 "그런 tx 모른다" → abort로 해석). 그래서 정상 커밋 경로가 abort 경로보다 로그 강제 쓰기가 더 많다.

## 검증

PostgreSQL은 XA 스타일 2PC를 SQL로 노출한다. `PREPARE TRANSACTION`이 곧 Phase 1의 참여자 측 `<prepared>` force-write에 해당한다.

```sql
-- 세션에서: 로컬 작업 후 "prepared" 상태로 못박기 (Phase 1 vote-yes)
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
PREPARE TRANSACTION 'txn-42';   -- 이 시점부터 in-doubt: 세션이 끊겨도 락과 변경이 남는다

-- 세션이 죽어도 서버 재시작해도 살아남음. 카탈로그로 확인:
SELECT gid, prepared, owner FROM pg_prepared_xacts;   -- 'txn-42'가 보인다

-- 코디네이터의 Phase 2 결정:
COMMIT PREPARED 'txn-42';   -- 또는 ROLLBACK PREPARED 'txn-42';
```

`PREPARE TRANSACTION` 실행 뒤 `COMMIT PREPARED`를 **안 하고 방치**하면, 그 트랜잭션이 잡은 락과 보유한 오래된 XID가 그대로 남아 **VACUUM이 dead tuple을 회수 못 하고**(xmin horizon이 안 밀림) 테이블이 부푼다. 이게 in-doubt window가 운영에서 실제로 아프게 만드는 지점이다 — 명세상 "대기"가 현실에선 "락 보유 + 리소스 누수"로 나타난다. `max_prepared_transactions`가 0이면 아예 `PREPARE TRANSACTION`이 거부되는 것도 이 위험 때문.

## 잘못 알고 있던 것

- **"2PC는 합의(consensus) 알고리즘이다."** — 아니다. Raft/Paxos 같은 합의는 노드 과반만 살아있으면 진행(liveness)을 보장하고 **소수 노드나 리더 장애를 견딘다**. 2PC는 정반대로 **모든 참여자의 만장일치 yes**를 요구하고(한 명이라도 no/무응답이면 abort), 코디네이터 단일 장애에 **블로킹**된다. 원자성(safety)은 지키지만 가용성(liveness)은 포기하는 프로토콜이다. 그래서 "합의로 코디네이터 자체를 복제(Raft로 만든 코디네이터)"하는 조합이 등장한다(예: 분산 DB의 Paxos/Raft-commit).

- **"yes를 던진 참여자는 타임아웃 나면 알아서 롤백하면 되지 않나?"** — Phase 1에서 코디네이터 응답을 기다리는 동안(아직 vote 전)이라면 참여자가 abort로 갈 수 있다. 하지만 **이미 vote-yes를 보내고 PREPARED가 된 뒤**에는 독단 abort가 금지된다. 다른 참여자가 이미 commit했을 수 있어 원자성이 깨지기 때문. 이 비대칭이 블로킹의 근원이다.

- **"코디네이터가 죽어도 참여자끼리 물어보면(termination protocol) 해결된다."** — 부분적으로만. 살아있는 참여자 중 하나라도 이미 commit/abort를 받았다면 그 결정을 전파해 풀 수 있다. 그러나 **모두가 PREPARED에만 머문 채 코디네이터가 죽으면** 누구도 결정을 모른다 → 여전히 블로킹. 이 창을 좁히려는 게 3PC(pre-commit 단계 추가)지만, 3PC는 네트워크 분단에서 안전성이 깨질 수 있어 실무에선 잘 안 쓴다.

## 더 파고들 만한 것

- **3PC와 그 한계**: pre-commit 단계로 in-doubt를 나눠 non-blocking을 노리지만 partition에 취약 — 왜 실무 대신 "Raft로 복제된 코디네이터"로 가는가.
- **XA 트랜잭션과 JTA**: 자바에서 `javax.transaction.xa.XAResource`의 `prepare()/commit(onePhase)`가 위 상태 머신 어디에 매핑되는가, one-phase optimization은 언제 트리거되나.
- **Percolator / Spanner의 2PC 변형**: 2PC를 Paxos 위에 얹어 코디네이터 SPOF를 제거하는 방식.

## 참고

- Gray, J. & Reuter, A. *Transaction Processing: Concepts and Techniques*, §7.5 — 2PC의 원전 격 서술과 presumed abort/commit 최적화.
- X/Open **XA Specification** — 분산 트랜잭션의 TM↔RM 인터페이스 표준.
- Kleppmann, M. *Designing Data-Intensive Applications*, Ch.9 — 블로킹 특성과 실무적 함의.
- PostgreSQL Documentation — `PREPARE TRANSACTION` / `COMMIT PREPARED` / `pg_prepared_xacts`.
