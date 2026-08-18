---
name: ship-issue
description: >-
  Take ONE named GitHub issue end to end in a fresh worktree — plan it with a dedicated planning
  agent, stop for the human's approval, implement it one fresh agent per plan chunk, open a PR,
  run it through Codex review, and resolve the findings with a dedicated resolving agent —
  leaving a green PR for the human to merge. Use when the user points at a specific issue and
  wants it carried to a mergeable PR: "take issue 12 end to end", "ship this issue",
  "plan and implement issue URL", "get this ready for me to merge". For the unattended multi-issue pipeline that
  sweeps every ready-for-agent issue on a board, use dispatch-agents instead — this skill is
  single-issue, interactive, and always stops for plan approval.
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

## Runtime adapter

This workflow names **roles**, not required model brands: planner, chunk implementer, resolver,
and rebase/fix agent. When the runtime supports model selection, prefer `opus` for planner and
resolver roles and `sonnet` for chunk implementer and rebase/fix roles. When it does not, use a
fresh available subagent for the role and tell the user about the substitution before spawning;
never claim a model was selected when the tool cannot select it.

Before setup, inspect the available delegation tools and establish whether they support model
selection, waiting, and automatic parent resumption. For Codex collaboration tools, read
[references/codex-runtime.md](references/codex-runtime.md) before spawning the first subagent.

Keep these states distinct throughout the run:

- **agent complete** — the delegated agent returned;
- **step validated** — the parent inspected the returned artifact and confirmed the step's exit
  conditions;
- **workflow complete** — the PR is current, green, and has no unresolved Codex blockers.

Never describe an agent or step completing as the issue being "finished". Only the final handoff
in step 9 completes this workflow.

**Agent count is not fixed.** The planner decides it: one implementer agent per chunk it returns,
plus whatever rebase/fix agents the sync check calls for. A five-chunk plan is five implementers,
sequentially.

**Codex is not a GitHub check.** Nothing in `gh pr checks` reflects it. You post `@codex review`,
the review lands minutes later, and the only completion signal is that the bot has gone quiet for
the settle window (120s). It arrives in **either of two shapes** — a PR review plus inline
comments when it has findings, or a plain issue comment ("no major issues") when it does not.
Three rules, all encoded in `codex-wait.sh` and all learned the hard way — do not second-guess
them:

- **Never read an `arriving` review.** Codex posts inline comments in bursts *after* the review
  body, so reading early gives a truncated finding set and the resolver fixes half the review.
- **Never treat a review of an older commit as covering head.** Coverage is decided by the
  `**Reviewed commit:** <sha>` line, not by timestamps — and that line appears in both shapes.
- **Never trust an inline finding's `commit_id`.** GitHub advances it as head moves, so a finding
  from two rounds ago reports the current head and reads as new. `findings` reports `raisedOn`
  (the original commit) for exactly this reason.
- **A thread with replies in it is not a resolved finding.** Prior resolution is evidenced by the
  `(resolver, round N)` marker — `resolverReplyCount` and `counts.unresolved` — not by
  `replyCount`, which also counts a human asking codex a follow-up.

**Two `gh` traps worth knowing before they eat a step.** `gh pr edit` fails outright on hosts
where GitHub has sunset Projects (classic) unless `gh` is recent — it queries the removed
`projectCards` field and exits 1, so the edit silently never applies. Either upgrade `gh` or use
`gh api repos/<slug>/pulls/<n> -X PATCH -F body=@file`, and **check the exit code** rather than
assuming an edit landed.

## The run, in order

### 1. Set up

Run `scripts/setup.sh <issue>`. It fetches origin, creates `.claude/worktrees/ship-issue-<n>` on
branch `ship/issue-<n>` cut from `origin/<default-branch>`, and reports what it detected.

Read `warnings` before going further. An existing worktree, a missing test command, an
undetectable toolchain, or no sign of the Codex app in this repo each change what you should do
next — **surface them to the user; never paper over them.** The script deliberately never resets
an existing worktree: whether to build on prior work or discard it is the human's call.

Two fields in the blob are worth more than they look:

- **`issueStatedCommands`** — commands the issue itself names, typically in its acceptance
  criteria, with the directory each script actually lives in. In a monorepo the issue's real gate
  is often app-local (`cd apps/foo && pnpm check`) while the detected `commands` are the root
  ones: both real, but only one is what the issue is asking you to satisfy. **Pass these to every
  agent**, and prefer them over the generic detection when they disagree.
- **`stateDir`** — `<repo>/.claude/worktrees/ship-issue-<n>.state/`, beside the worktree rather
  than inside it, so nothing written there can reach the PR diff. The approved plan and every
  chunk handoff live here.

