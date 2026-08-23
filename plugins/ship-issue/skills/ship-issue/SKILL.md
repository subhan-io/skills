---
name: ship-issue
description: >-
  Take ONE named GitHub issue end to end in a fresh worktree — confirm the issue's acceptance
  criteria with the human, build a Codex repository brief, plan it with Claude Opus and a visual
  HTML explainer, stop for the human's approval, alternate implementation chunks between Codex
  and Claude Sonnet, open a PR, run Codex review, and resolve findings with Claude Opus — leaving
  a green PR for the human to merge. Use when the user points at a specific issue and wants it
  carried to a mergeable PR: "take issue 12 end to end", "ship this issue", "plan and implement
  this issue URL", "get this ready for me to merge". For the unattended multi-issue pipeline that
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
| `scripts/run-agent.sh ...` | selects Claude or Codex, applies its sandbox, validates the structured report, records usage, and prints one small run record |
| `scripts/engine-policy.sh` | static role routing: Codex brief/fix/rebase, Claude plan/resolve, alternating chunks |
| `scripts/pr-status.sh <pr>` | the between-steps snapshot: `classification` (conflict/pending/red/green), `behindBase`, `needsRebase`, codex state |
| `scripts/codex-wait.sh status\|request\|watch\|findings <pr>` | drives the Codex review; `watch` blocks until settled — **always background it** |

Alongside the scripts are role prompts, schemas under `schemas/`, and
`explainer-skeleton.html`, the HTML shell the planner fills at the approval gate.

**Routing is policy, not a model decision.** `engine-policy.sh` chooses the default engine and
Claude model. Never reproduce the map in an ad-hoc invocation or choose an engine from task vibes:

| Role | Default |
|---|---|
| repository brief | Codex, read-only, network off |
| planner | Claude Opus |
| implementer chunk 1, 3, 5… | Codex, workspace-write, network on |
| implementer chunk 2, 4, 6… | Claude Sonnet |
| fixer / rebaser | Codex, workspace-write, network on |
| resolver | Claude Opus |

An explicit `--engine` or `SHIP_ISSUE_ENGINE` override exists for the human, not for the
orchestrator to improvise with. Codex uses the installed CLI's default model. UI chunks follow the
same alternation: Codex runs on the same machine and has the same Playwright and upload tooling.

**Agent count is not fixed.** The planner decides it: one subprocess per chunk it returns, plus
whatever rebase/fix subprocesses the sync check calls for. A five-chunk plan is five implementers,
sequentially.

### Subprocess contract

Every routed role is invoked through `scripts/run-agent.sh`, using a filled prompt file and the
matching schema. Start it with the host shell tool's background/long-running-process support so a
30-minute agent does not block the orchestrator process. The runner writes raw output to a log,
writes the full role report to `--out`, appends `<stateDir>/engine-ledger.json`, and prints one
small JSON run record.

The gate is mechanical:

- `reportValid` must be `true` before the report file is read.
- Exit `65` / `status:"invalid-report"` means the model returned the wrong shape. Stop.
- Exit `124` / `status:"timed-out"` means the whole engine call timed out. Stop.
- A non-zero engine failure is a stop, except a Claude rate limit on implementer/fixer/rebaser,
  which the runner retries once on Codex and records in `failover`.
- A valid report can still say `blocked`, `stopped`, `plan-wrong`, or `escalate`; do not advance
  merely because its JSON is valid.

`run-agent.sh` gives every Codex writer `workspace-write`, network access, and `--add-dir` for the
state directory. Before either engine starts, it temporarily creates each missing colocated
`AGENTS.md -> CLAUDE.md` or `CLAUDE.md -> AGENTS.md` compatibility link. If both exist it skips
the directory. The links are hidden from child Git commands and removed after the call.

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
  than inside it, so nothing written there can reach the PR diff. The plan explainer, the
  approved plan and every chunk handoff live here.

**Read files from the worktree, never from the main checkout.** They are different commits: the
worktree is cut from `origin/<base>`, while the main checkout is wherever the human left it and is
routinely behind. A `package.json` read from the wrong one describes a toolchain that no longer
exists, and every agent you brief inherits the error.

A warning about `pr-media-upload` (missing plugin, or `infisical`/`aws` not on `PATH`) matters
twice. Always: it is how the plan explainer gets a URL the human can open from another device —
this skill usually runs on a remote box, so a file path on it is not something they can read.
And if the issue touches UI: it is where screenshots get published, and discovering that at the
publish step wastes a whole capture. Raise it before planning. The human either installs the
prerequisites, or accepts reading the explainer off the box themselves and UI chunks reporting
their shots un-capturable.

