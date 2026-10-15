#!/usr/bin/env bash
# ci-wait.sh — block until a PR's head commit has settled CI, then print one line.
#
#   ci-wait.sh --repo <owner/name> --pr <n> [--timeout <minutes, default 45>]
#
# Green means the head commit has at least one check and none is pending, failed
# or cancelled (skipped checks are fine). An empty check list right after a push
# means CI has not started yet, so it keeps waiting rather than calling it green.
#
# Prints exactly one line and exits:
#   0  green <sha>
#   1  red <sha> failing=<check>,<check> [log=<file>]
#
# On red, the failed steps' logs of every failing GitHub Actions job go to <file>
# (the last 200 lines of each), so reading why CI failed is one Read, not a
# round of `gh run view` greps.
#   2  timeout <sha> <pending|no-checks>
set -euo pipefail

repo="" pr="" timeout=45
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    *) echo "ci-wait.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] && [ -n "$pr" ] || { echo "ci-wait.sh: --repo and --pr are required" >&2; exit 2; }

deadline=$(( $(date +%s) + timeout * 60 ))
while :; do
  sha="$(gh pr view "$pr" -R "$repo" --json headRefOid -q .headRefOid)"
  # `gh pr checks` exits non-zero when checks fail or are pending; the JSON is what counts.
  checks="$(gh pr checks "$pr" -R "$repo" --json name,bucket,link 2>/dev/null || true)"
  [ -n "$checks" ] || checks='[]'
  total="$(jq 'length' <<<"$checks")"
  pending="$(jq '[.[] | select(.bucket == "pending")] | length' <<<"$checks")"
  failing="$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(",")' <<<"$checks")"
  if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ]; then
    if [ -z "$failing" ]; then echo "green $sha"; exit 0; fi
    log="${TMPDIR:-/tmp}/ci-wait-$pr-${sha:0:8}.log"; : >"$log"
    jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | [.name, .link] | @tsv' <<<"$checks" \
      | while IFS=$'\t' read -r name link; do
          [[ "$link" =~ /actions/runs/([0-9]+)/job/([0-9]+) ]] || continue
          { echo "=== $name"; gh run view "${BASH_REMATCH[1]}" -R "$repo" --job "${BASH_REMATCH[2]}" --log-failed 2>&1 \
              | sed -E $'s/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+ //' | tail -n 200; } >>"$log"
        done
    if [ -s "$log" ]; then echo "red $sha failing=$failing log=$log"; else rm -f "$log"; echo "red $sha failing=$failing"; fi
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    [ "$total" -eq 0 ] && echo "timeout $sha no-checks" || echo "timeout $sha pending"
    exit 2
  fi
  sleep 30
done
