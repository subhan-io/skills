#!/usr/bin/env bash
# Run one ship-issue role through Claude or Codex and emit one small JSON run record.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=engine-policy.sh
source "$SCRIPT_DIR/engine-policy.sh"

die() { echo "ERROR: $*" >&2; exit 64; }

ROLE=""; INDEX=""; PROMPT_FILE=""; SCHEMA=""; CWD=""; STATE_DIR=""; OUT=""
ENGINE_OVERRIDE="${SHIP_ISSUE_ENGINE:-}"; MODEL_OVERRIDE="${SHIP_ISSUE_MODEL:-}"
TIMEOUT_SECONDS="${SHIP_ISSUE_AGENT_TIMEOUT_SECONDS:-3600}"

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --index) INDEX="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    --cwd) CWD="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --engine) ENGINE_OVERRIDE="${2:-}"; shift 2 ;;
    --model) MODEL_OVERRIDE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$ROLE" ] || die "--role is required"
[ -f "$PROMPT_FILE" ] || die "--prompt-file must name a readable file"
[ -f "$SCHEMA" ] || die "--schema must name a readable file"
[ -d "$CWD" ] || die "--cwd must name a directory"
[ -d "$STATE_DIR" ] || die "--state-dir must name a directory"
[ -n "$OUT" ] || die "--out is required"
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) die "--timeout must be a positive integer" ;; esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || die "--timeout must be a positive integer"
if [ "$ROLE" = implementer ]; then
  case "$INDEX" in ''|*[!0-9]*) die "--index is required for implementer roles" ;; esac
fi

