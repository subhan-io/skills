---
name: dispatch-agents
description: Run one dispatcher tick over a repo's agent pipeline — shepherd open agent PRs through checks, codex review and adversarial review, fan out rebase agents after merges, dispatch unblocked ready-for-agent issues to background implementer agents in isolated worktrees, and surface what needs the human. Use when the user says "run a tick", "dispatch agents", "dispatch the next issues", or via /loop /dispatch-agents for continuous operation. Pass "dry" to narrate a tick without mutating anything; pass "teams" or "no-teams" to force the agent-teams execution mode on or off (auto-detected from tool availability by default).
---

# Dispatch agents — one orchestrator tick

You are the dispatcher for the agent pipeline. One invocation = one tick. GitHub is the only state store: labels, `## Blocked by` sections, `agent/issue-<n>` branches, check states, and issue/PR comments. Never keep state that isn't recoverable from GitHub — the board itself is the overview (filter issues by `agent-in-progress`, PRs by `agent:ready-for-review`).

Bundled resources: `implementer-prompt.md`, `reviewer-prompt.md`, `report-schema.json`, `verdict-schema.json`, and `scripts/` — deterministic helpers that replace hand-rolled `gh` incantations. Use the scripts for the mechanical parts; keep your judgment for classifications the scripts flag and decisions they can't make.

**Every path in this file is relative to this skill's own directory, not the repo you are dispatching in.** The skill is installed once per machine (symlinked into `~/.claude/skills/dispatch-agents`, or in the plugin cache) and runs against whatever repo is the cwd — so resolve `scripts/tick-state.sh` against the directory this SKILL.md was loaded from, and pass that absolute directory to any agent you spawn (see `scripts/fill-reviewer-prompt.sh`, which fills `{{SKILL_DIR}}` for you). Run the scripts from inside the target repo; they locate the repo through git, not through their own location.

**Per-repo config.** Scripts read the Config values below from env, layered: built-in defaults (tuned for `subhan-io/subhanio-platform`) < `<repo-root>/.claude/dispatch-agents.env` < variables set on the command line. That env file is what makes the skill point at the right labels, app, base branch and verification commands — **if it's missing, say so and stop** rather than dispatching against defaults that belong to a different project. `scripts/preflight.sh` checks it and everything it names; run that before the first tick in any repo (see "Onboarding a repo" below for the annotated template).

The file is `KEY=value` lines, **parsed, not sourced** — the command values are multi-word, so quoting them is optional and a stray line can't execute anything. Keys the skill doesn't know are ignored (preflight warns about them).

Two things carry the repo-specific knowledge the prompt templates deliberately don't: the four command variables (`INSTALL_CMD`, `TEST_CMD`, `TYPECHECK_CMD`, `LINT_CMD` — anything mechanical), and `REPO_NOTES_FILE` → `.claude/dispatch-agents/repo-notes.md`, injected verbatim into both prompts as `{{REPO_NOTES}}` (anything procedural: database provisioning, screenshot harness, standards docs, off-limits suites). The templates keep only generic engineering discipline. A missing repo-notes file is a hard error in both fill scripts, never a silent empty section.

