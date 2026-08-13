---
name: ship-issue
description: Take ONE named GitHub issue end to end in a fresh worktree — plan it with an opus subagent, stop for the human's approval, implement it one sonnet subagent per plan chunk, open a PR, run it through Codex review, and resolve the findings with an opus subagent — leaving a green PR for the human to merge. Use when the user points at a specific issue and wants it carried to a mergeable PR: "take issue 12 end to end", "ship this issue", "plan and implement <issue URL>", "get this ready for me to merge". For the unattended multi-issue pipeline that sweeps every ready-for-agent issue on a board, use dispatch-agents instead — this skill is single-issue, interactive, and always stops for plan approval.
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

**Models:** planner `opus`, chunk implementers `sonnet`, resolver `opus`, rebase/fix `sonnet`.
Pass via the Agent tool's `model` param at spawn.

**Agent count is not fixed.** The planner decides it: one implementer agent per chunk it returns,
plus whatever rebase/fix agents the sync check calls for. A five-chunk plan is five implementers,
sequentially.

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

### 4. Implement — one sonnet subagent per chunk

**One agent per chunk, spawned in order, never in parallel.** The chunks exist because each was
sized to fill a session's context; running them all in one agent spends that budget three times
over and the later chunks execute with the earlier ones evicted. A chunk boundary is a context
reset, not a comment header.

For each chunk in the approved plan, in order:

1. Spawn a background Agent with `model: "sonnet"`, given `implementer-prompt.md` with every
   `{{...}}` filled: the chunk itself, the plan summary, the full chunk list for orientation, and
   `{{PREVIOUS_CHUNKS}}` — the **handoff reports of the chunks already done**, verbatim. The
   agent has no memory of them; that block is the only continuity it gets. For chunk 1 it says
   nothing has landed yet.
2. Wait for it to report, then read the report before spawning the next one. The next chunk's
   prompt is built from it.
3. Only when it reports its chunk green and pushed does the next chunk start.

Never spawn the next chunk over a chunk that stopped early, went red, or reported the plan wrong
— that is the failure the boundaries exist to contain. Take it to the user instead:

- **Plan proved wrong** → back to the user with what the agent found. Usually the answer is
  re-planning the remaining chunks, not forcing this one through.
- **Left red or stopped mid-chunk** → the worktree is in an unknown state. Report the state and
  what the agent said; do not paper over it with a fix agent that has no idea what was intended.

Keep every handoff report for the whole run. They feed later chunks, the PR body, and the
hand-off in step 9.

**Screenshots.** A chunk touching user-visible code returns published image URLs in its report,
captured the one sanctioned way: **a throwaway Playwright script against a temporary harness
seeded with mock data** — never `agent-browser`, never the browser MCP tools or in-app browser
pane, never a preview deploy. `implementer-prompt.md` spells out why and how; your job is to not
accept less. A UI chunk that reports no screenshots and no explicit `un-capturable:` reason is an
incomplete chunk — send it back rather than carrying the gap into the PR.

### 5. Open the PR

Once the last chunk reports green, open the PR yourself — into the base branch, with
`Closes #<n>` in the body. No implementer agent has the whole picture; you do, from the plan and
the handoff reports. The body should cover what changed and why, chunk by chunk, how it was
verified (the results the agents actually observed, not "tests pass"), the screenshots from every
chunk that produced them, and anything deliberately left out or deviated from.

Embed images as `![alt](url)` and video as a raw `<video src="url" controls width="640">` tag on
its own line. If a UI chunk came back `un-capturable:`, carry that reason into the body — a
reviewer should never have to guess whether the shots were skipped or impossible.

Do not merge it, and do not post `@codex review` here — step 7 does that.

### 6. Sync check

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
- **green** → step 7.

### 7. Codex review

`scripts/codex-wait.sh request <pr>` (exit 5 = already requested for this head commit, fine),
then run `scripts/codex-wait.sh watch <pr>` through Bash with **`run_in_background: true`** and
end your turn. Its completion notification re-invokes you. Never run `watch` in the foreground —
it blocks for up to 15 minutes.

Exit 4 means it timed out with codex still silent. Say so and hand back to the user; do not
re-trigger on a loop.

### 8. Resolve — opus subagent

With the review settled, run `scripts/codex-wait.sh findings <pr>` and spawn a background Agent
with `model: "opus"`, given `resolver-prompt.md` with the findings inline. It fixes what is
right, rebuts what is wrong with evidence, defers what is out of scope, verifies, pushes, and
posts a round summary.

Its push moves head, so codex will read as `not-requested` again. **Return to step 6** — that is
intended: each round gets a review of the code it is actually judging.

**Max 2 resolve rounds.** Count them by the `(resolver, round N)` PR comments, so a resumed
session sees the same count. At the cap, stop and hand the PR to the user with what is
outstanding — do not start a third round.

### 9. Hand off

When the PR is green, codex is settled with no unresolved blockers, and the branch is current
with the base, tell the user it is ready to merge. Include: PR URL, what was built, what codex
found and how each finding was resolved (fixed / rebutted / deferred), verification results, and
anything still open.

## Hard rules

- **Never merge.** Not at the cap, not when it looks obviously fine.
- **Never skip the approval gate**, and never treat "sounds good" on something else as approval
  of the plan.
- Never weaken or delete a test to make a gate or a finding go away.
- **Screenshots come from Playwright + mock data, never from `agent-browser` or any other live
  browser.** This holds for resolve and fix agents too, not just chunks — if a codex finding is
  about UI, the re-shot evidence is captured the same way.
- Every verification command runs from **inside the PR's worktree**.
- One agent per worktree at a time — the step order already keeps chunk, fix, rebase and resolve
  agents from overlapping; respect it. Chunks are sequential for the same reason: they share a
  worktree and each one builds on the last.
- **Never collapse the chunks into one agent** because the issue looks small. If it is genuinely
  one session of work, the planner returns one chunk and that is the same thing.
- Spawn background agents and end your turn rather than polling; completion notifications
  re-invoke you.
- If reality contradicts expectations (PR closed by hand, branch diverged, issue reassigned),
  report it and prefer doing less over guessing.
