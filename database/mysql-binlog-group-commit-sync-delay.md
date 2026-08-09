# MySQL Binary Log Group Commit: sync_delay 배치 윈도우와 커밋 순서 보장이 durability와 처리량을 함께 얻는 법

> **Primary source:** MySQL 8.0 Reference Manual §19.1.6.4 "Binary Logging Options and Variables" (`binlog_group_commit_sync_delay`, `binlog_group_commit_sync_no_delay_count`, `binlog_order_commits` 시스템 변수 문서) / `innodb_flush_log_at_trx_commit` 시스템 변수 문서
> **Secondary:** MySQL 8.0 Reference Manual Chapter 17 (InnoDB) 로깅 관련 서술
> **Date:** 2026-08-09
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/mysql-group-commit-sync-delay

## 왜 봤나

- "durability를 지키려면 트랜잭션마다 fsync를 해야 하고, fsync는 비싸니 durability와 처리량은 트레이드오프"라는 명제는 절반만 맞다. MySQL의 group commit은 이 트레이드오프의 상수항을 바꾼다 — 트랜잭션 개수당 fsync 비용을 낮추면서도 커밋을 확인받은 트랜잭션의 durability는 그대로 유지한다.
- 흔한 혼동: "`sync_binlog=1`이면 매 트랜잭션마다 fsync가 발생해서 그룹 커밋이 무력화된다"는 생각. 실제로는 `sync_binlog=1`이어도 같은 그룹에 묶인 트랜잭션들은 fsync 1회를 공유한다. 그룹의 크기를 결정하는 건 동시성(같은 순간에 커밋 대기 중인 트랜잭션 수)과, 이번에 다룰 `binlog_group_commit_sync_delay`라는 별도의 배치 윈도우 지연 노브다.

## 핵심 한 문장

> MySQL은 binlog fsync 앞에 마이크로초 단위 지연 윈도우(`binlog_group_commit_sync_delay`)를 끼워 넣어 그 순간 도착한 트랜잭션들을 한 그룹으로 모은 뒤 fsync 1회로 묶어 처리하며, 이 그룹 내부 순서와 스토리지 엔진 커밋 순서의 일치는 `binlog_order_commits`가 별도로 보장한다.

## 내부 동작

### 1. group commit이 없다면 생기는 문제

각 트랜잭션이 커밋될 때 클라이언트에게 "커밋됐다"고 응답하려면, 그 트랜잭션의 로그가 디스크에 실제로 내려갔다는 보장(fsync)이 있어야 한다. 순진하게 트랜잭션마다 독립적으로 binlog에 쓰고 fsync하면, 동시에 100개의 트랜잭션이 커밋을 시도할 때 디스크는 fsync 100번을 순차 처리해야 한다. fsync는 디스크 회전/컨트롤러 배리어 대기가 있는 상대적으로 느린 연산이라, 이게 처리량의 하한을 만든다.

group commit의 아이디어는 "어차피 비슷한 시점에 도착한 여러 트랜잭션의 binlog write를 모아서, fsync는 그 묶음 전체에 대해 한 번만 하자"는 것이다. 그룹에 속한 트랜잭션은 모두 같은 fsync 완료 시점에 "커밋됨" 확인을 받으므로, 개별 트랜잭션의 durability(그 fsync 이후에는 크래시가 나도 사라지지 않는다는 보장)는 그대로 유지된다. 줄어드는 것은 fsync *횟수*이지 durability *수준*이 아니다.

### 2. 배치 윈도우: `binlog_group_commit_sync_delay`

문제는 그룹의 크기가 순전히 "그 순간의 동시성"에 의존한다는 점이다. 부하가 낮으면 트랜잭션들이 시간축에서 떨어져 도착하고, 그룹은 자연히 1개짜리로 쪼그라들어 group commit의 이점이 사라진다.

`binlog_group_commit_sync_delay`는 이 자연 발생 그룹을 인위적으로 넓히는 지연 윈도우다(단위: 마이크로초, 기본값 0=지연 없음, 최대 1,000,000). 문서 원문에 따르면:

> "Setting `binlog_group_commit_sync_delay` to a microsecond delay enables more transactions to be synchronized together to disk at once, reducing the overall time to commit a group of transactions because the larger groups require fewer time units per group."

