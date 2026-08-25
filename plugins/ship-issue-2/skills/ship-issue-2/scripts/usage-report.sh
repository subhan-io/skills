#!/usr/bin/env bash
# usage-report.sh — what each ship-issue run cost, joined from the ledger and the
# session logs both harnesses leave on disk.
#
#   usage-report.sh [--since 2026-08-18] [--json]
#
# Per run (a run-start event, closed by the next run-end for the same issue):
#   - Codex: every ledger codex event in the window — sessions, total and uncached
#     tokens (uncached = input - cached + output; the rollout's own numbers).
#   - Claude: assistant-message usage summed from ~/.claude/projects/<flattened cwd>
#     within the run's time window, deduplicated by message id. Raw tokens, split
#     cache-read / cache-write / output — cache reads dominate and are what
#     subscription limits mostly meter.
# A run with no run-end is reported as open, window capped at now.
set -euo pipefail

LEDGER="${SHIP_ISSUE_LEDGER:-$HOME/.local/state/ship-issue/ledger.jsonl}"
SINCE="$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
AS_JSON=false
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="$2T00:00:00Z"; shift 2 ;;
    --json) AS_JSON=true; shift ;;
    *) echo "usage-report.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -f "$LEDGER" ] || { echo "no ledger at $LEDGER" >&2; exit 1; }
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

runs="$(jq -s --arg since "$SINCE" --arg now "$NOW" '
  map(select(.ts >= $since)) as $ev
  | [$ev[] | select(.event == "run-start")]
  | map(. as $s
      | ([$ev[] | select(.event == "run-end" and (.issue|tostring) == ($s.issue|tostring) and .ts >= $s.ts)] | first) as $e
      | {issue: ($s.issue|tostring), tier: ($s.tier // "?"), cwd: ($s.cwd // ""),
         start: $s.ts, end: ($e.ts // $now), open: ($e == null),
         outcome: ($e.outcome // "open"), pr: ($e.pr // null),
         codex: ([$ev[] | select(.event == "codex" and (.issue|tostring) == ($s.issue|tostring)
                                 and .ts >= $s.ts and .ts <= ($e.ts // $now))]
                 | {sessions: length,
                    roles: (map(.role) | group_by(.) | map({(.[0]): length}) | add // {}),
                    total: (map((.tokens | if type == "string" then (try fromjson catch null) else . end)
                                | .total_tokens // 0) | add // 0),
                    uncached: (map((.tokens | if type == "string" then (try fromjson catch null) else . end)
                                   | if . == null then 0
                                     else ((.input_tokens // 0) - (.cached_input_tokens // 0) + (.output_tokens // 0)) end)
                               | add // 0)})})
' "$LEDGER")"

report="[]"
n="$(jq 'length' <<<"$runs")"
for i in $(seq 0 $((n - 1))); do
  run="$(jq -c ".[$i]" <<<"$runs")"
  cwd="$(jq -r '.cwd' <<<"$run")"
  start="$(jq -r '.start' <<<"$run")"
  end="$(jq -r '.end' <<<"$run")"
  claude='{"msgs":0,"cache_read":0,"cache_write":0,"out":0}'
  if [ -n "$cwd" ]; then
    proj_dir="$HOME/.claude/projects/$(echo "$cwd" | sed 's|[/.]|-|g')"
    if [ -d "$proj_dir" ]; then
      claude="$(find "$proj_dir" -name '*.jsonl' -newermt "${start%Z}" 2>/dev/null \
        | xargs -r cat 2>/dev/null \
        | jq -c --arg s "$start" --arg e "$end" \
            'select(.type == "assistant" and .message.usage and .timestamp >= $s and .timestamp <= $e)
             | {id: (.message.id // "x"), u: .message.usage}' 2>/dev/null \
        | jq -s '(group_by(.id) | map(.[-1])) as $m
                 | {msgs: ($m|length),
                    cache_read: ($m | map(.u.cache_read_input_tokens // 0) | add // 0),
                    cache_write: ($m | map(.u.cache_creation_input_tokens // 0) | add // 0),
                    out: ($m | map(.u.output_tokens // 0) | add // 0)}')"
      [ -n "$claude" ] || claude='{"msgs":0,"cache_read":0,"cache_write":0,"out":0}'
    fi
  fi
  report="$(jq -c --argjson r "$run" --argjson c "$claude" '. + [$r + {claude: $c}]' <<<"$report")"
done

if $AS_JSON; then
  jq . <<<"$report"
  exit 0
fi

echo "ship-issue runs since $SINCE"
jq -r '
  def m: tostring | if (.|length) > 6 then (.[0:-6] + "." + .[-6:-5] + "M") else . end;
  (["issue","tier","start","outcome","cdx-sess","cdx-total","cdx-uncached","cl-cread","cl-cwrite","cl-out"] | @tsv),
  (.[] | [.issue, .tier, (.start[0:16]), .outcome,
          .codex.sessions, (.codex.total|m), (.codex.uncached|m),
          (.claude.cache_read|m), (.claude.cache_write|m), (.claude.out|m)] | @tsv)
' <<<"$report" | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else awk -F'\t' '{for (i=1;i<=NF;i++) printf "%-18s", $i; print ""}'; fi