### 2. Confirm the criteria, build the brief, then plan

**Before running the brief or planner, confirm the ask with the user.** Planning is the expensive step,
and a plan built on criteria the human never meant is the expensive step wasted. From the issue
body (already in the setup blob), extract the ask in one sentence and the acceptance criteria
**verbatim** — plus `issueStatedCommands`, since those are usually criteria too — and put them to
the user: are these the right criteria, and are any missing or wrong? If the issue names no
criteria, propose the list you would plan against and ask the same question. This is a cheap
text exchange, not an artifact — do not read the codebase for it, and do not let it grow into
pre-planning. If the user already confirmed the criteria in this conversation (or told you to
skip the check), don't re-ask.

Fill `repo-brief-prompt.md` from the setup blob and criteria notes, and write it to
`<stateDir>/repo-brief.prompt.md`. Start this through the host's background shell support:

```bash
scripts/run-agent.sh --role repo-brief \
  --prompt-file <stateDir>/repo-brief.prompt.md \
  --schema <skillDir>/schemas/repo-brief-report.schema.json \
  --cwd <worktree> --state-dir <stateDir> \
  --out <stateDir>/repo-brief.report.json
```

The policy routes it to read-only Codex with network disabled. When the process ends, inspect the
small run record. Only if `reportValid:true` and the brief says `status:"ready"`, fill
`planner-prompt.md`, including `{{REPO_BRIEF_PATH}}`, every setup value, and
`{{CRITERIA_NOTES}}`. Write it to `<stateDir>/planner.prompt.md`, then run it the same way with
`--role planner`, `planner-report.schema.json`, and `<stateDir>/planner.report.json`. Policy
routes it to Claude Opus.

The planner reads the evidence brief, verifies only the facts its design depends on, and produces
**two things from one understanding**:

- the schema-checked **chunked plan** in `planner.report.json` — each chunk sized to fit one agent
  session (~200k tokens), independently verifiable, and marked `touchesUI`. This is what the
  implementers get. `touchesUI` controls screenshot enforcement, never engine routing.
- the **explainer**, `<stateDir>/plan-explainer.html` — the same plan re-told for the human who
  has to approve it: a self-contained page that opens with the ask and the confirmed acceptance
  criteria, shows the touched code with real excerpts, then **shows** each chunk — for UI work as
  static mocks built from the app's real design tokens, light and dark, with declined
  alternatives beside the planned one; otherwise as before/after code — and names what could
  break, with every decision consolidated in its endnotes. It is written in Simplified Technical
  English for a strong engineer who **knows the stack and the repo layout**: no repo tour, no
  toolchain explanation, only this code and these decisions. It is the thing the user reads.

  Where the plan genuinely cannot settle a fork, the page asks instead of assuming: the planner
  puts it in a question block beside the mocks that show the options, and a sticky **Copy Q&A**
  button copies every question and answer as plain text for the user to paste back in chat.

**Check the validated report and explainer before presenting anything.** A report that is invalid
or blocked, an explainer that is missing or still the skeleton, a non-contiguous chunk index, or
an explainer path outside the state directory is an incomplete planning step. Rerun the planner
with the validated plan and the artifact defect in its prompt; do not present half a plan.

### 3. Approval gate — HARD STOP

**Publish the explainer and put its URL first**, before any of the plan text. This skill runs
on whatever machine the user pointed it at — usually a remote box — so a path on disk is not
something they can open from their phone or laptop. Upload it with `uploadScript` from the setup
blob: `"$uploadScript" <stateDir>/plan-explainer.html` prints one line, a URL that opens as a page
in any browser (`upload.sh` serves `.html` as `text/html`). Print that URL on its own line at the
top of your message, with the path beside it. If setup found no `uploadScript`, say so and give
the path — they will have to fetch it off the box themselves. Never post the explainer to the
issue or the PR.

The URL is **public but unlisted** (random key, no auth, permanent) — which is why the planner
is told to keep secrets out of its excerpts, and why you say "unlisted, permanent" when you hand
it over rather than letting the user assume it is private.

Then present the plan's summary, the decisions it asks them to confirm, and the chunk list; the
full chunk text is there if they want it but the page is the review surface. **If the explainer
carries open questions**, say so and say how to answer: the page's sticky **Copy Q&A** button
copies every question with the chosen answer, and they paste that back here. Do not re-ask those
questions as chat prose — the whole point of putting them on the page is that the options are the
mocks. Then **wait**. Do not run the implementer or write code.
This is the whole point of the skill's interactive shape: the cheapest place to catch a wrong
approach is before anything is built — and the gate is only as good as the reading it gets, which
is what the explainer is for.

