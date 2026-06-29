# TIL — Deep Dives

**기술적으로 깊이 파고든 주제만 정리하는 공간.**
가벼운 팁이나 표면 사용법은 여기 두지 않는다. 폴리시된 글은 [velog](https://velog.io/@jungseonw00)에 따로 정리한다.

## Bar

이 repo에 들어오는 노트는 다음 중 **둘 이상**을 충족해야 한다.

- **1차 출처**(스펙·RFC·공식 docs·라이브러리 소스코드)를 직접 인용한다.
- **내부 동작**(알고리즘, 상태 전이, 메모리 구조 등)을 설명한다.
- **코드/출처로 검증**한다 (인라인 스니펫으로 동작을 보이거나, 1차 출처를 직접 따라가 확인).
- **잘못 알고 있던 것**을 바로잡는다.

## What does NOT belong here

- "X 사용법 정리" 류 (공식 docs 한 번만 읽으면 끝나는 표면 사용법)
- 단순 명령어 모음 / 셸 팁
- 깊이 없는 라이브러리 소개
- 강의 / 영상 시청 후기

→ 이런 건 velog 임시 글이나 사적 노트에.

## Navigation

| 폴더 | 다루는 깊이 |
| --- | --- |
| [java/](./java/) | JVM·JIT·GC 알고리즘, JLS 메모리 모델, 동시성 프리미티브 |
| [spring/](./spring/) | Bean lifecycle, AOP 프록시 내부, Transaction 전파 메커니즘 |
| [jpa/](./jpa/) | Persistence Context, dirty checking, fetch 전략 내부, 영속성 전이 |
| [database/](./database/) | 스토리지 엔진, B+Tree/LSM, MVCC, 트랜잭션 격리 구현 |
| [network/](./network/) | TCP 상태 머신, HTTP/2·3 multiplexing, TLS handshake 단계 |
| [system-design/](./system-design/) | 분산 패턴 (Outbox, Saga), CAP/PACELC, 합의 알고리즘 |
| [messaging/](./messaging/) | 브로커 내부, exactly-once 보장, 파티셔닝·리밸런싱 |
| [observability/](./observability/) | W3C Trace Context, OpenTelemetry SDK 내부, 메트릭 카디널리티 |
| [books/](./books/) | 책 챕터별 노트 (DDIA, Database Internals, Effective Java 등) |

## How I use this

- 새 노트는 [`NOTE_TEMPLATE.md`](./NOTE_TEMPLATE.md)를 그대로 복사해서 시작한다.
- 파일명: **주제 기반 kebab-case** (예: `persistence-context.md`). 날짜 X.
- 검증은 본문 인라인 스니펫 또는 1차 출처를 따라간 흐름으로 적는다 (별도 `examples/` 실행 환경은 두지 않는다).
- 정리가 충분히 두꺼워지면 [velog 글](https://velog.io/@jungseonw00)로 다듬어 발행하고, 노트 하단에 velog 링크를 남긴다.

## Conventions

- 단정 어투 금지. 출처가 있는 경우만 단정한다.
- 한 노트 = 한 주제. 두꺼워지면 쪼갠다.
- 다이어그램은 ASCII 또는 mermaid. 큰 그림이면 별도 SVG로 분리.
- 코드 스니펫은 60줄 이하, 핵심 라인에만 주석.

## Recent

<!-- 자동 생성: ./scripts/update-recent.sh -->
- 2026-06-29 — [Kubernetes CPU limit과 CFS throttling: cgroup quota·period가 컨테이너를 조이는 법](./kubernetes/cpu-limits-cfs-throttling.md)
- 2026-06-28 — [PostgreSQL WAL과 체크포인트: 충돌 복구를 보장하는 내부 동작](./database/postgresql-wal-and-checkpoint.md)
- 2026-06-27 — [False Sharing와 @Contended: 캐시 라인이 만드는 보이지 않는 경합](./performance/false-sharing-and-contended.md)
- 2026-06-25 — [Raft 합의 알고리즘: 리더 선출과 로그 복제 안전성](./system-design/raft-leader-election-and-log-replication.md)
- 2026-06-24 — [JVM 티어드 컴파일레이션: C1/C2 레벨 전이와 OSR·역최적화](./java/jvm-tiered-compilation-c1-c2-osr.md)

## Related

- 블로그: https://velog.io/@jungseonw00
