#!/usr/bin/env bash
# Scaffold for the deep cases: a notes CLI whose storage format has to change
# under existing user data, which is a data migration (a deep-tier signal).
set -euo pipefail

cat >notes.sh <<'SH'
#!/usr/bin/env bash
# notes.sh — a note per line in $NOTES_FILE (default ./notes.txt).
set -euo pipefail
file="${NOTES_FILE:-./notes.txt}"
case "${1:-}" in
  add) shift; printf '%s\n' "$*" >>"$file" ;;
  list) [ -f "$file" ] && nl -w1 -s': ' "$file" || true ;;
  *) echo "usage: notes.sh add <text> | list" >&2; exit 2 ;;
esac
SH

cat >test.sh <<'SH'
#!/usr/bin/env bash
# test.sh — runs every check against a fresh notes file, prints each result, and
# writes the summary to test-result.txt: `PASS <n>/<n>` only when every check passed.
pass=0; total=0
check() {  # check <name> <expected output> <command...>
  local name="$1" want="$2"; shift 2; total=$((total + 1))
  if [ "$("$@" 2>/dev/null)" = "$want" ]; then pass=$((pass + 1)); echo "ok   $name"; else echo "FAIL $name"; fi
}
export NOTES_FILE; NOTES_FILE="$(mktemp)"; rm "$NOTES_FILE"
./notes.sh add buy milk
check "add then list" "1: buy milk" ./notes.sh list
rm -f "$NOTES_FILE"
if [ "$pass" -eq "$total" ]; then echo "PASS $pass/$total" >test-result.txt; else echo "FAIL $pass/$total" >test-result.txt; fi
[ "$pass" -eq "$total" ]
SH

chmod +x notes.sh test.sh
printf 'test-result.txt\nnotes.txt\n' >.gitignore
git init -q -b main
git add -A
git -c user.email=eval@example.com -c user.name=eval commit -q -m "notes: add and list"