**Read files from the worktree, never from the main checkout.** They are different commits: the
worktree is cut from `origin/<base>`, while the main checkout is wherever the human left it and is
routinely behind. A `package.json` read from the wrong one describes a toolchain that no longer
exists, and every agent you brief inherits the error.

A warning about `pr-media-upload` (missing plugin, or `infisical`/`aws` not on `PATH`) matters
only if this issue touches UI — raise it then, before planning, since the alternative is an agent
completing a whole capture and finding it has nowhere to publish. The human either installs the
prerequisites or accepts that UI chunks will report their shots un-capturable.

### 2. Plan — planner agent

Spawn a fresh planner agent, using `opus` when model selection is available, given
`planner-prompt.md` with every `{{...}}` filled from the setup blob. It reads the code and
returns a chunked plan, each chunk sized to fit one agent session and independently verifiable.

Wait according to the runtime adapter; do not end the parent turn merely because the planner is
running unless the runtime guarantees automatic continuation. When it returns, the parent must
validate the plan before presenting it: map every acceptance criterion to a chunk; confirm named
existing paths and functions from the worktree; confirm every chunk can end green; confirm every
UI chunk budgets the required screenshot process; and surface every ambiguity rather than
silently deciding it. An agent's `completed` status is not plan approval or step validation.

### 3. Approval gate — HARD STOP

Present the plan to the user and **wait**. Do not spawn the implementer, do not create branches,
do not write code. This is the whole point of the skill's interactive shape: the cheapest place
to catch a wrong approach is before anything is built.

**On approval, write the plan to `<stateDir>/plan.md` before spawning anything**, along with any
decisions the human made at the gate — those are part of the plan now, and a chunk agent that
re-litigates a settled question wastes a session. Until it is on disk the plan exists only in your
context: the chunks cannot cite it, a handoff that points at it is pointing at nothing, and a
resumed session has lost it. Pass the path to every agent from here on.

Do **not** post the plan to the issue instead. The issue is the spec; a chunked implementation
plan with token estimates is process ephemera that clutters it for every later reader, and
re-planning after feedback leaves two comments with no way to tell which is current.

If the user asks for changes, re-spawn the planner with their feedback and present again. Only
an explicit green light moves to step 4.

### 4. Implement — one sonnet subagent per chunk

**One agent per chunk, spawned in order, never in parallel.** The chunks exist because each was
sized to fill a session's context; running them all in one agent spends that budget three times
over and the later chunks execute with the earlier ones evicted. A chunk boundary is a context
reset, not a comment header.

For each chunk in the approved plan, in order:

1. Spawn a fresh implementer agent, using `sonnet` when model selection is available, given
   `implementer-prompt.md` with every
   `{{...}}` filled: the chunk itself, the plan summary, the full chunk list for orientation,
   `{{SKILL_DIR}}` — this skill's own absolute directory, since the agent reads
   `handoff-prompt.md` out of it — `{{STATE_DIR}}` from the setup blob, where the plan and the
   handoffs live, `{{ISSUE_STATED_COMMANDS}}` so it verifies the gate the issue actually names,
   and `{{PREVIOUS_CHUNKS}}`, **one line per chunk already done, in order, each naming that chunk
   and the absolute path of its handoff document**. The agent has no memory of them; those
   documents are the only continuity it gets. For chunk 1 it says nothing has landed yet.

   Also hand it `uploadScript` from the setup blob — the absolute path of `pr-media-upload`'s
   `upload.sh`, when setup found one. The agent can search for it, but a path you already have
   beats a search it might get wrong on the first try, after it has done the capture work.
2. Wait according to the runtime adapter, then **read the handoff document it names** before
   spawning the next one. Also inspect the branch state and reported verification evidence. A
   path that is missing, empty, describes a chunk that stopped early, or conflicts with the
   worktree is a stop, not a detail. Only after these checks is the chunk step validated.
3. Only when it reports its chunk green and pushed does the next chunk start.

Never spawn the next chunk over a chunk that stopped early, went red, or reported the plan wrong
— that is the failure the boundaries exist to contain. Take it to the user instead:

- **Plan proved wrong** → back to the user with what the agent found. Usually the answer is
  re-planning the remaining chunks, not forcing this one through.
- **Left red or stopped mid-chunk** → the worktree is in an unknown state. Report the state and
  what the agent said; do not paper over it with a fix agent that has no idea what was intended.