A pasted-back Q&A block is an **answer, not an approval.** Fold the answers into the plan and say
what changed. If an answer contradicts a chunk, rerun the planner with it. Then ask for the
green light.

**On approval, write the plan to `<stateDir>/plan.md` before running anything**, along with any
decisions the human made at the gate — those are part of the plan now, and a chunk agent that
re-litigates a settled question wastes a session. Until it is on disk the plan exists only in your
context: the chunks cannot cite it, a handoff that points at it is pointing at nothing, and a
resumed session has lost it. Pass the path to every agent from here on.

Do **not** post the plan to the issue instead. The issue is the spec; a chunked implementation
plan with token estimates is process ephemera that clutters it for every later reader, and
re-planning after feedback leaves two comments with no way to tell which is current.

If the user asks for changes, rerun the planner with their feedback; it rewrites the plan
**and** the explainer (overwriting `plan-explainer.html`, so the file always holds the current
plan), and you publish and present again the same way — each upload is a fresh URL, so name
the new one and say the old one is stale. Only an explicit green light moves to step 4. The
explainer stays in the state directory after approval, beside `plan.md` — a later reader of the
run, or a resumed session, gets the same briefing the approver did.

### 4. Implement — one routed subprocess per chunk

**One agent per chunk, run in order, never in parallel.** The chunks exist because each was
sized to fill a session's context; running them all in one agent spends that budget three times
over and the later chunks execute with the earlier ones evicted. A chunk boundary is a context
reset, not a comment header.

For each chunk in the approved plan, in order:

1. Fill `implementer-prompt.md` with every
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
   Write the filled prompt to `<stateDir>/chunk-N.prompt.md`, then start `run-agent.sh` in the
   background with `--role implementer --index N`, `implementer-report.schema.json`, the issue
   worktree, state directory, and `<stateDir>/chunk-N.report.json`. Odd chunks route to Codex;
   even chunks route to Claude Sonnet. Do not override the policy for UI work.
2. Wait for the run record. Check `reportValid` before reading the report. Only a report with
   `status:"green"` can advance. Then **read the handoff document it names** before running the next
   one. A path that is missing, empty, or describes a chunk that stopped early is a stop, not a
   detail.
3. Only when it reports its chunk green and pushed does the next chunk start.

Never run the next chunk over a chunk that stopped early, went red, or reported the plan wrong
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

- **conflict** → fill `rebaser-prompt.md`, then run `run-agent.sh --role rebaser` with
  `maintenance-report.schema.json`. Policy routes it to Codex. It fetches, restores the branch's
  remote tip when necessary, rebases onto `origin/<base>`, verifies, and force-pushes with lease.
  If both sides changed the same contract incompatibly, it aborts and reports `escalate`; never
  force-push a guess to turn a PR green.
- **needsRebase** without conflict → same routed rebaser, expecting a clean rebase.
- **red** → fill `fixer-prompt.md`, including the failing check evidence, then run
  `run-agent.sh --role fixer` with `maintenance-report.schema.json`. Policy routes it to Codex.
  It reproduces the failure, fixes the root cause, never weakens tests, verifies, and pushes.
- **pending** → wait; re-check rather than proceeding.
- **green** → step 7.

The rebaser/fixer report must be valid and `status:"green"` before returning to this sync check.

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

### 8. Resolve — Claude Opus subprocess

With the review settled, run `scripts/codex-wait.sh findings <pr>`, fill `resolver-prompt.md` with
the findings inline — and with
`{{ISSUE_STATED_COMMANDS}}` filled, exactly as the implementers got it. A resolver that only
knows the root commands can fix app-local code and report it verified without ever running the
gate the issue asked for. Write the prompt under the state directory, then start
`run-agent.sh --role resolver` with `resolver-report.schema.json` and a round-specific report
path. Policy routes it to Claude Opus. It fixes what is right, rebuts what is wrong with evidence,
defers what is out of scope, verifies, pushes, and posts a round summary. Require a valid report
with `status:"green"` before continuing.

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
- Start agent subprocesses with the host shell's background/long-running support. Do not run a
  long role synchronously or spin in a tight polling loop.
- If reality contradicts expectations (PR closed by hand, branch diverged, issue reassigned),
  report it and prefer doing less over guessing.
