#!/usr/bin/env bash
set -euo pipefail

add_dir=""; model=""; permission=""; schema=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--output-format|--json-schema|--permission-mode|--model|--add-dir)
      key="$1"; value="${2:-}"
      [ "$key" = --add-dir ] && add_dir="$value"
      [ "$key" = --model ] && model="$value"
      [ "$key" = --permission-mode ] && permission="$value"
      [ "$key" = --json-schema ] && schema="$value"
      shift 2
      ;;
    *) shift ;;
  esac
done

[ -n "$add_dir" ] || exit 70
[ -L CLAUDE.md ] || [ -e CLAUDE.md ] || exit 71
prompt="$(cat)"
printf '%s\n' "permission=$permission schema=$schema prompt=$prompt" > "$add_dir/fake-claude.args"

case "${FAKE_CLAUDE_MODE:-valid}" in
  valid)
    report="${FAKE_REPORT_JSON:-}"
    [ -n "$report" ] || report='{"status":"ok"}'
    jq -cn --argjson report "$report" --arg model "$model" \
      '{structured_output:$report,model:$model,usage:{input_tokens:7,output_tokens:2,cache_creation_input_tokens:1,cache_read_input_tokens:4}}'
    ;;
  invalid)
    printf '%s\n' '{"structured_output":{"unexpected":true},"usage":{"input_tokens":1,"output_tokens":1}}'
    ;;
  rate-limit)
    echo 'You have hit your usage limit. Try again later.' >&2
    exit 1
    ;;
  sleep) sleep 30 ;;
  *) exit 72 ;;
esac
