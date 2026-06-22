# til — 기술 deep-dive 노트

주제별 기술 심화 노트(마크다운) 저장소. 자체 OpenClaw 에이전트(til-bot)가 매일 노트를 작성/커밋한다. **노트는 git push 대상, `_pipeline/`은 `.gitignore` 대상.**

## 구조 (2026-06-22 온디맨드 퍼널로 재편)
- `_pipeline/scripts/prompts/til-draft.md` — **온디맨드** 주제 선정(백로그 없음) → deep-dive 노트 작성 → 핸드오프 + 원장 append. TIL↔블로그 퍼널의 **리더**(매일 19:30). 전체 흐름은 머신 `~/CLAUDE.md`의 "TIL ↔ 블로그 퍼널" 섹션 참고.
- `README.md`(노트 품질 "Bar") · `NOTE_TEMPLATE.md`(노트 섹션 구조) — til-draft.md가 읽는 기준. 수정 금지 대상.
- `scripts/update-recent.sh` + `.github/workflows` — push 후 README "Recent"를 origin에 자동 커밋한다. 그래서 런타임에 origin이 보통 1커밋 앞서 plain `git push`가 거부됨(정상) → rebase 후 재푸시, **force-push 금지**.
- 폴더(taxonomy): `java` `jpa` `spring` `database` `messaging` `network` `observability` `system-design` `books` (+확장 `security` `kubernetes` `infra` `performance`). 목록은 til-draft.md에 인라인돼 있다.
- **공유 상태(퍼널)**: `~/var/state/blog-til-funnel/` — `published-topics.md`(중복 사전), `<날짜>.json`(핸드오프), `published-<날짜>.flag`(멱등), `requests.md`(우선 주제 슬롯).

## ⚠️ 계약 / 주의
- 출력 마커는 평문 한 줄(굵게·백틱 금지): `TIL_READY: {folder}/{slug}.md` 또는 `TIL_FAILED: <reason>`. (옛 `BACKLOG_EMPTY`/`REFILL_*` 마커는 폐기.)
- 노트는 `NOTE_TEMPLATE.md` 섹션 구조 + `README.md`의 Bar(4개 중 2개 이상) 충족, 5000자 권장·7000자 상한.
- **이 repo엔 `examples/` 디렉터리·코드 실행 환경이 없다** — 검증은 본문 인라인 스니펫 또는 1차 출처 추적으로 적고, 존재하지 않는 파일 경로를 참조하지 않는다.
- 파일 read 실패가 런 전체를 중단시키지 않도록: 존재 불확실 파일(`requests.md`, `published-topics.md`)은 `ls`로 확인 후 읽는다.
- til-draft.md가 끝나면 cron이 git push 후 **퍼널②(블로그 발행, jobid facf6b62)를 `openclaw cron run`으로 트리거**한다.

## 폐기 (2026-06-22)
백로그+보충 구조를 온디맨드로 대체하며 삭제됨: `_pipeline/topics-backlog.md`, `til-refill-backlog.{sh,md}`, `til-draft.sh`(레거시 단독 실행기), `com.seonwoojung.til-draft.plist`(macOS launchd). til-bot은 더 이상 백로그를 읽지 않는다.
