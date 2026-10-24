# Eval mode

Read this file when the invocation says `eval`. An eval run replays a task so
that two versions of this skill, or two arms of an experiment, can be compared
on the same work. It runs as AFK (read `afk.md` too) with these changes, so that
it publishes nothing:

- `run-start` carries `mode=eval`, so `usage-report.sh` keeps eval runs apart
  from production ones.
- The invocation names the base: `base=<ref>`. Use it wherever the skill says
  the default branch or `epic/<n>`.
- Work in the current checkout. When it is already on a branch other than the
  base, commit there: the eval reads the result from this checkout's HEAD.
- The issue is read, never written: no comments, no edits to its body or its
  parent's, no labels, no closing.
- No push, no PR, no merge, no `t3_thread_send`, no `repo-notes.md` change.
  Step 6 ends after the full test pass and the evidence gate, with the work
  committed on the run's branch.
- Step 7 runs its rounds through `review.sh` against `base=<ref>`, which reviews
  the local branch and needs no PR. When `review.sh` exits 2 (no Codex in this
  environment), skip review and say so in the handover. Findings are triaged
  and fixed as usual; the round comment goes into the handover, not onto a PR.
- The handover is the run's final message, and `run-end` logs `outcome=stopped`
  with the usual counts. When the invocation asks for it, write the handover to
  the file it names as well.
