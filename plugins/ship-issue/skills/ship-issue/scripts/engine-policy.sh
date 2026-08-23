#!/usr/bin/env bash
# shellcheck shell=bash
# Static engine policy for ship-issue. The orchestrator supplies facts (role and chunk index);
# this file makes the routing decision so a model never chooses its own billing pool.

engine_for_role() {
  local role="$1" index="${2:-}"
  case "$role" in
    repo-brief|fixer|rebaser) printf '%s\n' codex ;;
    planner|resolver) printf '%s\n' claude ;;
    implementer)
      case "$index" in ''|*[!0-9]*) return 64 ;; esac
      if (( index % 2 == 1 )); then printf '%s\n' codex; else printf '%s\n' claude; fi
      ;;
    *) return 64 ;;
  esac
}

model_for_role() {
  local engine="$1" role="$2"
  [ "$engine" = claude ] || return 0
  case "$role" in
    planner|resolver) printf '%s\n' opus ;;
    repo-brief|implementer|fixer|rebaser) printf '%s\n' sonnet ;;
    *) return 64 ;;
  esac
}

role_is_writer() {
  case "$1" in
    planner|implementer|fixer|rebaser|resolver) return 0 ;;
    repo-brief) return 1 ;;
    *) return 64 ;;
  esac
}

role_allows_rate_limit_failover() {
  case "$1" in
    implementer|fixer|rebaser) return 0 ;;
    repo-brief|planner|resolver) return 1 ;;
    *) return 64 ;;
  esac
}
