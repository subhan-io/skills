#!/usr/bin/env bash
# stack.sh — keep an epic's stacked pull requests correct across merges.
#
#   stack.sh track   --repo R --branch B --parent P     # record B as stacked on P
#   stack.sh list    --repo R                           # show the recorded stack
#   stack.sh restack --repo R [--base master]           # rebase + retarget after a merge
#
# A stacked branch starts from its blocker's head, not from master, so a dependent
# sub-issue can be worked before its blocker merges. Its pull request opens with
# `--base <blocker-branch>`, so the diff shows only that sub-issue's own work.
#
# This repository squash-merges. A squash rewrites the blocker's commits, so after
# the blocker merges, every branch above it still carries the pre-squash commits
# and its merge base is stale — the diff would re-show the blocker's changes.
# `restack` is what repairs that: it rebases each remaining branch onto its new
# parent, force-pushes, and retargets the pull request.
#
# The parent and the exact commit a branch forked from are recorded in git config
# (`branch.<name>.shipEpicParent` / `.shipEpicBase`). The forked-from commit is the
# part that cannot be recovered later: after a squash merge the blocker branch is
# deleted, so nothing else can tell git which commits are the branch's own.
set -euo pipefail

cmd="${1:-}"; shift || true
repo="" branch="" parent="" base="master"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --parent) parent="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    *) echo "stack.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] || { echo "stack.sh: --repo is required" >&2; exit 2; }
git() { command git -C "$repo" "$@"; }
ghx() { ( cd "$repo" && command gh "$@" ); }
say() { echo "stack.sh: $*" >&2; }

# git stores config variable names lower-cased (the branch subsection keeps its
# case, the variable does not), so this pattern must be lower-case to match at
# all — `--get branch.<b>.shipEpicParent` reads fine either way, which is what
# makes the mistake silent.
tracked_branches() {
  git config --get-regexp '^branch\..*\.shipepicparent$' 2>/dev/null \
    | sed 's/^branch\.\(.*\)\.shipepicparent .*$/\1/' || true
}

case "$cmd" in
  track)
    [ -n "$branch" ] && [ -n "$parent" ] || {
      echo "stack.sh track: --branch and --parent are required" >&2; exit 2; }
    # Record where B actually left P. `restack` rebases everything after this
    # commit, so a tip taken from the wrong ref would replay the parent's own
    # commits onto the parent. Prefer the real merge base once B exists, and
    # prefer the remote tip over the local one — the remote is what the pull
    # request diffs against.
    parent_ref="$parent"
    git rev-parse --verify --quiet "origin/$parent" >/dev/null && parent_ref="origin/$parent"
    if git rev-parse --verify --quiet "$branch" >/dev/null; then
      forked_from=$(git merge-base "$branch" "$parent_ref")
    else
      forked_from=$(git rev-parse --verify "$parent_ref")
    fi
    [ -n "$forked_from" ] || { say "cannot resolve where $branch forks from $parent"; exit 1; }
    git config "branch.$branch.shipEpicParent" "$parent"
    git config "branch.$branch.shipEpicBase" "$forked_from"
    say "$branch tracked on $parent at ${forked_from:0:8}"
    ;;

  list)
    for b in $(tracked_branches); do
      p=$(git config --get "branch.$b.shipEpicParent")
      pr=$(ghx pr list --head "$b" --state open --json number -q '.[0].number' 2>/dev/null || true)
      echo "$b <- $p${pr:+  (PR #$pr)}"
    done
    ;;

  restack)
    [ -z "$(git status --porcelain)" ] || {
      say "the working tree is dirty — commit or set the changes aside first"; exit 1; }
    started_on=$(git rev-parse --abbrev-ref HEAD)
    git fetch --prune origin >/dev/null

    # Process a branch only once its parent is settled, so a three-deep stack
    # rebases bottom-up in one pass rather than leaving the top on a stale base.
    remaining=$(tracked_branches)
    settled=" $base "
    progress=1
    while [ -n "${remaining// /}" ] && [ "$progress" = 1 ]; do
      progress=0; still=""
      for b in $remaining; do
        # Drop a branch that is already merged away. `git branch -d` clears its
        # config, but an AFK run merges with --delete-branch, which removes the
        # branch on origin only — the local ref and this tracking survive, and
        # rebasing on them would force-push a merged branch back into existence.
        # A branch that was never pushed has no `branch.<b>.remote`, which is
        # what separates "not yet opened" from "merged and gone".
        if ! git rev-parse --verify --quiet "$b" >/dev/null \
           || { git config --get "branch.$b.remote" >/dev/null 2>&1 \
                && ! git rev-parse --verify --quiet "origin/$b" >/dev/null; }; then
          say "$b is merged or gone — untracking it"
          git config --unset "branch.$b.shipEpicParent" || true
          git config --unset "branch.$b.shipEpicBase" || true
          settled="$settled $b "; progress=1; continue
        fi

        # A branch with no upstream has not opened a pull request yet, so there
        # is nothing to retarget and nothing to keep in sync. Leave it tracked
        # and untouched — pushing it here would publish an empty branch.
        if ! git config --get "branch.$b.remote" >/dev/null 2>&1; then
          say "$b is not pushed yet — leaving it alone"
          settled="$settled $b "; progress=1; continue
        fi

        p=$(git config --get "branch.$b.shipEpicParent")

        # A parent that no longer exists on the remote was squash-merged and
        # deleted. Everything stacked on it now belongs directly on the base.
        if ! git rev-parse --verify --quiet "origin/$p" >/dev/null && [ "$p" != "$base" ]; then
          say "$b: parent $p is merged and gone — reparenting onto $base"
          p="$base"; git config "branch.$b.shipEpicParent" "$base"
        fi
        case "$settled" in *" $p "*) ;; *) still="$still $b"; continue ;; esac

        new_parent_tip=$(git rev-parse --verify "origin/$p")
        old_base=$(git config --get "branch.$b.shipEpicBase" || echo "")
        [ -n "$old_base" ] || { say "$b has no recorded fork point — skipping"; continue; }

        if [ "$new_parent_tip" = "$old_base" ]; then
          say "$b is already on top of $p"
        else
          say "$b: rebasing onto $p"
          if ! git rebase --onto "$new_parent_tip" "$old_base" "$b"; then
            git rebase --abort || true
            git checkout "$started_on" >/dev/null 2>&1 || true
            say "$b conflicts with $p — resolve it by hand, then re-run restack"
            exit 1
          fi
          git config "branch.$b.shipEpicBase" "$new_parent_tip"
          git push --force-with-lease origin "$b"
        fi

        pr=$(ghx pr list --head "$b" --state open --json number -q '.[0].number' 2>/dev/null || true)
        if [ -n "$pr" ]; then
          ghx pr edit "$pr" --base "$p" >/dev/null
          say "$b: PR #$pr now targets $p"
        fi
        settled="$settled $b "; progress=1
      done
      remaining="$still"
    done
    [ -z "${remaining// /}" ] || say "could not settle:${remaining} (parent cycle?)"

    git checkout "$started_on" >/dev/null 2>&1 || true
    say "restack complete"
    ;;

  *) echo "stack.sh: expected track, list, or restack" >&2; exit 2 ;;
esac