CWD="$(realpath "$CWD")"
STATE_DIR="$(realpath "$STATE_DIR")"
PROMPT_FILE="$(realpath "$PROMPT_FILE")"
SCHEMA="$(realpath "$SCHEMA")"
OUT="$(realpath -m "$OUT")"
case "$OUT" in "$STATE_DIR"/*) ;; *) die "--out must live inside --state-dir" ;; esac
mkdir -p "$(dirname "$OUT")"

REQUESTED_ENGINE="${ENGINE_OVERRIDE:-$(engine_for_role "$ROLE" "$INDEX")}" \
  || die "unknown role or invalid role/index: $ROLE ${INDEX:-}"
case "$REQUESTED_ENGINE" in claude|codex) ;; *) die "engine must be claude or codex" ;; esac
ENGINE="$REQUESTED_ENGINE"
MODEL="${MODEL_OVERRIDE:-$(model_for_role "$ENGINE" "$ROLE")}" \
  || die "no model policy for $ENGINE/$ROLE"

base="${OUT%.json}"
LOG="$base.log"
RAW="$base.raw"
MANIFEST="$base.instruction-links"
EXCLUDES="$base.git-excludes"
LEDGER="$STATE_DIR/engine-ledger.json"
ENTRY="$base.ledger-entry.json"
rm -f "$OUT" "$RAW" "$LOG" "$ENTRY"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
FAILOVER_FROM=""
FAILOVER_REASON=""
REPORT_VALID=false
TOKENS=0
SESSION_ID=""

cleanup_instruction_links() {
  "$SCRIPT_DIR/sync-agent-instructions.sh" --manifest "$MANIFEST" --cleanup >/dev/null 2>&1 || true
  rm -f "$MANIFEST" "$EXCLUDES"
}
trap cleanup_instruction_links EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$SCRIPT_DIR/sync-agent-instructions.sh" --root "$CWD" --manifest "$MANIFEST"
: > "$EXCLUDES"
while IFS=$'\t' read -r link _target; do
  [ -n "$link" ] || continue
  relative="${link#"$CWD"/}"
  printf '/%s\n' "$relative" >> "$EXCLUDES"
done < "$MANIFEST"

# Keep temporary compatibility symlinks out of `git status` and `git add -A` in the child. These
# environment-only config entries disappear with the subprocess and never alter the target repo.
git_config_index="${GIT_CONFIG_COUNT:-0}"
case "$git_config_index" in ''|*[!0-9]*) die "GIT_CONFIG_COUNT must be an integer" ;; esac
printf -v "GIT_CONFIG_KEY_$git_config_index" '%s' core.excludesFile
printf -v "GIT_CONFIG_VALUE_$git_config_index" '%s' "$EXCLUDES"
export "GIT_CONFIG_KEY_$git_config_index" "GIT_CONFIG_VALUE_$git_config_index"
export GIT_CONFIG_COUNT=$((git_config_index + 1))

PROMPT="$(cat "$PROMPT_FILE")"
SCHEMA_JSON="$(jq -c . "$SCHEMA")" || die "schema is not valid JSON: $SCHEMA"

run_codex() {
  local sandbox=read-only net=false
  local -a command
  if role_is_writer "$ROLE"; then sandbox=workspace-write; net=true; fi
  command=("${RUN_AGENT_CODEX_BIN:-codex}" exec --sandbox "$sandbox" -C "$CWD"
    --add-dir "$STATE_DIR" -c "sandbox_workspace_write.network_access=$net"
    --output-schema "$SCHEMA" -o "$OUT" --json)
  [ -z "$MODEL" ] || command+=(--model "$MODEL")
  command+=("$PROMPT")
  timeout --foreground --signal=TERM --kill-after=15 "$TIMEOUT_SECONDS" \
    "${command[@]}" > "$RAW" 2> "$LOG"
}

run_claude() {
  local permission=plan
  local -a command
  role_is_writer "$ROLE" && permission=acceptEdits
  command=("${RUN_AGENT_CLAUDE_BIN:-claude}" -p --model "$MODEL" --output-format json
    --json-schema "$SCHEMA_JSON" --permission-mode "$permission" --add-dir "$STATE_DIR" "$PROMPT")
  (cd "$CWD" && timeout --foreground --signal=TERM --kill-after=15 "$TIMEOUT_SECONDS" \
    "${command[@]}" > "$RAW" 2> "$LOG")
  local result=$?
  if [ "$result" -eq 0 ]; then
    jq -e '
      if (.structured_output? | type) == "object" then .structured_output
      elif (.result? | type) == "object" then .result
      elif (.result? | type) == "string" then (.result | fromjson)
      else error("Claude JSON output has no structured result") end
    ' "$RAW" > "$OUT" 2>> "$LOG" || return 65
  fi
  return "$result"
}

run_selected_engine() {
  if [ "$ENGINE" = codex ]; then run_codex; else run_claude; fi
}

run_selected_engine
EXIT_CODE=$?

if [ "$ENGINE" = claude ] && [ "$EXIT_CODE" -ne 0 ] \
   && role_allows_rate_limit_failover "$ROLE" \
   && grep -Eiq 'rate.?limit|usage.?limit|hit your.*limit|too many requests|(^|[^0-9])429([^0-9]|$)' "$LOG" "$RAW" 2>/dev/null; then
  FAILOVER_FROM=claude
  FAILOVER_REASON=rate-limit
  mv "$LOG" "$base.claude-attempt.log"
  mv "$RAW" "$base.claude-attempt.raw"
  rm -f "$OUT"
  ENGINE=codex
  MODEL="$(model_for_role codex "$ROLE")" \
    || die "no Codex model policy for $ROLE"
  run_selected_engine
  EXIT_CODE=$?
fi

STATUS=failed
if [ "$EXIT_CODE" -eq 124 ]; then
  STATUS=timed-out
elif [ "$EXIT_CODE" -eq 0 ]; then
  if "$SCRIPT_DIR/validate-agent-report.py" "$SCHEMA" "$OUT" >> "$LOG" 2>&1; then
    REPORT_VALID=true
    STATUS="$(jq -r '.status // "green"' "$OUT")"
  else
    EXIT_CODE=65
    STATUS=invalid-report
  fi
elif [ "$EXIT_CODE" -eq 65 ]; then
  STATUS=invalid-report
fi

if [ "$ENGINE" = claude ] && [ -s "$RAW" ]; then
  TOKENS="$(jq -r '[.usage? // {} | .input_tokens?, .output_tokens?, .cache_creation_input_tokens?, .cache_read_input_tokens? | numbers] | add // 0' "$RAW" 2>/dev/null || echo 0)"
  SESSION_ID="$(jq -r '.session_id? // empty' "$RAW" 2>/dev/null || true)"
elif [ "$ENGINE" = codex ] && [ -s "$RAW" ]; then
  TOKENS="$(jq -rs '[.. | objects | .usage? | objects | .input_tokens?, .output_tokens? | numbers] | add // 0' "$RAW" 2>/dev/null || echo 0)"
  SESSION_ID="$(jq -rs '[.. | objects | .thread_id? | strings][0] // empty' "$RAW" 2>/dev/null || true)"
  if [ -z "$MODEL" ]; then
    MODEL="$(jq -rs '[.. | objects | .model? | strings][0] // empty' "$RAW" 2>/dev/null || true)"
  fi
fi
case "$TOKENS" in ''|*[!0-9]*) TOKENS=0 ;; esac

END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))
INDEX_JSON=null
[ -z "$INDEX" ] || INDEX_JSON="$INDEX"
MODEL_RECORD="${MODEL:-default}"
FAILOVER_JSON=null
[ -z "$FAILOVER_FROM" ] || FAILOVER_JSON="$(jq -n --arg from "$FAILOVER_FROM" --arg reason "$FAILOVER_REASON" '{from:$from,reason:$reason}')"

jq -cn --arg role "$ROLE" --argjson index "$INDEX_JSON" --arg requestedEngine "$REQUESTED_ENGINE" \
  --arg engine "$ENGINE" --arg model "$MODEL_RECORD" --arg status "$STATUS" \
  --argjson exitCode "$EXIT_CODE" --argjson durationSec "$DURATION" --argjson tokens "$TOKENS" \
  --arg startedAt "$STARTED_AT" --arg reportPath "$OUT" --argjson reportValid "$REPORT_VALID" \
  --arg logPath "$LOG" --arg sessionId "$SESSION_ID" --argjson failover "$FAILOVER_JSON" \
  '{role:$role,index:$index,requestedEngine:$requestedEngine,engine:$engine,model:$model,
    status:$status,exitCode:$exitCode,durationSec:$durationSec,tokens:$tokens,startedAt:$startedAt,
    reportPath:$reportPath,reportValid:$reportValid,logPath:$logPath,
    sessionId:(if $sessionId == "" then null else $sessionId end),failover:$failover,
    ledgerRecorded:true}' > "$ENTRY"

if ! "$SCRIPT_DIR/record-engine-run.py" "$LEDGER" "$ENTRY"; then
  jq -c '.status="ledger-error" | .exitCode=74 | .ledgerRecorded=false' "$ENTRY" > "$ENTRY.tmp"
  mv "$ENTRY.tmp" "$ENTRY"
  EXIT_CODE=74
fi
cat "$ENTRY"
exit "$EXIT_CODE"
