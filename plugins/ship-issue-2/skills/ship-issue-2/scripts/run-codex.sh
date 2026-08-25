#!/usr/bin/env bash
# run-codex.sh — run ONE Codex session for one unit of work, and record what it cost.
#
#   run-codex.sh --role chunk --issue 397 --index 2 \
#     --prompt-file /tmp/chunk-2.prompt.md --out /tmp/chunk-2.last.md [--cd DIR]
#   run-codex.sh --role fix --issue 397 --resume <sessionId> --prompt-file F --out F
#
# One invocation = one Codex session (fresh unless --resume). Subscription cost is
# turns × context, so fresh-and-small beats warm-and-long: resume only for the one
# immediate follow-up the SKILL allows.
#
# The session runs workspace-write with network on and reads CLAUDE.md as its project
# doc. The model's final message lands in --out; a usage event (session id, duration,
# token totals from the rollout file) is appended to the ledger via ledger.sh; one
# small JSON run record is printed for the orchestrator.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
role="" issue="" index="" prompt_file="" out="" cd_dir="$PWD" resume=""

while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --index) index="$2"; shift 2 ;;
    --prompt-file) prompt_file="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --cd) cd_dir="$2"; shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    *) echo "run-codex.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done

if [ -z "$role" ] || [ -z "$prompt_file" ] || [ -z "$out" ]; then
  echo "run-codex.sh: --role, --prompt-file and --out are required" >&2; exit 1
fi
[ -f "$prompt_file" ] || { echo "run-codex.sh: prompt file not found: $prompt_file" >&2; exit 1; }

start_epoch=$(date +%s)

codex_args=(--cd "$cd_dir" --sandbox workspace-write \
  -c 'sandbox_workspace_write.network_access=true' \
  -c 'project_doc_fallback_filenames=["CLAUDE.md"]' \
  --output-last-message "$out")

if [ -n "$resume" ]; then
  codex exec resume "$resume" "${codex_args[@]}" - < "$prompt_file"
else
  codex exec "${codex_args[@]}" - < "$prompt_file"
fi
exit_code=$?
duration=$(( $(date +%s) - start_epoch ))

# Attribute the session: newest rollout started at/after us whose cwd matches ours.
session_id="" tokens_json="null"
rollout="$(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -newermt "@$((start_epoch - 5))" 2>/dev/null \
  | xargs -r ls -t 2>/dev/null \
  | while IFS= read -r f; do
      meta_cwd="$(head -1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null)"
      if [ "$meta_cwd" = "$cd_dir" ]; then echo "$f"; break; fi
    done)"
if [ -n "$rollout" ]; then
  session_id="$(head -1 "$rollout" | jq -r '.payload.session_id // .payload.id // empty' 2>/dev/null)"
  tokens_json="$(grep -o '"total_token_usage":{[^}]*}' "$rollout" | tail -1 | sed 's/^"total_token_usage"://')"
  [ -n "$tokens_json" ] || tokens_json="null"
fi

"$SCRIPT_DIR/ledger.sh" event=codex "role=$role" "issue=$issue" "index=$index" \
  "cwd=$cd_dir" "sessionId=$session_id" "resumed=${resume:+true}" \
  "exitCode=$exit_code" "durationSec=$duration" "tokens=$tokens_json" || true

jq -n -c --arg role "$role" --arg issue "$issue" --arg index "$index" \
  --arg sessionId "$session_id" --arg out "$out" \
  --argjson exitCode "$exit_code" --argjson durationSec "$duration" \
  --argjson tokens "${tokens_json:-null}" \
  '{role:$role, issue:$issue, index:$index, sessionId:$sessionId,
    exitCode:$exitCode, durationSec:$durationSec, tokens:$tokens, out:$out}'

exit "$exit_code"
