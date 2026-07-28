#!/usr/bin/env bash
# install.sh — symlink every skill in this repo into ~/.claude/skills.
#
#   ./install.sh              # link all skills
#   ./install.sh -n           # dry run: print what would change, touch nothing
#   ./install.sh -f           # replace real directories (not just stale symlinks)
#   ./install.sh dispatch-agents [...]   # link only the named skills
#
# Symlinks (not copies) so `git pull` in this repo updates every machine's skills at once.
# The alternative install path — `/plugin marketplace add subhan-io/skills` — does not use
# this script at all; see README.md.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
DRY=false; FORCE=false; WANTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=true ;;
    -f|--force) FORCE=true ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) WANTED+=("$1") ;;
  esac
  shift
done

# If ~/.claude/skills is itself a symlink into this repo, per-skill links would be written
# back into the working tree. Bail rather than pollute it.
if [ -L "$DEST" ]; then
  resolved="$(cd "$(dirname "$DEST")" && cd "$(readlink "$DEST")" 2>/dev/null && pwd || echo "")"
  case "$resolved" in
    "$REPO"|"$REPO"/*)
      echo "error: $DEST is a symlink into this repo ($resolved)." >&2
      echo "Remove it (rm \"$DEST\") and re-run; it will be recreated as a real directory." >&2
      exit 1 ;;
  esac
fi

$DRY || mkdir -p "$DEST"
linked=0; skipped=0

for skill_md in "$REPO"/skills/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  src="$(dirname "$skill_md")"
  name="$(basename "$src")"

  if [ ${#WANTED[@]} -gt 0 ]; then
    match=false
    for w in "${WANTED[@]}"; do [ "$w" = "$name" ] && match=true; done
    $match || continue
  fi

  target="$DEST/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    # A real directory here is someone's actual work — never clobber it silently.
    if ! $FORCE; then
      echo "skip $name — $target is a real directory (re-run with -f to replace it)" >&2
      skipped=$((skipped + 1)); continue
    fi
    $DRY || rm -rf "$target"
  fi

  if $DRY; then
    echo "would link $name -> $src"
  else
    ln -sfn "$src" "$target"
    echo "linked $name -> $src"
  fi
  linked=$((linked + 1))
done

if [ "$linked" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "no skills matched" >&2; exit 1
fi
echo "done: $linked linked, $skipped skipped"
if $DRY; then echo "(dry run — nothing was written)"; fi
exit 0
