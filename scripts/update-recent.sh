#!/usr/bin/env bash
# README.md의 "## Recent" 섹션을 최신 노트 5개로 갱신한다.
# 사용법: ./scripts/update-recent.sh && git add README.md && git commit -m "docs: Recent 갱신"
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP_SECTION=$(mktemp)
{
  echo "## Recent"
  echo
  echo "<!-- 자동 생성: ./scripts/update-recent.sh -->"
  git log --diff-filter=A --name-only --format='%as' -- '*.md' \
    | awk 'NF==1 && /^[0-9]/{d=$0} /\.md$/ && !/README/ && !/NOTE_TEMPLATE/ && /\// {print d, $0}' \
    | sort -r | head -5 \
    | while read -r date path; do
        title=$(grep -m1 '^# ' "$path" | sed 's/^# //' || true)
        [ -z "$title" ] && title="$path"
        echo "- ${date} — [${title}](./${path})"
      done
  echo
} > "$TMP_SECTION"

awk -v section="$TMP_SECTION" '
  /^## Recent$/ {skip=1; while ((getline line < section) > 0) print line; next}
  /^## / && skip {skip=0}
  !skip {print}
' README.md > README.md.tmp && mv README.md.tmp README.md
rm -f "$TMP_SECTION"
echo "Recent 섹션 갱신 완료"
