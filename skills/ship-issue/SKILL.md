---
name: ship-issue
description: Take ONE named GitHub issue end to end in a fresh worktree — plan it with an opus subagent, stop for the human's approval, implement with a sonnet subagent, open a PR, run it through Codex review, and resolve the findings with an opus subagent — leaving a green PR for the human to merge. Use when the user points at a specific issue and wants it carried to a mergeable PR: "take issue 12 end to end", "ship this issue", "plan and implement <issue URL>", "get this ready for me to merge". For the unattended multi-issue pipeline that sweeps every ready-for-agent issue on a board, use dispatch-agents instead — this skill is single-issue, interactive, and always stops for plan approval.
---

# Ship one issue, end to end

One issue in, one mergeable PR out. Unlike `dispatch-agents` (which sweeps a whole board
unattended), this skill runs **one issue with a human in the loop** and has exactly one hard
stop: the plan must be approved before any code is written.

**Never merge the PR.** The human's merge click is the finish line, not yours.

**Every path below is relative to this skill's own directory**, not the repo you are working in.
The skill is installed once per machine and runs against whatever repo is the cwd, so resolve
`scripts/setup.sh` against the directory this SKILL.md was loaded from, and pass that absolute
directory to any subagent that needs a script.

**No per-repo config file.** The repo's default branch, toolchain and verification commands are
detected by `scripts/setup.sh`. Where detection fails it emits a warning naming what it could
not find — surface those to the user and ask, rather than assuming.

**Argument:** the issue — a full URL (`https://github.com/owner/repo/issues/12`), `#12`, or `12`.
A URL naming a different repo than the cwd is a hard error, not a silent retarget.

| Script | Does |
|---|---|
| `scripts/setup.sh <issue> [--dry-run]` | resolves the issue, detects base branch + commands, creates the worktree off the **current** tip of the default branch, returns one JSON blob with `warnings` |
| `scripts/pr-status.sh <pr>` | the between-steps snapshot: `classification` (conflict/pending/red/green), `behindBase`, `needsRebase`, codex state |
| `scripts/codex-wait.sh status\|request\|watch\|findings <pr>` | drives the Codex review; `watch` blocks until settled — **always background it** |

**Models:** planner `opus`, implementer `sonnet`, resolver `opus`, rebase/fix `sonnet`.
Pass via the Agent tool's `model` param at spawn.

**Codex is not a GitHub check.** Nothing in `gh pr checks` reflects it. You post `@codex review`,
the review lands minutes later as a review body plus inline comments, and the only completion
signal is that the bot has gone quiet for the settle window (120s). Two rules, both encoded in
`codex-wait.sh` and both learned the hard way — do not second-guess them:

- **Never read an `arriving` review.** Codex posts inline comments in bursts *after* the review
  body, so reading early gives a truncated finding set and the resolver fixes half the review.
- **Never treat a review of an older commit as covering head.** Coverage is decided by the
  `**Reviewed commit:** <sha>` line in the review body, not by timestamps.

## The run, in order

### 1. Set up

Run `scripts/setup.sh <issue>`. It fetches origin, creates `.claude/worktrees/ship-issue-<n>` on
branch `ship/issue-<n>` cut from `origin/<default-branch>`, and reports what it detected.

Read `warnings` before going further. An existing worktree, a missing test command, an
undetectable toolchain, or no sign of the Codex app in this repo each change what you should do
next — **surface them to the user; never paper over them.** The script deliberately never resets
an existing worktree: whether to build on prior work or discard it is the human's call.

### 2. Plan — opus subagent

Spawn a background Agent with `model: "opus"`, given `planner-prompt.md` with every `{{...}}`
filled from the setup blob. It reads the code and returns a chunked plan, each chunk sized to
fit one Claude Code session (~200k tokens) and independently verifiable.

### 3. Approval gate — HARD STOP

Present the plan to the user and **wait**. Do not spawn the implementer, do not create branches,
do not write code. This is the whole point of the skill's interactive shape: the cheapest place
to catch a wrong approach is before anything is built.

If the user asks for changes, re-spawn the planner with their feedback and present again. Only
an explicit green light moves to step 4.

### 4. Implement — sonnet subagent

Spawn a background Agent with `model: "sonnet"`, given `implementer-prompt.md` filled in with the
**approved plan** inline. It implements chunk by chunk, verifies, pushes, and opens a PR with
`Closes #<n>`. It does not merge and does not trigger codex.

When it reports back, note the PR number. If it stopped early because the plan proved wrong,
take that to the user rather than spawning a fix agent to force it through.

### 5. Sync check

Before review, run `scripts/pr-status.sh <pr>`:

- **conflict** → spawn a rebase agent (`sonnet`) in the worktree: `git fetch origin`, hard-reset
  to `origin/<branch>`, rebase onto `origin/<base>`. Resolve conflicts preserving the intent of
  both sides; re-run every verification command; force-push `--force-with-lease`. If a hunk is
  genuinely ambiguous — both sides changed the same contract incompatibly — `git rebase --abort`
  and escalate to the user. Never force-push a guess to turn a PR green.
- **needsRebase** without conflict → same agent, expecting a clean rebase.
- **red** → spawn a fix agent (`sonnet`): reproduce the failing checks in the worktree, fix the
  root cause, never weaken tests.
- **pending** → wait; re-check rather than proceeding.
- **green** → step 6.

### 6. Codex review

`scripts/codex-wait.sh request <pr>` (exit 5 = already requested for this head commit, fine),
then run `scripts/codex-wait.sh watch <pr>` through Bash with **`run_in_background: true`** and
end your turn. Its completion notification re-invokes you. Never run `watch` in the foreground —
it blocks for up to 15 minutes.

Exit 4 means it timed out with codex still silent. Say so and hand back to the user; do not
re-trigger on a loop.

### 7. Resolve — opus subagent

With the review settled, run `scripts/codex-wait.sh findings <pr>` and spawn a background Agent
with `model: "opus"`, given `resolver-prompt.md` with the findings inline. It fixes what is
right, rebuts what is wrong with evidence, defers what is out of scope, verifies, pushes, and
posts a round summary.

Its push moves head, so codex will read as `not-requested` again. **Return to step 5** — that is
intended: each round gets a review of the code it is actually judging.

**Max 2 resolve rounds.** Count them by the `(resolver, round N)` PR comments, so a resumed
session sees the same count. At the cap, stop and hand the PR to the user with what is
outstanding — do not start a third round.

### 8. Hand off

When the PR is green, codex is settled with no unresolved blockers, and the branch is current
with the base, tell the user it is ready to merge. Include: PR URL, what was built, what codex
found and how each finding was resolved (fixed / rebutted / deferred), verification results, and
anything still open.

## Hard rules

- **Never merge.** Not at the cap, not when it looks obviously fine.
- **Never skip the approval gate**, and never treat "sounds good" on something else as approval
  of the plan.
- Never weaken or delete a test to make a gate or a finding go away.
- Every verification command runs from **inside the PR's worktree**.
- One agent per worktree at a time — the step order already keeps fix, rebase and resolve agents
  from overlapping; respect it.
- Spawn background agents and end your turn rather than polling; completion notifications
  re-invoke you.
- If reality contradicts expectations (PR closed by hand, branch diverged, issue reassigned),
  report it and prefer doing less over guessing.
