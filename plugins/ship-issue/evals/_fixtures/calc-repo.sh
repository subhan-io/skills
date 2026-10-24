#!/usr/bin/env bash
# Scaffold for the light cases: a small CLI with one bug and one missing check.
# `avg` divides by a hard-coded 2, and an empty `avg` divides by zero.
set -euo pipefail

cat >calc.sh <<'SH'
#!/usr/bin/env bash
# calc.sh — integer arithmetic over its arguments.
set -euo pipefail
op="${1:-}"; shift || true
case "$op" in
  sum) total=0; for n in "$@"; do total=$((total + n)); done; echo "$total" ;;
  avg) total=0; for n in "$@"; do total=$((total + n)); done; echo $((total / 2)) ;;
  max) best="$1"; for n in "$@"; do [ "$n" -gt "$best" ] && best="$n"; done; echo "$best" ;;
  *) echo "usage: calc.sh sum|avg|max <n>..." >&2; exit 2 ;;
esac
SH

cat >test.sh <<'SH'
#!/usr/bin/env bash
# test.sh — runs every check, prints each result, and writes the summary to
# test-result.txt: `PASS <n>/<n>` only when every check passed.
pass=0; total=0
check() {  # check <name> <expected output> <command...>
  local name="$1" want="$2"; shift 2; total=$((total + 1))
  if [ "$("$@" 2>/dev/null)" = "$want" ]; then pass=$((pass + 1)); echo "ok   $name"; else echo "FAIL $name"; fi
}
check "sum" 6 ./calc.sh sum 1 2 3
check "max" 9 ./calc.sh max 4 9 2
if [ "$pass" -eq "$total" ]; then echo "PASS $pass/$total" >test-result.txt; else echo "FAIL $pass/$total" >test-result.txt; fi
[ "$pass" -eq "$total" ]
SH

chmod +x calc.sh test.sh
printf 'test-result.txt\n' >.gitignore
git init -q -b main
git add -A
git -c user.email=eval@example.com -c user.name=eval commit -q -m "calc: sum, avg, max"