즉 커밋을 시도한 스레드가 즉시 fsync로 가지 않고, 지정된 마이크로초만큼 대기하면서 그 사이 도착하는 다른 트랜잭션들을 같은 그룹에 편입시킨 다음 fsync를 한 번 수행한다. 개별 트랜잭션 입장에서는 지연(latency)이 늘지만, 서버 전체 처리량(throughput)은 fsync 총 횟수가 줄어드는 만큼 늘어날 수 있다 — 전형적인 latency-throughput 트레이드오프를 명시적 노브로 노출한 것이다.

여기에 안전밸브가 붙는다. `binlog_group_commit_sync_no_delay_count`는 "지연을 끝까지 기다리지 않고 몇 개가 모이면 즉시 중단할지"를 정한다. 이미 충분히 큰 그룹이 모였는데도 나머지 지연 시간을 다 기다리는 건 손해이므로, 이 카운트에 도달하면 지연을 조기 종료하고 바로 fsync로 진행한다(`binlog_group_commit_sync_delay=0`이면 이 변수는 아무 효과가 없다 — 지연 자체가 없으니 "조기 종료"할 대상이 없다).

```
시간 →
  T1 커밋 요청 ──┐
  T2 커밋 요청 ───┼─ [배치 윈도우: 최대 sync_delay μs, 또는 no_delay_count개 도달 시 조기종료] ─ fsync 1회 ─ T1,T2,T3 동시 durable
  T3 커밋 요청 ──┘
  T4 커밋 요청 ────────────────────(다음 그룹, 별도 fsync)───────────────────
```

### 3. `sync_binlog`과의 합성

지연 윈도우가 언제 적용되는지는 `sync_binlog` 설정에 따라 갈린다. 문서 원문:

> "When `sync_binlog=0` or `sync_binlog=1` is set, the delay ... is applied for every binary log commit group before synchronization ... When `sync_binlog` is set to a value n greater than 1, the delay is applied after every n binary log commit groups."

즉 `sync_binlog=1`(그룹마다 매번 fsync)에서는 매 그룹 앞에 지연 윈도우가 걸리고, `sync_binlog=N>1`(N개 그룹마다 한 번 fsync — 이건 durability를 낮추는 설정이다, 크래시 시 최대 N그룹 분량 손실 가능)에서는 N그룹째마다 한 번 지연이 걸린다. 두 노브는 서로 직교하는 축이다: `sync_binlog`는 "몇 그룹마다 fsync할지"(durability 레벨), `binlog_group_commit_sync_delay`는 "그룹을 얼마나 크게 불릴지"(그룹당 처리량)를 조절한다.

### 4. 커밋 순서 보장: `binlog_order_commits`

group commit은 "여러 트랜잭션의 binlog write를 한 fsync로 묶는다"는 이야기였다. 그런데 binlog에 순서대로 적힌 트랜잭션들이 InnoDB 같은 스토리지 엔진에도 *같은 순서로* 커밋되는지는 별개의 질문이다 — 두 로그(binlog, InnoDB redo log)의 커밋 순서가 어긋나면 복제본을 binlog로 재생했을 때 소스와 다른 최종 상태에 도달할 위험이 생긴다.

`binlog_order_commits`(기본값 ON)는 이를 막는다. 문서 원문:

> "transaction commit instructions issued to storage engines are serialized on a single thread, so that transactions are always committed in the same order as they are written to the binary log."

즉 기본값에서는 스토리지 엔진에 대한 커밋 지시가 단일 스레드로 직렬화되어, binlog에 적힌 순서 == 스토리지 엔진 커밋 순서가 항상 유지된다. 이를 끄면(`OFF`) 여러 스레드가 병렬로 스토리지 엔진 커밋을 발행할 수 있어 커밋 그룹 내부의 상대 순서가 binlog 기록 순서와 달라질 수 있다 — 다만 문서는 "단일 클라이언트에서 나온 트랜잭션들은 항상 시간순으로 커밋된다"는 것과, "복제본에서 소스와 동일한 트랜잭션 히스토리를 보존하려면 `slave_preserve_commit_order=1`을 설정하라"는 복구 경로를 함께 제시한다.

### 5. 그림으로 정리하면