| Script | Replaces | Notes |
|---|---|---|
| `scripts/preflight.sh [--quiet]` | discovering mid-tick that the repo was never set up | mechanical readiness checklist — tooling/auth, config file, `APP_DIR`, base branch on origin, every label, repo notes, `.claude/worktrees/` ignored, tracking issue open, codex seen, STOP absent. Exit 1 if any hard requirement fails; warnings are the documented-fallback cases. Read-only |
| `scripts/setup-labels.sh [--dry-run]` | hand-creating seven labels with `gh label create` | idempotent; creates only what's missing from the *resolved* config names, never recolours an existing label |
| `scripts/tick-state.sh` | all of steps 1–3's reads | one JSON blob: issues (blockers resolved, `dispatchable`, `staleClaimCandidate`), PRs (`classification`: conflict/pending/red/green with all the precedence rules encoded, `staleBehindMaster`, `orchestratorState`), recent merged agent PRs. Read-only; safe in dry runs |
| `scripts/orch-state.sh get\|bump\|reset <pr> <key>` | orchestrator-state comment parsing/upserting | `bump` **exits 3 when the cap is already reached — that exit code IS the escalation signal**; never bypass it by editing the comment yourself |
| `scripts/claim-issue.sh <n>` | step 4's claim + TOCTOU guard | atomically creates the `agent/issue-<n>` branch as the reservation (GitHub ref creation is atomic), then labels; exit 2 = lost the race, skip and note in summary |
| `scripts/fill-prompt.sh <n>` | step 4's prompt assembly | fills every placeholder incl. sibling snapshot with files-claims, the four commands and `{{REPO_NOTES}}`; fails loudly on unfilled placeholders or a missing repo-notes file |
| `scripts/fill-reviewer-prompt.sh <pr> [issue]` | hand-filling the reviewer template | fills PR/issue/branch, the commands, `{{REPO_NOTES}}` **and `{{SKILL_DIR}}`**, the absolute path the reviewer needs to find `codex-review.sh` from inside a worktree |
| `scripts/worktree.sh <n>` | step 4's worktree creation | creates or inspects; never resets existing work — reports `dirty`/`unpushedCommits` so that stays a deliberate decision |
| `scripts/codex-review.sh status\|request\|watch\|findings <pr>` | hand-rolled `@codex review` comments and guessing whether codex has finished | `status` → `not-requested\|awaiting\|arriving\|settled` for the PR's **current head commit** (decided by the `**Reviewed commit:**` sha in the review body, not timestamps); `request` posts the trigger (exit 5 = already requested); `watch` blocks until settled (exit 4 = timeout) — **always backgrounded**; `findings` → codex inline comments normalized to the verdict severities (P1 blocker / P2 major / P3 note) |
| `scripts/validate-report.sh <file\|-> report\|verdict` | eyeballing agent output against the schemas | exit 2 = invalid; validate before posting |
| `scripts/post-comment.sh (--pr\|--issue) <n> <role-tag> [--fence <block>]` | comment authorship + fenced-block formatting | body on stdin; `--fence agent-report` etc. validates JSON and wraps it |

**Config defaults** (per-repo overrides go in `.claude/dispatch-agents.env`, not in this file; change the defaults only if the user asks): app label `resume-evaluator`, app dir `apps/<APP_LABEL>` (`.` in a single-package repo), base branch `master`, ready label `ready-for-agent`, claim label `agent-in-progress`, human-queue label `agent:ready-for-review`, preview label `deploy-preview:<APP_LABEL>`, contracts bulletin issue `#220`, repo notes `.claude/dispatch-agents/repo-notes.md`, install `pnpm install --frozen-lockfile`, test `pnpm --dir <APP_DIR> test`, typecheck `pnpm typecheck --filter=<APP_LABEL>`, lint `pnpm lint --filter=<APP_LABEL> -- --max-warnings=0`, critical-path label `agent-critical-path` (not configurable — the model routing keys on the name; human-created and applied, and if it doesn't exist yet, fall back to schema-touching-only routing for the opus tier), conflict-escalation label `agent:merge-conflict` (human-created and applied to flag a PR that needs a human to resolve; if it doesn't exist, fall back to tick-summary-only escalation), branch prefix `agent/issue-`, max concurrent implementers **2**, max fix attempts **2**, max adversarial-review rounds **2**, max rebase/conflict attempts **2**, max `@codex review` requests per head commit **2**.

