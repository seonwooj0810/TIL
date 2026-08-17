# til — 기술 deep-dive 노트

주제별 기술 심화 노트(마크다운) 저장소. 자체 OpenClaw 에이전트(til-bot)가 주3회(월·수·금) 노트를 작성/커밋한다. **노트는 git push 대상, `_pipeline/`은 `.gitignore` 대상.**

## 구조 (2026-06-22 온디맨드 퍼널로 재편)
- `_pipeline/scripts/prompts/til-draft.md` — **온디맨드** 주제 선정(백로그 없음) → deep-dive 노트 작성 → 핸드오프 + 원장 append. TIL↔블로그 퍼널의 **리더**(2026-08-01부로 매일→주3회 월수금). cron 자체는 19:30 정각에 뜨고, PHASE 0에서 스크립트 내부 랜덤 sleep(0~30분)으로 실제 작업 시작을 19:30~20:00 사이로 분산한다(2h30m cron stagger 방식에서 in-script jitter로 변경됨). 전체 흐름은 머신 `~/CLAUDE.md`의 "TIL ↔ 블로그 퍼널" 섹션 참고.
- `README.md`(노트 품질 "Bar") · `NOTE_TEMPLATE.md`(노트 섹션 구조) — til-draft.md가 읽는 기준. 수정 금지 대상.
- `scripts/update-recent.sh` + `.github/workflows` — push 후 README "Recent"를 origin에 자동 커밋한다. 그래서 런타임에 origin이 보통 1커밋 앞서 plain `git push`가 거부됨(정상) → rebase 후 재푸시, **force-push 금지**.
- 폴더(taxonomy): `java` `jpa` `spring` `database` `messaging` `network` `observability` `system-design` `books` (+확장 `security` `kubernetes` `infra` `performance`). 목록은 til-draft.md에 인라인돼 있다.
- **공유 상태(퍼널)**: `~/var/state/blog-til-funnel/` — `published-topics.md`(중복 사전), `<날짜>.json`(핸드오프), `published-<날짜>.flag`(멱등), `requests.md`(우선 주제 슬롯).

## ⚠️ 계약 / 주의
- 출력 마커는 평문 한 줄(굵게·백틱 금지): `TIL_READY: {folder}/{slug}.md` 또는 `TIL_FAILED: <reason>`. (옛 `BACKLOG_EMPTY`/`REFILL_*` 마커는 폐기.)
- 노트는 `NOTE_TEMPLATE.md` 섹션 구조 + `README.md`의 Bar(4개 중 2개 이상) 충족, 5000자 권장·7000자 상한.
- **이 repo엔 `examples/` 디렉터리·코드 실행 환경이 없다** — 검증은 본문 인라인 스니펫 또는 1차 출처 추적으로 적고, 존재하지 않는 파일 경로를 참조하지 않는다.
- 파일 read 실패가 런 전체를 중단시키지 않도록: 존재 불확실 파일(`requests.md`, `published-topics.md`)은 `ls`로 확인 후 읽는다.
- til-draft.md 성공/실패 무관하게(성공 시 git push 후, 실패 시 바로) cron이 **퍼널②(블로그 발행, jobid facf6b62)를 `openclaw cron run`(force 모드)으로 트리거**한다. **2026-08-09부로 facf6b62 자체 스케줄은 disabled** — 이 트리거가 블로그 발행의 유일한 실행 경로다(disabled여도 force 모드 `cron run`은 정상 동작 — enabled 체크를 건너뜀).
- **thinking = 전역 기본값 상속(오버라이드 없음, 현재 high), 손대지 말 것**: 2026-08-09 xhigh→high 다운그레이드가 til-bot에선 토큰 -45.7%(턴수 86→55)로 확실한 이득이었음(반대로 blog-bot은 같은 변경이 +18% 역행해서 xhigh로 롤백함 — `blog-pipeline/CLAUDE.md` 참고). 이 봇에 한해 전역값을 그대로 따라가는 게 맞다.
- **과거 실패 이력(07-31, 4연속 error)은 세션재시작 버그가 아니라 "주간 사용량 한도 도달"(당시 opus-4-8 사용, 자동 재시도 4번 만에 다음날 리셋 후 성공)** — oss-bot의 detach+폴링 패턴(세션재시작이 detach 안 된 서브프로세스를 죽이는 문제 대응)과는 무관한 별개 원인. til-bot은 오케스트레이터가 직접 작업해서 애초에 detach할 서브프로세스가 없어 그 특정 버그에 노출된 적이 없다 — 의도적으로 다른 패턴 쓰는 게 아니라 구조상 해당 사항이 없는 것.
- **토큰 사용량 확인**: `~/.config/claude-bots/report-usage til [--days N]` — 이 봇은 서브프로세스가 없어 `usage.jsonl`에 전혀 안 잡히므로, 이 도구로 `~/.claude/projects/`를 직접 긁어야 실측치가 나온다.

## 폐기 (2026-06-22)
백로그+보충 구조를 온디맨드로 대체하며 삭제됨: `_pipeline/topics-backlog.md`, `til-refill-backlog.{sh,md}`, `til-draft.sh`(레거시 단독 실행기), `com.seonwoojung.til-draft.plist`(macOS launchd). til-bot은 더 이상 백로그를 읽지 않는다.