**The handoffs are written to a spec, not improvised.** Each implementer ends by compacting its
session into a handoff document aimed at whoever runs next, and reports the path. The method is
`handoff-prompt.md`, bundled in this skill's directory — adapted from Matt Pocock's `handoff`
skill, which it defers to when that skill is installed. Either route produces the same document,
so **nothing about the run changes with what is installed on the machine** and there is nothing to
check up front.

You pass **paths, not prose** — the document is written for the next implementer to read in full,
while you read it to confirm the chunk landed and to mine it for the PR body. Keep every path for
the whole run: they feed later chunks, the PR body in step 5, and the hand-off in step 9.

**Screenshots.** A chunk touching user-visible code returns published image URLs in its report,
captured the one sanctioned way: **a throwaway Playwright script against a temporary harness
seeded with mock data** — never `agent-browser`, never the browser MCP tools or in-app browser
pane, never a preview deploy. `implementer-prompt.md` spells out why and how; your job is to not
accept less. A UI chunk that reports no screenshots and no explicit `un-capturable:` reason is an
incomplete chunk — send it back rather than carrying the gap into the PR.

### 5. Open the PR

Once the last chunk reports green, open the PR yourself — into the base branch, with
`Closes #<n>` in the body. No implementer agent has the whole picture; you do, from the plan and
the handoff documents. The body should cover what changed and why, chunk by chunk, how it was
verified (the results the agents actually observed, not "tests pass"), the screenshots from every
chunk that produced them, and anything deliberately left out or deviated from.

Embed images as `![alt](url)` and video as a raw `<video src="url" controls width="640">` tag on
its own line. If a UI chunk came back `un-capturable:`, carry that reason into the body — a
reviewer should never have to guess whether the shots were skipped or impossible.

Do not merge it, and do not post `@codex review` here — step 7 does that.

### 6. Sync check

Before review, run `scripts/pr-status.sh <pr>`:

- **conflict** → spawn a rebase agent (prefer `sonnet` when selectable) in the worktree:
  `git fetch origin`, hard-reset
  to `origin/<branch>`, rebase onto `origin/<base>`. Resolve conflicts preserving the intent of
  both sides; re-run every verification command; force-push `--force-with-lease`. If a hunk is
  genuinely ambiguous — both sides changed the same contract incompatibly — `git rebase --abort`
  and escalate to the user. Never force-push a guess to turn a PR green.
- **needsRebase** without conflict → same agent, expecting a clean rebase.
- **red** → spawn a fix agent (prefer `sonnet` when selectable): reproduce the failing checks in
  the worktree, fix the root cause, never weaken tests.
- **pending** → wait; re-check rather than proceeding.
- **green** → step 7.

### 7. Codex review

`scripts/codex-wait.sh request <pr>` (exit 5 = already requested for this head commit, fine),
then run `scripts/codex-wait.sh watch <pr>` through Bash with **`run_in_background: true`** and
end your turn. Its completion notification re-invokes you. Never run `watch` in the foreground —
it blocks for up to 15 minutes.

Exit 4 means it timed out with codex still silent. **Confirm that before believing it** — check
the bot's PR reviews *and* its issue comments for a `**Reviewed commit:**` line matching head,
since a verdict that arrived in an unexpected shape is indistinguishable from silence at the
script's level. If it really is silent, say so and hand back to the user; do not re-trigger on a
loop.

### 8. Resolve — resolver agent

With the review settled, run `scripts/codex-wait.sh findings <pr>` and spawn a fresh resolver
agent, using `opus` when model selection is available, given `resolver-prompt.md` with the
findings inline — and with
`{{ISSUE_STATED_COMMANDS}}` filled, exactly as the implementers got it. A resolver that only
knows the root commands can fix app-local code and report it verified without ever running the
gate the issue asked for. It fixes what is right, rebuts what is wrong with evidence, defers what
is out of scope, verifies, pushes, and posts a round summary.

Its push moves head, so codex will read as `not-requested` again. **Return to step 6** — that is
intended: each round gets a review of the code it is actually judging.

**Max 2 resolve rounds.** Count them by the `(resolver, round N)` marker, and look for it in
**both** the PR's issue comments and its review-comment replies — a resolver answering a finding
in its own thread is doing the right thing, but that reply never appears in
`gh pr view --json comments`, so a count that reads only there sees zero rounds and blows the cap.
`codex-wait.sh findings` also reports `replyCount` per finding for the same purpose. At the cap,
stop and hand the PR to the user with what is
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
- Follow the runtime adapter for agent waiting and resumption. Never assume completion
  notifications re-invoke the parent unless the active runtime explicitly guarantees it.
- If reality contradicts expectations (PR closed by hand, branch diverged, issue reassigned),
  report it and prefer doing less over guessing.