```
[클라이언트 커밋 요청들]
        │
        ▼
  binlog 캐시에 이벤트 기록 (트랜잭션별)
        │
        ▼
  ┌─ 배치 윈도우 (binlog_group_commit_sync_delay, no_delay_count로 조기종료) ─┐
  │             같은 시간대 도착 트랜잭션들을 그룹으로 편입                    │
  └────────────────────────────┬───────────────────────────────────────────┘
                                ▼
                    binlog fsync 1회 (sync_binlog 정책에 따라 매그룹/N그룹마다)
                                ▼
        스토리지 엔진 커밋 지시 — binlog_order_commits=ON이면 단일 스레드 직렬화
                                ▼
                    각 트랜잭션에 커밋 확인 응답
```

## 검증

로컬 MySQL 8.0 인스턴스에서 다음으로 현재 설정값을 확인할 수 있다:

```sql
SHOW VARIABLES LIKE 'binlog_group_commit_sync_delay';
SHOW VARIABLES LIKE 'binlog_group_commit_sync_no_delay_count';
SHOW VARIABLES LIKE 'sync_binlog';
SHOW VARIABLES LIKE 'binlog_order_commits';
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
```

fsync 횟수가 실제로 줄어드는지는 syscall 레벨에서 직접 관찰할 수 있다:

```bash
# mysqld PID 확인 후, 부하 생성 동안 fsync 호출 횟수를 집계
strace -f -c -e trace=fsync,fdatasync -p "$(pgrep -x mysqld)" &
STRACE_PID=$!
# 다른 터미널에서 짧은 동시 트랜잭션을 다수 발생시킨다 (sysbench oltp_insert 등)
sleep 20
kill -INT "$STRACE_PID"
```

`binlog_group_commit_sync_delay=0`(기본)과 예를 들어 `1000`(1ms)으로 바꿔 동일 부하를 재현했을 때, 커밋 처리된 트랜잭션 수 대비 `fsync` 호출 횟수 비율이 후자에서 더 낮게 나오는지 비교하면 그룹 크기가 커졌다는 것을 직접 확인할 수 있다.

## 잘못 알고 있던 것

- **"fsync를 자주 할수록 안전하고, 그룹으로 묶으면 안전성이 떨어진다"** — 그룹 커밋은 fsync *횟수*를 줄이는 것이지, 커밋 확인을 보낸 트랜잭션의 durability를 낮추는 게 아니다. 클라이언트는 자신이 속한 그룹의 fsync가 끝난 *후에만* 커밋 확인을 받으므로, 그 시점 이후 크래시에도 데이터는 살아남는다. 위험이 생기는 지점은 그룹 커밋이 아니라 `sync_binlog=0`이나 `N>1`처럼 fsync 자체를 스킵/지연하는 별개의 설정이다.
- **"`sync_binlog=1`이면 그룹 커밋이 의미 없다"** — `sync_binlog=1`은 "그룹마다 fsync한다"는 뜻이지 "트랜잭션마다 fsync한다"는 뜻이 아니다. 여러 트랜잭션이 같은 그룹에 묶이면 `sync_binlog=1`에서도 그 그룹 전체에 fsync 1회만 발생한다. 그룹의 크기를 늘리는 건 동시성과 `binlog_group_commit_sync_delay`의 역할이다.
- **"`binlog_order_commits`를 끄면 복제가 곧바로 깨진다"** — 문서는 단일 클라이언트의 트랜잭션은 여전히 시간순으로 커밋된다고 명시한다. 문제가 되는 건 서로 무관한 트랜잭션들 간의 상대 순서이며, 트랜잭션들이 서로 일관된 결과를 내도록 설계돼 있다면 대부분 영향이 없다. 순서 보존이 꼭 필요하면 끄는 대신 복제본에 `slave_preserve_commit_order=1`을 설정하는 경로가 문서에 별도로 제시돼 있다.

## 더 파고들 만한 것

- InnoDB redo log의 prepare와 binlog write 사이의 XA 스타일 2단계 커밋 — 크래시 후 재시작 시 InnoDB의 "prepared" 트랜잭션과 binlog에 실제로 적힌 트랜잭션을 어떻게 대조해 commit/rollback을 결정하는지 (이번 노트에서는 정확한 절 번호를 확인하지 못해 다루지 않았다).
- 반동기 복제(semi-sync replication)의 `AFTER_SYNC` vs `AFTER_COMMIT` 대기 지점이 이 group commit 파이프라인의 어느 단계에 끼어드는지.

## 참고

- MySQL 8.0 Reference Manual §19.1.6.4 "Binary Logging Options and Variables"
- MySQL 8.0 Reference Manual — `innodb_flush_log_at_trx_commit` 시스템 변수 문서 (Chapter 17, InnoDB)
