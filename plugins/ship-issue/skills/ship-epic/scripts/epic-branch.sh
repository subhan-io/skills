#!/usr/bin/env bash
# epic-branch.sh — the epic's integration branch.
#
#   epic-branch.sh ensure --repo R --epic N [--base main]  # create epic/N off base if absent; prints its name
#   epic-branch.sh sync   --repo R --epic N [--base main]  # merge base into epic/N and push
#   epic-branch.sh status --repo R --epic N [--base main]  # drift from base, PRs into it, the epic PR
#
# One branch per epic, `epic/N`, forked from the base branch. Every sub-issue
# branches from its tip and opens its PR against it; a finished sub-issue merges
# into it. Parallel sub-issues are then ordinary siblings of one branch — nothing
# to rebase when one of them merges — and a sub-issue that depends on two others
# branches from the tip once both are in. The human merges epic/N into the base
# once, as the feature's PR.
#
# sync prints nothing on stdout when the branch is current or the merge is clean.
# On a conflict it prints one line —
#   conflict branch=epic/N base=<base> worktree=<dir>
# — and exits 1 with the merge aborted and the worktree left clean at origin/epic/N
# for a resolver to redo the merge in.
#
# The merge runs in a worktree of its own under ~/.local/state/ship-issue/epic-N/,
# named for the repository (origin's owner/name) so two repositories that both
# have an epic N never share one, and checked to belong to this repository before
# it is reused. It is detached and reset to origin/epic/N on every sync, so
# nothing a resolver left half-done survives a re-run: only a pushed merge counts.
set -euo pipefail

cmd="${1:-}"; shift || true
repo="" epic="" base="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --epic) epic="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    *) echo "epic-branch.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] && [ -n "$epic" ] || { echo "epic-branch.sh: --repo and --epic are required" >&2; exit 2; }
case "$epic" in ''|*[!0-9]*) echo "epic-branch.sh: --epic must be a number" >&2; exit 2 ;; esac
branch="epic/$epic"
git() { command git -C "$repo" "$@"; }
ghx() { ( cd "$repo" && command gh "$@" ); }
say() { echo "epic-branch.sh: $*" >&2; }

git fetch --quiet origin

case "$cmd" in
  ensure)
    if ! git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
      git rev-parse --verify --quiet "origin/$base" >/dev/null \
        || { say "no origin/$base to fork from"; exit 1; }
      git push --quiet origin "origin/$base:refs/heads/$branch"
      say "$branch created from origin/$base"
    fi
    echo "$branch" ;;

  sync)
    git rev-parse --verify --quiet "origin/$branch" >/dev/null \
      || { say "no origin/$branch — run ensure first"; exit 1; }
    if git merge-base --is-ancestor "origin/$base" "origin/$branch"; then
      say "$branch already contains origin/$base"; exit 0
    fi
    slug=$(git remote get-url origin | sed -E 's#/$##; s#\.git$##; s#^.*[:/]([^/]+)/([^/]+)$#\1-\2#')
    wt="$HOME/.local/state/ship-issue/epic-$epic/worktree-$slug"
    common=$(realpath "$(git rev-parse --git-common-dir)")
    if git worktree list --porcelain | grep -Fxq "worktree $wt" \
       && [ "$(realpath "$(command git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null)" = "$common" ]; then
      command git -C "$wt" merge --abort >/dev/null 2>&1 || true
      command git -C "$wt" reset --quiet --hard
      command git -C "$wt" checkout --quiet --detach "origin/$branch"
    else
      # A directory this repository does not own — never registered, pruned, or
      # left by another checkout — is scratch: the branch it held is on origin
      # or it never counted.
      rm -rf "$wt"; mkdir -p "$(dirname "$wt")"
      git worktree prune
      git worktree add --quiet --detach "$wt" "origin/$branch"
    fi
    if command git -C "$wt" merge --no-edit "origin/$base" >&2; then
      command git -C "$wt" push --quiet origin "HEAD:refs/heads/$branch"
      say "$branch: merged origin/$base and pushed"
    else
      command git -C "$wt" merge --abort
      echo "conflict branch=$branch base=$base worktree=$wt"
      exit 1
    fi ;;

  status)
    git rev-parse --verify --quiet "origin/$branch" >/dev/null \
      || { echo "$branch: not created"; exit 0; }
    counts=$(git rev-list --left-right --count "origin/$base...origin/$branch")
    behind=${counts%%[[:space:]]*}; ahead=${counts##*[[:space:]]}
    echo "$branch: $ahead commits ahead of $base, $behind behind"
    echo "merged into $branch:"
    ghx pr list --base "$branch" --state merged --json number,title,mergedAt \
      -q 'if length == 0 then "  none" else .[] | "  #\(.number) \(.title) (\(.mergedAt[0:10]))" end'
    echo "open against $branch:"
    ghx pr list --base "$branch" --state open --json number,title,isDraft \
      -q 'if length == 0 then "  none" else .[] | "  #\(.number) \(.title)\(if .isDraft then " (draft)" else "" end)" end'
    echo "epic pull request ($branch -> $base):"
    ghx pr list --head "$branch" --base "$base" --state all --json number,state,isDraft,url \
      -q 'if length == 0 then "  none" else .[] | "  #\(.number) \(.state | ascii_downcase)\(if .isDraft then " draft" else "" end) \(.url)" end' ;;

  *) echo "epic-branch.sh: ensure | sync | status" >&2; exit 2 ;;
esac