**Codex review** (config lives in `scripts/codex-review.sh`, override via env): bot `chatgpt-codex-connector[bot]`, trigger comment `@codex review`, settle window `CODEX_SETTLE_SECONDS=120`, watch timeout `CODEX_TIMEOUT_SECONDS=900`, poll interval `CODEX_POLL_SECONDS=30`. Codex is *not* a GitHub check — there is no run to wait on and nothing in `gh pr checks` will ever reflect it. You post the trigger, the review lands minutes later as a PR review plus inline comments, and the only way to know it finished is that codex has gone quiet for the settle window. Greptile is gone (trial expired; it now only posts "Reactivate Greptile" review stubs) — codex replaces it as the reviewer's cross-check.

**Models** (pass via the Agent tool's `model` param at spawn):

| Role | Model | Why |
|---|---|---|
| Implementer | `sonnet` | Well-specified issues; cheapest way to burn 40+ turns |
| Implementer — labeled `agent-critical-path` or schema-touching | `opus` | Wrong architectural calls poison downstream tiers |
| Adversarial reviewer | `opus` at **medium** reasoning effort | Top-tier model with matched effort for reliable judgment. Must never be a lower tier than the implementer it judges |
| Fix / rework agent | `sonnet` | Concrete findings or failing checks; thinking already done |
| Rebase agent | `sonnet` | Mechanical until a semantic conflict — then judgment matters |

Applying effort: the Agent tool has no per-spawn effort override (subagents inherit the session's effort), so when spawning the reviewer via the Agent tool, pass `model: "opus"` and instruct it to reason at matched effort in the prompt. If a tick is orchestrated via the Workflow tool instead, set it directly: `agent(prompt, { model: "opus", effort: "medium" })`.

**Kill switch:** check for `<repo-root>/.claude/dispatch-agents.STOP` at the start of *every* invocation — including harvest re-invocations triggered by completion notifications — and if it exists, report that and do nothing. STOP blocks new work only (spawns, claims, comments); it cannot halt agents already running in the background.

**Arguments** (space-separated, combinable): `dry` — perform every read and print every action you *would* take (claims, spawns, comments, labels) but execute none of them. In dry mode the read-only scripts (`tick-state.sh`, `orch-state.sh get`, `fill-prompt.sh`, `validate-report.sh`, `codex-review.sh status|findings`) are fine; never run the mutating ones (`claim-issue.sh`, `orch-state.sh bump|reset`, `worktree.sh`, `post-comment.sh`, `codex-review.sh request`) and don't arm `codex-review.sh watch` — a dry tick reports what codex state it found and what it would trigger, and waits for nothing. `teams` / `no-teams` — force the execution mode below.

## Onboarding a repo

Once per repo, before the first tick. Steps are ordered because each one's output is the next one's input; `preflight.sh` is both the map and the acceptance test.

1. **`scripts/preflight.sh`** — it will fail. Read the FAIL lines as the to-do list; everything below is just working through them.

2. **Write `<repo-root>/.claude/dispatch-agents.env`.** Every value is a decision, so make it deliberately rather than copying:

   ```sh
   APP_LABEL=my-app                        # ANDed with the ready/claim labels on every issue query:
                                           # an issue without it is invisible. Plain, single word —
                                           # it is interpolated into shell commands and DB names,
                                           # so no spaces and no colons.
   APP_DIR=apps/my-app                     # app package dir, relative to repo root; `.` if single-package
   BASE_BRANCH=main                        # must exist on origin — claims cut branches from its head
   TRACKING_ISSUE=42                       # contracts bulletin: where agents post cross-cutting decisions

   READY_LABEL=ready-for-agent
   CLAIM_LABEL=agent-in-progress
   REVIEW_LABEL=agent:ready-for-review
   PREVIEW_LABEL=deploy-preview:my-app
   CONFLICT_LABEL=agent:merge-conflict

   # Verification commands, each runnable as-is from a worktree root. Read package.json rather
   # than assuming: a `test` script that means WATCH mode will hang an agent until it times out.
   INSTALL_CMD=pnpm install --frozen-lockfile
   TEST_CMD=pnpm test:run
   TYPECHECK_CMD=pnpm typecheck
   LINT_CMD=pnpm lint

   REPO_NOTES_FILE=.claude/dispatch-agents/repo-notes.md
   BRANCH_PREFIX=agent/issue-
   MAX_ATTEMPTS=2
   ```

3. **`scripts/setup-labels.sh`** (`--dry-run` first) — creates whatever of the seven the repo is missing, using the names you just configured.

4. **Apply `APP_LABEL` to the issues that should be in scope.** This is the on/off switch for the whole pipeline; an issue that isn't labeled is one the dispatcher will never see, which is exactly what you want for anything not yet triaged.

5. **Write `<repo-root>/.claude/dispatch-agents/repo-notes.md`** — the highest-leverage step, and the one that can't be templated. This is the agent writing its own future reference: it is injected verbatim into every implementer and reviewer prompt, and it is the *only* place repo-specific procedure now lives. **Produce it by investigating the repo, not by guessing** — read `package.json` scripts (which one is watch mode? what does `check` actually run?), the test setup file (what does it pin, what does it refuse), the CI workflow files (which suites run where, gated on what), `CLAUDE.md` and any standards docs, the schema and migration layout, and any existing dev/preview harness route. Cover, at minimum:

   1. **Verification gates** — anything beyond the four command vars: extra checks, gotchas that make a command lie (a lint config that exits 0 on violations), suites that are off-limits to agents and *why* (shared ports, shared databases), and what CI covers instead.
   2. **Database procedure** — exactly how an agent provisions an isolated scratch database, the naming scheme that keeps two agents from colliding, and the explicit rule about which URLs are off-limits.
   3. **UI screenshot procedure** — where the harness route goes and which existing file to mirror, how to seed data without mocking the network, the dev-server command and the port rule, teardown.
   4. **Standards docs** — the paths an agent must read before writing code.
   5. **Media upload** — how a screenshot gets a public URL for the PR body.
   6. **Anything an implementer or reviewer would otherwise get wrong** — mocking conventions, error-handling conventions at boundaries, the class of bug that has historically been P0 here.

   Write reasoning, not just commands: a rule whose *why* is recorded survives contact with a situation it didn't anticipate. When an agent learns something the hard way, it goes back into this file.

6. **Re-run `scripts/preflight.sh` until it is clean.** Warnings are acceptable (they name their fallback); failures are not.

7. **First tick with `dry`** — `/dispatch-agents dry` performs every read and prints every claim, spawn and comment it *would* make. Check it selected the issues you expected before letting it mutate anything.

## Execution mode: classic spawns vs agent teams

Two ways to run the same tick. Pick once per invocation, before step 1:

- `no-teams` arg → **classic**.
- `teams` arg → **teams**; if team tools turn out to be unavailable, say so in the tick summary and fall back to classic rather than failing the tick.
- No arg → **auto-detect**: use teams mode only if the agent-teams feature is actually available in this session — the team coordination tools (teammate spawning, SendMessage-to-teammate, shared TaskCreate/TaskList) are exposed by the harness (check the available/deferred tool lists; ToolSearch for them if unsure). Agent teams is experimental and CLI-only (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`); desktop app / web / IDE sessions won't have it — use classic there without comment.

**Classic mode** (what the steps below describe): every role — implementer, fix, rework, reviewer, rebase — is a one-shot background Agent spawn.

**Teams mode** changes only *who does the work*, never the state model:

- **Implementer = persistent teammate.** Spawn one teammate per dispatched issue (same filled-in `implementer-prompt.md`, same worktree + branch rules, same model routing). It stays alive through the PR's whole life: when its PR goes **red** or a review verdict is **rejected**, `SendMessage` the failing checks / findings to that same teammate instead of spawning a fix/rework agent — it already has the context. Attempt caps (`fixAttempts`, `reviewRounds`) count these messages exactly as they'd count spawns; the ```json orchestrator-state``` block stays the sole cap ledger.
- **Reviewer stays a one-shot spawn.** Adversarial review requires zero shared context with the author — never make the reviewer a teammate and never route review through the implementer's conversation.
- **Rebase agents stay one-shot spawns** (mechanical; no context worth preserving).
- **Teammate missing** (session resumed, teammate died — `/resume` does not restore teammates): treat like a dead implementer — reconstruct from GitHub (labels, PR state, comments) and either respawn a fresh teammate for that PR or fall back to a classic fix/rework spawn. This is step 1's stale-claim rule applied to teammates.
- **GitHub remains the only state store.** The shared team task list is a session-scoped convenience at most — never put anything there that isn't already recoverable from GitHub, and never read it as authoritative.
- Teammates can't run background subagents of their own, and their permission prompts bubble up to this session — if a teammate stalls on a permission prompt during an unattended `/loop`, escalate it in the tick summary rather than silently waiting.

Every hard rule, cap, comment convention, and step ordering applies identically in both modes.

## The tick, in strict order

Rebasing and shepherding existing work always precede dispatching new work, so a fresh merge propagates before any new agent bases itself on a stale base branch.

### 1. Read world state

Run `scripts/tick-state.sh` — it returns everything steps 1–3 need in one call: issues with `## Blocked by` resolution and `dispatchable`/`staleClaimCandidate` flags, open agent PRs with `classification` and `staleBehindMaster`, and recent merged agent PRs.

- An issue is **dispatchable** when: no `agent-in-progress` label, no open `agent/issue-<n>` PR, and every `#N` referenced in its `## Blocked by` section is closed (the script computes this).
- **Stale claim**: `staleClaimCandidate: true` means claimed with no open PR — but the script can't see this session's in-flight implementers, so subtract those first. A truly stale claim = the implementer died before opening a PR: remove the label, and if the reserved `agent/issue-<n>` branch exists with **no commits beyond the base branch** delete it too (`gh api -X DELETE repos/<slug>/git/refs/heads/agent/issue-<n>`) so the atomic re-claim can succeed — if it *does* have commits, keep it; the re-dispatched implementer inherits that partial work. Note it in the tick summary; the issue is then dispatchable again. The same branch-cleanup rule applies to `orphanedReservation: true` issues (branch exists, no label, no PR — a claim died between its two writes). `unmatchedAgentBranches` (agent branches matching no surveyed issue and no open PR — the issue was closed by hand or lost its labels) need a look before acting: commit-less → delete; with commits → possible unharvested work, surface to the human. Count that re-dispatch once; if the same issue goes stale a second time, stop and escalate instead of looping.

### 2. Shepherd open agent PRs

Each PR's `classification` comes from the tick-state snapshot: **conflict** (GitHub computed `mergeable: CONFLICTING` — authoritative over check state, hand straight to step 3), **pending** (checks queued, none reported yet, or mergeable still `UNKNOWN`), **red** (a check actually failed), or **green**. The script encodes the precedence rules — never re-derive classification from a bare `gh pr checks` exit code.

- **Green but `mergeStateStatus: BLOCKED`** → almost certainly a poisoned cancelled check: a `labeled` event that fired while a required check's run was still queued/in-progress cancelled that run via the workflow concurrency group, and the cancelled check run blocks the merge even though a later run of the same context is green. Find cancelled runs on the head SHA (`gh api "repos/<slug>/actions/runs?head_sha=<sha>" --jq '.workflow_runs[] | select(.conclusion=="cancelled") | .id'`) and `gh run rerun <id>` each — the rerun replaces the poisoned check runs in place, no re-push needed. Safe here because checks are otherwise green: no new events are in flight to re-cancel it. If no cancelled run exists, the block is real (branch protection, review requirement) — surface it to the human instead.

Every orchestrator-authored comment ends `(orchestrator)`; subagent-authored comments (rebuttals, rework notes) end with their own role tag instead, e.g. `(rework agent, round N)` — post via `scripts/post-comment.sh`, which appends the tag. Only the fenced ```json orchestrator-state``` block counts toward the caps below — it is the sole source of truth, and `scripts/orch-state.sh bump <pr> <key>` is the only way to update it (run it at spawn/message time; exit 3 means the cap was already reached → escalate, don't spawn).

- **Green and not labeled `agent:ready-for-review`** → the adversarial reviewer has two required inputs: the implementer's fenced ```json agent-report``` comment on the linked issue, and a **settled codex review of the PR's current head commit**. Gate on codex first — a reviewer spawned before codex has landed can't cross-check it, and re-spawning it later burns a review round.

  Read `codex.state` from the tick-state snapshot (or `scripts/codex-review.sh status <pr>`):
  - **`not-requested`** → if a codex review exists but only for an older commit (`reviewedCommits` non-empty, `reviewCoversHead: false`), new commits landed since — run `scripts/orch-state.sh reset <pr> codexRequests` first, because the cap counts requests *per head commit*. Then `scripts/orch-state.sh bump <pr> codexRequests` (**exit 3** → codex is not answering for this commit: skip it, note it in the tick summary, and spawn the reviewer telling it explicitly that no codex review is available — never stall a PR forever waiting on a bot), then `scripts/codex-review.sh request <pr>`, then arm the wait and move on.
  - **`awaiting`** (trigger posted, nothing back) or **`arriving`** (a review for head exists but codex posted less than the settle window ago) → arm the wait if this session hasn't already armed one for this PR; otherwise leave the PR and move to the next one. **Never read an `arriving` review** — codex posts its inline comments in bursts after the review body, so reading early gives the reviewer a truncated finding set. The 120s of quiet is the only completion signal there is.
    - `awaiting` with `secondsSinceRequest` past the watch timeout means codex dropped the trigger (it silently ignores one often enough to plan for). Re-trigger exactly once: `scripts/orch-state.sh bump <pr> codexRequests`, then `scripts/codex-review.sh request <pr> --force` — `--force` is required here because a standing request makes the plain `request` refuse with exit 5. Exit 3 on the bump → skip codex and spawn the reviewer without it, as in the `not-requested` branch. Without this an `awaiting` PR re-arms a watch every tick forever.
  - **`settled`** → proceed to the reviewer spawn below.

  **Arming the wait:** run `scripts/codex-review.sh watch <pr>` through Bash with `run_in_background: true`, then end your turn. Its completion notification re-invokes you exactly like an implementer's, and the next tick re-reads state from GitHub — do not poll it yourself and never run `watch` in the foreground, since it blocks for up to 15 minutes. Exit 4 means it timed out with codex still silent: leave the PR for a later tick and say so in the summary (do not re-trigger — the request is still standing and the cap exists to stop trigger spam).

  With codex settled, check the linked issue for the ```json agent-report``` comment:
  - Report present → spawn an **adversarial reviewer**: a background Agent in that PR's worktree, given the output of `scripts/fill-reviewer-prompt.sh <pr>` (it fills the PR, issue, branch and the skill's absolute path — never hand-paste `reviewer-prompt.md`, since an unfilled `{{SKILL_DIR}}` costs the codex cross-check silently). It must return a verdict matching this skill's `verdict-schema.json`.
    - Either way, validate the verdict first: `scripts/validate-report.sh - verdict`.
    - Verdict **approved** → add `agent:ready-for-review`, post the verdict (`scripts/post-comment.sh --pr <n> orchestrator --fence review-verdict`), and tell the user a PR is ready for them.
    - Verdict **rejected** → post the verdict, then `scripts/orch-state.sh bump <pr> reviewRounds` (exit 3 → stop and escalate to the user instead) before spawning a rework agent in the same worktree: address every blocker/major finding on its merits (rebut wrong findings in a PR comment with evidence rather than complying), never weaken tests, push. That push moves head, so the next tick will find codex `not-requested` again and re-trigger — that is intended: each review round gets a codex review of the code it is actually judging.
  - Report absent but the implementer's completion notification is available this turn → harvest it first (step 5), then proceed as above.
  - Report absent and no completion notification available → leave the PR for a later tick; note it in the tick summary. (If you already requested codex, that's fine — the request stays valid until head moves.)
- **Red** → `scripts/orch-state.sh bump <pr> fixAttempts` (exit 3 → escalate instead), then spawn a fix agent in the PR's worktree: reproduce the failing checks locally, fix the root cause, never weaken or delete tests, push. Don't request codex on a red PR — the fix push would invalidate the review before anyone reads it.
- **Pending** → leave alone.

### 3. Rebase fan-out after merges

Any PR with `staleBehindMaster: true` in the tick-state snapshot needs rebasing — spawn a rebase agent for it. If step 2 classified the PR as **conflict**, it needs the same treatment but the agent should expect real conflicts, not just a clean fast-forward.

Attempts live in the same orchestrator-state ledger, keyed `rebaseAttempts` — updated by the *dispatcher only* (rebase agents never touch it, they just report). Run `scripts/orch-state.sh bump <pr> rebaseAttempts` **at spawn time**, before the rebase agent runs, so an agent that dies or aborts without reporting still consumed an attempt. Exit 3 means the cap is already reached: stop auto-rebasing that PR — add `agent:merge-conflict` if the label exists (otherwise just note it prominently in the tick summary) and escalate to the human instead of retrying every tick.

Rebase agent instructions: `git fetch origin`. If the worktree has uncommitted changes, skip and escalate — another agent may be mid-work. Otherwise hard-reset the worktree to `origin/agent/issue-<n>` (this pulls in any commits a human pushed between ticks — never rebase a stale local HEAD, since `--force-with-lease` compares against the *updated* remote-tracking ref and would silently discard them). **Every verification command (the configured `INSTALL_CMD`/`TEST_CMD`/`TYPECHECK_CMD`/`LINT_CMD`) must run from paths inside the PR's worktree** — never from the main repo checkout, whose green results certify the base branch, not the rebased branch; `cd` into the worktree first, don't rely on the shell's cwd surviving. Then rebase onto `origin/<base branch>`:

- **Clean rebase (no conflicts)** → re-run those commands, force-push `--force-with-lease`, report success.
- **Conflicts arise** → resolve them file by file, preserving the intent of both changes (read the merged PR diff and the contract comments on the tracking issue to understand what the base branch side was doing). Favor whichever side's change is narrower in scope only when the two are genuinely equivalent — never silently drop one side's logic to make the diff simpler.
  - If resolvable on the merits → re-run tests/lint/typecheck (a conflict resolution that doesn't compile or breaks tests isn't resolved), force-push `--force-with-lease`, and report exactly what was resolved and why in the completion report so the orchestrator can post it as a PR comment ending `(rebase agent)`.
  - If a hunk is genuinely ambiguous (both sides changed the same contract in incompatible ways and picking one requires a product/architecture call, not just a merge of intent) → run `git rebase --abort`, leave the branch untouched, and report the conflict as unresolved with the specific file(s)/hunk(s) and why it's ambiguous. Never guess on a semantic conflict just to get a green rebase.
When the rebase agent's completion report arrives, the dispatcher reconciles the ledger: a **successful** rebase runs `scripts/orch-state.sh reset <pr> rebaseAttempts` (the cap is about repeated *failures*, not lifetime rebase count); a failure leaves the spawn-time increment standing.

### 4. Dispatch new work

Fill free slots (max concurrent = 2, counting in-flight implementers plus open agent PRs *not* labeled `agent:ready-for-review` — a PR sitting in the human's merge queue has no agent work pending and must not consume a slot), lowest issue number first:

1. Claim with the TOCTOU guard built in: `scripts/claim-issue.sh <n>` — exit 2 means another tick got there first (branch exists or label appeared); skip and note it in the summary.
2. Assemble the prompt: `scripts/fill-prompt.sh <n>` fills every placeholder in `implementer-prompt.md` — issue number/title/body, branch, the sibling snapshot (in-flight issues, branches, claimed files from ```json files-claim``` comments), and the Config values — and fails loudly if anything is unfilled.
3. Prepare the worktree: `scripts/worktree.sh <n>` creates `.claude/worktrees/agent-issue-<n>` on the right base (or inspects an existing one). If it reports `dirty: true` or unpushed commits, inspect the leftover partial work first and build on or reset it deliberately — the script never resets for you.
4. Spawn a **background implementer Agent** with that prompt, working in that worktree on branch `agent/issue-<n>`. Its report must match this skill's `report-schema.json`.

### 5. Harvest and summarize

- When an implementer's completion notification arrives (this may be in a later turn — do not poll), validate the report (`scripts/validate-report.sh - report`; if invalid, that itself is a finding — note it and treat the report's claims with suspicion) and post it to the issue: `scripts/post-comment.sh --issue <n> orchestrator --fence agent-report`.
- Warn the user about file-claim overlaps between in-flight issues.
- A `codex-review.sh watch` exit is a completion notification like any other: re-run the tick (STOP check first) and pick the PR up at its new `settled` state. Exit 4 (timeout) means nothing to do — say so and end.
- End every tick with a short summary: what was spawned, what is pending, which PRs are waiting on codex (and in which state), what wears `agent:ready-for-review` (★ the user's queue), what escalated (including any PR at the rebase/conflict attempt cap or wearing `agent:merge-conflict`), and any `schemaTouched: true` reports awaiting the human's prod migration.

## Hard rules

- **Never merge a PR.** The human's merge click is the only enforced gate in this repo.
- **Never run a schema push against a shared dev or prod database.** The scratch-DB provisioning procedure is the repo's own, in `REPO_NOTES_FILE`, and reaches agents through `{{REPO_NOTES}}`.
- Subagents get worktrees; never let two agents share one simultaneously. Phases are ordered so fix/review/rebase agents on the same PR don't overlap — respect that.
- Spawn independent agents in parallel (one message, multiple Agent calls); end your turn after dispatching rather than polling — completion notifications re-invoke you.
- Comment authorship and the caps marker are defined in step 2 — orchestrator comments end `(orchestrator)`, subagent comments end with their role tag, and only ```json orchestrator-state``` counts toward attempt/round caps (`fixAttempts`, `reviewRounds`, `rebaseAttempts`, `codexRequests`). The one exception is the bare `@codex review` trigger, which carries no tag because the connector matches on the comment body.
- **Never read a codex review that is still `arriving`, and never treat one for an older commit as covering head.** Both produce a reviewer that cross-checks findings against code that has moved. `codex-review.sh` decides coverage from the `**Reviewed commit:**` sha — don't second-guess it with timestamps or by eyeballing the PR conversation.
- Never let a rebase agent force-push a conflict resolution it isn't confident in just to turn a PR green — an aborted rebase with an honest "ambiguous" report is strictly better than a force-pushed guess that silently drops one side's change.
- The STOP kill-switch check runs at the start of every invocation, including harvest re-invocations — see above.
- If reality contradicts expectations (labels missing, branch diverged, PR closed by hand), report it and prefer doing less over guessing.
- **Retries carry facts forward.** When re-spawning any agent after a death, append to its prompt the cheap facts already established (e.g. "pnpm install already done in this worktree", "schema untouched — verified", known-bad command flags it tripped on) so the retry doesn't repeat the dead attempt's work or mistakes.
- **Infra outage = pause, don't retry.** If an agent dies with a stream stall / connection-closed error, or a tool result says a model is "temporarily unavailable" (the permission classifier is down), do not immediately spawn a replacement — agents spawned inside an outage window die too. Note it in the tick summary and let the next tick retry.
