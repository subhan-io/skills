#!/usr/bin/env bash
set -euo pipefail

out=""; cwd=""; add_dir=""; sandbox=""; net=""
while [ $# -gt 0 ]; do
  case "$1" in
    exec|--json) shift ;;
    --sandbox) sandbox="${2:-}"; shift 2 ;;
    -C) cwd="${2:-}"; shift 2 ;;
    --add-dir) add_dir="${2:-}"; shift 2 ;;
    --output-schema|-o|--model) [ "$1" = -o ] && out="${2:-}"; shift 2 ;;
    -c)
      case "${2:-}" in sandbox_workspace_write.network_access=*) net="${2#*=}" ;; esac
      shift 2
      ;;
    *) shift ;;
  esac
done

[ -n "$out" ] && [ -n "$cwd" ] && [ -n "$add_dir" ] || exit 70
[ -L "$cwd/AGENTS.md" ] || [ -e "$cwd/AGENTS.md" ] || exit 71
printf '%s\n' "sandbox=$sandbox network=$net add_dir=$add_dir" > "${FAKE_ARGS_LOG:-$add_dir/fake-codex.args}"
printf '%s\n' ok > "$add_dir/codex-state-write-ok"

case "${FAKE_CODEX_MODE:-valid}" in
  valid)
    report="${FAKE_REPORT_JSON:-}"
    [ -n "$report" ] || report='{"status":"ok"}'
    printf '%s\n' "$report" > "$out"
    ;;
  invalid) printf '%s\n' '{"unexpected":true}' > "$out" ;;
  sleep) sleep 30 ;;
  *) exit 72 ;;
esac

printf '%s\n' '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000001","model":"test-codex"}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":11,"cached_input_tokens":2,"output_tokens":3}}'
