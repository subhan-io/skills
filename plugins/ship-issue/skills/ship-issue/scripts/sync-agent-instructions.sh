#!/usr/bin/env bash
# Create temporary colocated CLAUDE.md/AGENTS.md compatibility links for one agent call.
set -euo pipefail

ROOT=""; MANIFEST=""; CLEANUP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 64 ;;
  esac
done

[ -n "$MANIFEST" ] || { echo "ERROR: --manifest is required" >&2; exit 64; }

if $CLEANUP; then
  [ -f "$MANIFEST" ] || exit 0
  while IFS=$'\t' read -r link target; do
    [ -n "$link" ] || continue
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
      rm "$link"
    fi
  done < "$MANIFEST"
  exit 0
fi

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "ERROR: --root must be a directory" >&2
  exit 64
fi
: > "$MANIFEST"

declare -A dirs=()
while IFS= read -r -d '' instruction; do
  dirs["$(dirname "$instruction")"]=1
done < <(find "$ROOT" \
  \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.next' -o -path '*/dist' \
     -o -path '*/build' -o -path '*/.claude/worktrees' \) -prune -o \
  \( -name CLAUDE.md -o -name AGENTS.md \) -print0)

for dir in "${!dirs[@]}"; do
  claude="$dir/CLAUDE.md"; agents="$dir/AGENTS.md"
  claude_exists=false; agents_exists=false
  [ -e "$claude" ] || [ -L "$claude" ] && claude_exists=true
  [ -e "$agents" ] || [ -L "$agents" ] && agents_exists=true

  if $claude_exists && $agents_exists; then
    continue
  elif $claude_exists; then
    [ -e "$claude" ] || { echo "ERROR: dangling instruction link: $claude" >&2; exit 65; }
    (cd "$dir" && ln -s CLAUDE.md AGENTS.md)
    printf '%s\t%s\n' "$agents" CLAUDE.md >> "$MANIFEST"
  elif $agents_exists; then
    [ -e "$agents" ] || { echo "ERROR: dangling instruction link: $agents" >&2; exit 65; }
    (cd "$dir" && ln -s AGENTS.md CLAUDE.md)
    printf '%s\t%s\n' "$claude" AGENTS.md >> "$MANIFEST"
  fi
done
