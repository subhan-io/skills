# shellcheck shell=bash
# Shared helpers for ship-issue scripts.
#
# Deliberately thin. Unlike dispatch-agents, this skill has NO per-repo config file: it takes
# one issue and runs interactively with a human at the keyboard, so anything repo-specific is
# either detected (default branch, package manager) or asked about. A config file you have to
# write before the first run is exactly the friction this skill exists to avoid.

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"; }
need gh
need jq
need git

# Main repo root even when invoked from inside a linked worktree.
main_repo_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir)" || die "not in a git repo"
  dirname "$common"
}

repo_slug() { gh repo view --json nameWithOwner --jq .nameWithOwner; }

# The repo's actual default branch — never assume main or master. A skill that hardcodes
# either is wrong in half the repos it runs in, and wrong silently: it cuts the branch from a
# ref that exists but isn't what anyone merges into.
default_branch() { gh repo view --json defaultBranchRef --jq .defaultBranchRef.name; }

# Accepts 12, #12, or https://github.com/owner/repo/issues/12 and echoes the bare number.
# A full URL is also checked against the current repo: silently working the wrong repo's
# issue is a worse failure than refusing.
parse_issue() {
  local raw="$1" num slug want
  case "$raw" in
    *github.com/*)
      want="$(printf '%s' "$raw" | sed -E 's#.*github\.com/([^/]+/[^/]+)/issues/.*#\1#')"
      num="$(printf '%s' "$raw" | sed -E 's#.*/issues/([0-9]+).*#\1#')"
      slug="$(repo_slug)"
      [ "$want" = "$slug" ] || die "issue URL points at $want but the current repo is $slug.
cd into a checkout of $want and run the skill there."
      ;;
    *) num="${raw#\#}" ;;
  esac
  case "$num" in ''|*[!0-9]*) die "could not read an issue number from: $raw" ;; esac
  printf '%s' "$num"
}
