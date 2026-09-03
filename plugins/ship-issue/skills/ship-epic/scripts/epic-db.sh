#!/usr/bin/env bash
# epic-db.sh — provision the one database an epic's sub-issues share.
#
#   epic-db.sh --repo <path> --app <app-dir> --epic <n> [--recreate] [--push]
#              [--no-seed] [--seed-script <name>] [--secrets] [-x <extension>]
#
# One database per (app, epic), reused by every sub-issue of that epic. Sub-issue
# B's migration therefore applies on top of sub-issue A's, so an ordering conflict
# shows up while the stack is still open instead of on master.
#
# Prints ONE line on stdout: the path of a 0600 file holding the connection
# string. Progress goes to stderr, so `f=$(epic-db.sh ...)` is safe. Read it with
# `DATABASE_URL="$(cat "$f")"`. The URL is never printed, so it stays out of
# transcripts, issue comments, and PR bodies.
#
# The database is a pgmanager `pr`-env database numbered `epic + 9000` — pgmanager
# has no epic env, and 9000+ is the agent-scratch range that cannot collide with a
# real PR-preview database. The daily `pr-cleanup.yml` reaper deletes `pr`
# databases after 7 days; this script is create-if-missing, so a reaped epic costs
# one rebuild, not a lost epic.
#
# The script never touches an Infisical dev or prod database. It only ever writes
# to the URL it provisioned itself.
set -euo pipefail

repo="" app="" epic="" recreate=0 seed=1 seed_script="" use_secrets=0 schema_cmd="db:migrate"
extensions=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --epic) epic="$2"; shift 2 ;;
    --recreate) recreate=1; shift ;;
    --push) schema_cmd="db:push"; shift ;;
    --no-seed) seed=0; shift ;;
    --seed-script) seed_script="$2"; shift 2 ;;
    --secrets) use_secrets=1; shift ;;
    -x|--extension) extensions+=("$2"); shift 2 ;;
    *) echo "epic-db.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$repo" ] && [ -n "$app" ] && [ -n "$epic" ] || {
  echo "epic-db.sh: --repo, --app and --epic are all required" >&2; exit 2; }
case "$epic" in ''|*[!0-9]*) echo "epic-db.sh: --epic must be a number" >&2; exit 2 ;; esac
[ -d "$repo/apps/$app" ] || { echo "epic-db.sh: no app at $repo/apps/$app" >&2; exit 2; }

# pgmanager project names are ^[a-z][a-z0-9_]*$, so the app label swaps hyphens
# for underscores — the same mapping the ci-<app>.yml files use.
project="${app//-/_}"
prnum=$(( epic + 9000 ))
say() { echo "epic-db.sh: $*" >&2; }

pkg_has_script() {
  python3 - "$repo/apps/$app/package.json" "$1" <<'EOF'
import json, sys
sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])).get("scripts", {}) else 1)
EOF
}

if ! pkg_has_script "$schema_cmd"; then
  # Every app in this monorepo has db:migrate today; fall back rather than fail so
  # a new app without versioned migrations still gets a usable epic database.
  if [ "$schema_cmd" = "db:migrate" ] && pkg_has_script db:push; then
    say "$app has no db:migrate script — falling back to db:push"
    schema_cmd="db:push"
  else
    say "$app has no $schema_cmd script"; exit 1
  fi
fi

if [ "$recreate" = 1 ]; then
  say "dropping ${project} pr ${prnum}"
  pgmanager db delete "$project" pr "$prnum" >/dev/null 2>&1 || true
fi

if pgmanager db info "$project" pr "$prnum" --json >/dev/null 2>&1; then
  say "reusing existing ${project}_pr_${prnum}"
else
  say "creating ${project}_pr_${prnum}"
  create_args=()
  for ext in ${extensions+"${extensions[@]}"}; do create_args+=(--extension "$ext"); done
  pgmanager db create "$project" pr "$prnum" ${create_args+"${create_args[@]}"} --json >/dev/null
fi

url=$(pgmanager db credentials "$project" pr "$prnum" --json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["connection_string"])')
[ -n "$url" ] || { say "pgmanager returned no connection string"; exit 1; }

state_dir="$HOME/.local/state/ship-issue/epic-db"
mkdir -p "$state_dir"; chmod 700 "$state_dir"
url_file="$state_dir/${project}-${epic}.url"
( umask 077; printf '%s' "$url" > "$url_file" )

# `infisical run` injects the app's dev secrets, INCLUDING its own DATABASE_URL.
# The trailing `env DATABASE_URL=...` applies AFTER that injection, so the epic
# database always wins. Never reorder these two — swapping them would point a
# schema write at the shared dev database.
run_in_app() {
  if [ "$use_secrets" = 1 ]; then
    ( cd "$repo" && infisical run --env=dev --path="/$app" -- \
        env DATABASE_URL="$url" SKIP_ENV_VALIDATION=1 pnpm --filter "$app" "$@" )
  else
    ( cd "$repo" && env DATABASE_URL="$url" SKIP_ENV_VALIDATION=1 \
        pnpm --filter "$app" "$@" )
  fi
}

say "applying schema via $schema_cmd"
if ! run_in_app "$schema_cmd"; then
  say "$schema_cmd failed against the epic database"
  say "if the failure is a missing secret, re-run with --secrets"
  exit 1
fi

if [ "$seed" = 1 ]; then
  if [ -z "$seed_script" ]; then
    for candidate in db:seed e2e:seed; do
      if pkg_has_script "$candidate"; then seed_script="$candidate"; break; fi
    done
  fi
  if [ -z "$seed_script" ]; then
    say "no db:seed or e2e:seed script in $app — skipping seed"
    say "an epic that needs fixtures should add one in its first chunk"
  else
    say "seeding via $seed_script"
    if ! run_in_app "$seed_script"; then
      say "$seed_script failed"
      say "seeds that sign a user up need real secrets — re-run with --secrets"
      exit 1
    fi
  fi
fi

say "ready: ${project}_pr_${prnum}"
echo "$url_file"
