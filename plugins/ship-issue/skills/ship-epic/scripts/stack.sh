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
gitw() { command git -C "$1" "${@:2}"; }
ghx() { ( cd "$repo" && command gh "$@" ); }
say() { echo "stack.sh: $*" >&2; }

# The worktree that has a branch checked out, if any. `git rebase` switches to
# the branch internally, and git refuses that when another worktree holds it —
# ship-epic gives every picked branch its own worktree, so this is the normal
# case rather than the exception.
worktree_for() {
  git worktree list --porcelain \
    | awk -v ref="refs/heads/$1" '/^worktree /{wt=substr($0,10)} $0 == "branch " ref {print wt; exit}'
}

# A branch is done when its remote branch is gone or when its pull request has
# merged. Both spellings occur: an AFK run merges with --delete-branch, which
# removes the branch on origin only, while an attended merge is the human's and
# they may leave the branch in place. Treating absence alone as "merged" would
# leave a dependent PR targeting a merged branch, so merging it would update
# that dead branch instead of shipping to the base.
#
# A branch that was never pushed has no `branch.<b>.remote`, which is what
# separates "not yet opened" from "merged and gone".
branch_is_merged() {
  if git config --get "branch.$1.remote" >/dev/null 2>&1 \
     && ! git rev-parse --verify --quiet "origin/$1" >/dev/null; then
    return 0
  fi
  [ -n "$(ghx pr list --head "$1" --state merged --json number -q '.[0].number' 2>/dev/null)" ]
}

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
        # Drop a branch that is already merged. `git branch -d` clears its
        # config, but merging does not — the local ref and this tracking
        # survive, and rebasing on them would force-push merged work back into
        # existence.
        if ! git rev-parse --verify --quiet "$b" >/dev/null || branch_is_merged "$b"; then
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

        # A merged parent is out of the stack, so everything above it belongs
        # directly on the base now.
        if [ "$p" != "$base" ] && branch_is_merged "$p"; then
          say "$b: parent $p is merged — reparenting onto $base"
          p="$base"; git config "branch.$b.shipEpicParent" "$base"
        fi
        case "$settled" in *" $p "*) ;; *) still="$still $b"; continue ;; esac

        new_parent_tip=$(git rev-parse --verify "origin/$p")
        old_base=$(git config --get "branch.$b.shipEpicBase" || echo "")
        [ -n "$old_base" ] || { say "$b has no recorded fork point — skipping"; continue; }

        if [ "$new_parent_tip" = "$old_base" ]; then
          say "$b is already on top of $p"
        else
          # Rebase where the branch actually lives, or git refuses to switch to
          # it. A worktree mid-edit must not be rewritten under the person
          # working in it, so an unclean one stops the run instead.
          wt=$(worktree_for "$b")
          rebase_in="${wt:-$repo}"
          if [ -n "$wt" ] && [ -n "$(gitw "$wt" status --porcelain)" ]; then
            say "$b: its worktree $wt is dirty — commit or set the changes aside first"
            exit 1
          fi

          say "$b: rebasing onto $p"
          pre_rebase=$(git rev-parse "$b")
          if ! gitw "$rebase_in" rebase --onto "$new_parent_tip" "$old_base" "$b"; then
            gitw "$rebase_in" rebase --abort || true
            git checkout "$started_on" >/dev/null 2>&1 || true
            say "$b conflicts with $p — resolve it by hand, then re-run restack"
            exit 1
          fi

          # Record the new fork point only once the push it describes has
          # landed, and undo the local rebase if it has not. Recording first
          # leaves the next run seeing new_parent_tip == old_base, so it skips
          # both the rebase and the push and reports success while the remote
          # still holds the stale commits.
          if ! git push --force-with-lease origin "$b"; then
            gitw "$rebase_in" reset --hard "$pre_rebase" >/dev/null
            git checkout "$started_on" >/dev/null 2>&1 || true
            say "$b: push failed — rolled the branch back to ${pre_rebase:0:8}, re-run restack"
            exit 1
          fi
          git config "branch.$b.shipEpicBase" "$new_parent_tip"
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
