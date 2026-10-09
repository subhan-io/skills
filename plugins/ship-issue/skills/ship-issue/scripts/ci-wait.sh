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
#   1  red <sha> failing=<check>,<check>
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
  checks="$(gh pr checks "$pr" -R "$repo" --json name,bucket 2>/dev/null || true)"
  [ -n "$checks" ] || checks='[]'
  total="$(jq 'length' <<<"$checks")"
  pending="$(jq '[.[] | select(.bucket == "pending")] | length' <<<"$checks")"
  failing="$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(",")' <<<"$checks")"
  if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ]; then
    if [ -z "$failing" ]; then echo "green $sha"; exit 0; fi
    echo "red $sha failing=$failing"; exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    [ "$total" -eq 0 ] && echo "timeout $sha no-checks" || echo "timeout $sha pending"
    exit 2
  fi
  sleep 30
done
