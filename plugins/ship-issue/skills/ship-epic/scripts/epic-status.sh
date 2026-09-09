#!/usr/bin/env bash
# epic-status.sh — rewrite the status block in an epic's body.
#
#   epic-status.sh --repo <path> --epic <n> --file <status.md> [--dry-run]
#
# The block sits between `<!-- ship-epic:status -->` and `<!-- /ship-epic:status -->`
# and is replaced whole on every tick, so the body carries one current table rather
# than a trail of stale ones. The first call appends the block to the end of the
# body. The rest of the body — goal, build order, contracts — is left byte for byte.
#
# --dry-run prints the new body on stdout and edits nothing.
#
# The edit goes through the REST API with a JSON document on stdin rather than
# `gh issue edit`, which fails outright on hosts that have retired Projects
# (classic) unless gh is recent, and rather than `-f body=@file`, which posts the
# literal path.
set -euo pipefail

repo="" epic="" file="" dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --epic) epic="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "epic-status.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] && [ -n "$epic" ] && [ -n "$file" ] || {
  echo "epic-status.sh: --repo, --epic and --file are all required" >&2; exit 2; }
case "$epic" in ''|*[!0-9]*) echo "epic-status.sh: --epic must be a number" >&2; exit 2 ;; esac
[ -f "$file" ] || { echo "epic-status.sh: no status file at $file" >&2; exit 2; }

slug=$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner)
body=$(gh api "repos/$slug/issues/$epic" --jq .body)

new_body=$(python3 - "$file" <<'EOF' "$body"
import sys
status = open(sys.argv[1]).read().rstrip("\n")
body = sys.argv[2]
start, end = "<!-- ship-epic:status -->", "<!-- /ship-epic:status -->"
block = f"{start}\n{status}\n{end}"
i, j = body.find(start), body.find(end)
if i >= 0 and j > i:
    body = body[:i] + block + body[j + len(end):]
else:
    body = body.rstrip("\n") + "\n\n" + block + "\n"
sys.stdout.write(body)
EOF
)

if [ "$dry" = 1 ]; then
  printf '%s\n' "$new_body"
  exit 0
fi

jq -n --arg body "$new_body" '{body: $body}' \
  | gh api "repos/$slug/issues/$epic" -X PATCH --input - --jq '.number' >/dev/null
echo "epic-status.sh: status block rewritten on #$epic" >&2
