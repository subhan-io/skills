#!/usr/bin/env bash
# review.sh — run one ship-issue review round and log it to the ledger.
#
#   review.sh --run <id> --issue <n> --round <n> --base <ref> --focus "<text>"
#
# Run from the repo, on the committed branch: both reviewers review the diff of
# HEAD against <ref> (e.g. origin/main, origin/epic/769).
#
# The reviewer is Codex (`/codex:adversarial-review`, through the companion script
# that command runs). When Codex answers with its usage limit, the round falls back
# to Claude Code's `/code-review`, run headless, so a spent Codex quota no longer
# stops a run. Any other Codex failure is a failed round, not a fallback.
#
# Prints the review on stdout, headed with the reviewer that produced it. Logs
# phase=review-requested before the round and phase=review-settled (with
# reviewer=codex|claude, and the Claude review's token usage) only when a review
# actually returned.
#
# Exit codes: 0 review returned; 1 the review failed (nothing settled; stop and
# report); 2 bad arguments or Codex not installed.
#
# Overrides for tests: SHIP_ISSUE_CODEX_COMPANION (companion script path),
# SHIP_ISSUE_CLAUDE_BIN (claude binary), SHIP_ISSUE_REVIEW_MODEL (fallback model,
# default opus), SHIP_ISSUE_REVIEW_LEVEL (fallback /code-review level, default medium).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
run="" issue="" round="" base="" focus=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --round) round="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --focus) focus="$2"; shift 2 ;;
    *) echo "review.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
for v in run issue round base focus; do
  [ -n "${!v}" ] || { echo "review.sh: --$v is required" >&2; exit 2; }
done

companion="${SHIP_ISSUE_CODEX_COMPANION:-}"
if [ -z "$companion" ]; then
  plugin_dir="$(ls -d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/ 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$plugin_dir" ] && companion="${plugin_dir}scripts/codex-companion.mjs"
fi
if [ -z "$companion" ] || [ ! -f "$companion" ]; then
  echo "review.sh: Codex companion not found; install OpenAI's codex plugin and run /codex:setup" >&2
  exit 2
fi

"$here/ledger.sh" event=phase phase=review-requested round="$round" run="$run" issue="$issue"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
set +e
node "$companion" adversarial-review --wait --base "$base" "$focus" >"$out" 2>&1
status=$?
set -e

if grep -qi "usage limit" "$out"; then
  limit="$(grep -oi "you've hit your usage limit[^\[]*" "$out" | head -1 | sed 's/[[:space:]]*$//')"
  claude_bin="${SHIP_ISSUE_CLAUDE_BIN:-claude}"
  set +e
  json="$("$claude_bin" -p --model "${SHIP_ISSUE_REVIEW_MODEL:-opus}" --output-format json \
            --permission-mode bypassPermissions \
            "/code-review ${SHIP_ISSUE_REVIEW_LEVEL:-medium} $base" 2>/dev/null)"
  cstatus=$?
  set -e
  if [ "$cstatus" -ne 0 ] || ! jq -e '.is_error == false' >/dev/null 2>&1 <<<"$json"; then
    echo "review.sh: Codex hit its usage limit and the Claude /code-review fallback failed (exit $cstatus)" >&2
    printf '%s\n' "$json" | head -20 >&2
    exit 1
  fi
  usage="$(jq -c '.modelUsage // {} | with_entries(.value |= {cacheRead: .cacheReadInputTokens,
             cacheWrite: .cacheCreationInputTokens, out: .outputTokens})' <<<"$json")"
  echo "# Claude code review (fallback: Codex ${limit:-hit its usage limit})"
  echo
  echo "Findings carry no severity tag: grade each one before applying the round's bar."
  echo
  jq -r '.result' <<<"$json"
  "$here/ledger.sh" event=phase phase=review-settled round="$round" run="$run" issue="$issue" \
    reviewer=claude reviewUsage="$usage"
  exit 0
fi

if [ "$status" -ne 0 ] || grep -qE "Turn failed|did not return valid structured JSON" "$out"; then
  echo "review.sh: Codex review failed (exit $status):" >&2
  tail -20 "$out" >&2
  exit 1
fi

echo "# Codex adversarial review"
echo
cat "$out"
"$here/ledger.sh" event=phase phase=review-settled round="$round" run="$run" issue="$issue" reviewer=codex
