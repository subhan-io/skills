#!/usr/bin/env bash
# epic-db.sh — provision the database one sub-issue of an epic works against.
#
#   epic-db.sh --repo <worktree> --app <app-dir> --epic <n> --issue <n>
#              [--recreate] [--push] [--no-seed] [--seed-script <name>]
#              [--secrets] [-x <extension>]
#
# One database per (app, sub-issue), built from the sub-issue's own worktree.
# The worktree branches from the tip of epic/<n>, so its migrations are every
# merged sibling's plus its own, applied in order. Concurrent sub-issues never
# share a database: one shared across branches with different migration sets
# left drizzle's journal out of step with the tables (epic #616).
#
# Re-run it before each chunk. It is create-if-missing and picks up the
# migrations the chunk added. When applying the schema to an existing database
# fails, it rebuilds the database once and applies again; a failure on the
# rebuilt, empty database is a real migration error and exits 1.
#
# Prints ONE line on stdout: the path of a 0600 file holding the connection
# string. Progress goes to stderr, so `f=$(epic-db.sh ...)` is safe. Read it with
# `DATABASE_URL="$(cat "$f")"`. The URL is never printed, so it stays out of
# transcripts, issue comments, and PR bodies.
#
# The database is a pgmanager `scratch` database keyed `epic<epic>_<issue>`,
# leased for 7 days and renewed on every call, so an abandoned one expires on
# its own. Extensions default to the app's CI `db-extensions:` value in
# .github/workflows/ci-<app>.yml; -x overrides it.
#
# --push applies the schema with `drizzle-kit push --force` when the app's
# db:push script is plain `drizzle-kit push`: without --force, push asks before
# any statement it counts as data loss, a non-interactive shell answers no, and
# nothing is applied. --force is safe only because this database is disposable.
#
# The script never touches an Infisical dev or prod database. It only ever writes
# to the URL it provisioned itself.
set -euo pipefail

repo="" app="" epic="" issue="" recreate=0 seed=1 seed_script="" use_secrets=0 schema_cmd="db:migrate"
extensions=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --epic) epic="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --recreate) recreate=1; shift ;;
    --push) schema_cmd="db:push"; shift ;;
    --no-seed) seed=0; shift ;;
    --seed-script) seed_script="$2"; shift 2 ;;
    --secrets) use_secrets=1; shift ;;
    -x|--extension) extensions+=("$2"); shift 2 ;;
    *) echo "epic-db.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$repo" ] && [ -n "$app" ] && [ -n "$epic" ] && [ -n "$issue" ] || {
  echo "epic-db.sh: --repo, --app, --epic and --issue are all required" >&2; exit 2; }
case "$epic" in ''|*[!0-9]*) echo "epic-db.sh: --epic must be a number" >&2; exit 2 ;; esac
case "$issue" in ''|*[!0-9]*) echo "epic-db.sh: --issue must be a number" >&2; exit 2 ;; esac
[ -d "$repo/apps/$app" ] || { echo "epic-db.sh: no app at $repo/apps/$app" >&2; exit 2; }

# pgmanager project names are ^[a-z][a-z0-9_]*$, so the app label swaps hyphens
# for underscores — the same mapping the ci-<app>.yml files use.
project="${app//-/_}"
key="epic${epic}_${issue}"
dbname="${project}_scratch_${key}"
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

if [ ${#extensions[@]} -eq 0 ]; then
  # `db-extensions: vector pg_trgm  # comment` -> vector pg_trgm
  ci="$repo/.github/workflows/ci-$app.yml"
  if [ -f "$ci" ]; then
    read -r -a extensions <<<"$(sed -n 's/^[[:space:]]*db-extensions:[[:space:]]*//p' "$ci" \
      | head -1 | sed 's/#.*//; s/,/ /g')"
    [ ${#extensions[@]} -eq 0 ] || say "extensions from $(basename "$ci"): ${extensions[*]}"
  fi
fi

create_db() {
  say "creating $dbname"
  local args=()
  for ext in ${extensions+"${extensions[@]}"}; do args+=(--extension "$ext"); done
  pgmanager db create "$project" scratch "$key" --ttl 7d ${args+"${args[@]}"} --json >/dev/null
}
drop_db() {
  say "dropping $dbname"
  pgmanager db delete "$project" scratch "$key" >/dev/null 2>&1 || true
}

[ "$recreate" = 1 ] && drop_db
fresh=0
if pgmanager db info "$project" scratch "$key" --json >/dev/null 2>&1; then
  say "reusing existing $dbname"
  pgmanager db renew "$project" scratch "$key" --ttl 7d >/dev/null 2>&1 || true
else
  create_db; fresh=1
fi

state_dir="$HOME/.local/state/ship-issue/epic-db"
mkdir -p "$state_dir"; chmod 700 "$state_dir"
url_file="$state_dir/${project}-${epic}-${issue}.url"
# A recreated database gets a new password, so this runs again after a rebuild.
fetch_url() {
  url=$(pgmanager db credentials "$project" scratch "$key" --json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["connection_string"])')
  [ -n "$url" ] || { say "pgmanager returned no connection string"; exit 1; }
  ( umask 077; printf '%s' "$url" > "$url_file" )
}
fetch_url

# Tool output goes to stderr: stdout carries only the url file path.
# `infisical run` injects the app's dev secrets, INCLUDING its own DATABASE_URL.
# The trailing `env DATABASE_URL=...` applies AFTER that injection, so the epic
# database always wins. Never reorder these two — swapping them would point a
# schema write at the shared dev database.
run_in_app() {
  if [ "$use_secrets" = 1 ]; then
    ( cd "$repo" && infisical run --env=dev --path="/$app" -- \
        env DATABASE_URL="$url" SKIP_ENV_VALIDATION=1 pnpm --filter "$app" "$@" ) >&2
  else
    ( cd "$repo" && env DATABASE_URL="$url" SKIP_ENV_VALIDATION=1 \
        pnpm --filter "$app" "$@" ) >&2
  fi
}

# True when the app's db:push script is exactly `drizzle-kit push`, so --force
# can be appended without guessing at another tool's flags.
plain_drizzle_push() {
  python3 - "$repo/apps/$app/package.json" <<'EOF'
import json, sys
script = json.load(open(sys.argv[1])).get("scripts", {}).get("db:push", "")
sys.exit(0 if script.strip() == "drizzle-kit push" else 1)
EOF
}
apply_schema() {
  if [ "$schema_cmd" = "db:push" ] && plain_drizzle_push; then
    say "applying schema via drizzle-kit push --force"
    run_in_app exec drizzle-kit push --force
  else
    say "applying schema via $schema_cmd"
    run_in_app "$schema_cmd"
  fi
}

if ! apply_schema; then
  if [ "$fresh" = 1 ]; then
    say "$schema_cmd failed against a new, empty $dbname: the migrations themselves fail"
    say "if the failure is a missing secret, re-run with --secrets"
    exit 1
  fi
  say "$schema_cmd failed against the existing $dbname; rebuilding it once"
  drop_db; create_db; fetch_url
  if ! apply_schema; then
    say "$schema_cmd failed again on the rebuilt, empty database: the migrations themselves fail"
    say "if the failure is a missing secret, re-run with --secrets"
    exit 1
  fi
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

say "ready: $dbname"
echo "$url_file"
