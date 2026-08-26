---
name: ship-issue-omp
description: Ship one GitHub issue or adhoc task to a reviewed PR with native OMP agents, tools, approval gates, and durable run state.
disable-model-invocation: true
omp-only: true
---

# Ship one issue with OMP

One issue or adhoc task in, one reviewed pull request out. The human merges. OMP performs orchestration, implementation, verification, GitHub operations, and durable run accounting.

Two hard gates, in order:

1. the acceptance criteria and planning tier are confirmed;
2. the implementation plan is explicitly approved.

No code or branch mutation occurs before both gates. Ordinary repository facts do not reopen a gate. Return to the human only for a material change to acceptance criteria, scope, architecture, risk, or user-visible design.

`ship_run` is the run state machine and ledger writer. It persists state in the OMP session and appends events to `~/.local/state/ship-issue-omp/ledger.jsonl`. If the tool is unavailable, stop: the plugin extension is not loaded.

Preflight the companion skills before the criteria gate. Always read
`skill://codex-review`; for a user-visible task also read `skill://ui-evidence`
and `skill://pr-media-upload`. If a required companion is unavailable, stop and
report the exact `omp plugin install <name>@subhan-skills` command instead of
proceeding. Never replace GitHub Codex with a local reviewer, hand-written polling
or another review system, and never use a missing evidence skill as an
`un-capturable:` reason.

## 1. Read and bound the task

- GitHub issue URL or number: read it and its comments through `issue://<owner>/<repo>/<n>` when possible.
- Otherwise treat the command arguments as one adhoc task and restate it in one paragraph.
- One run ships one issue. If several unrelated outcomes are bundled, ask which one to ship first.

Inspect repository state before planning. Preserve user changes. A dirty worktree, an existing unrelated feature branch, missing GitHub authentication, or a repository mismatch is a material preflight decision; surface the concrete options instead of mutating or discarding work.

Map only enough repository surface to draft grounded criteria and choose a tier. Use one or two read-only `scout` tasks in a single native `task` batch when genuinely independent questions exist, such as implementation callsites and verification conventions. Skip scouts for a known light change. The orchestrator owns decomposition and decisions.

## 2. Confirm criteria and tier — gate

Draft a short exhaustive checklist of observable acceptance criteria. Choose a tier:

| Tier | Use when | Planning |
|---|---|---|
| **light** | At most about three files, no schema/auth change, no UI redesign | Short inline plan |
| **standard** | Everything else | Repository-grounded inline plan; visual explainer only when useful |
| **deep** | At least two of: migration; auth/payments/data deletion; crosses app boundaries; over about ten files; new subsystem | Native `ship-planner` task using the configured `@plan` role |

Use one native `ask` call with two questions: criteria confirmation and tier confirmation. Put the proposed checklist in a preview and mark the selected tier as recommended. The answer defines finished.

After approval, call:

```text
ship_run op=start task=<issue-or-summary> repo=<owner/name> tier=<tier> criteria=<approved-list>
```

## 3. Resolve plan-shaping questions

Resolve every remaining decision that changes the plan before presenting it.

- Small product or technical forks: native `ask`, with concise tradeoffs and a recommendation.
- Visual choices or context too large for a picker: use `skill://plan-explainer` when installed.
- Repository facts: investigate; do not ask the human to retrieve them.

For a user-visible task, inspect the real application and existing design tokens before proposing UI behavior.

## 4. Plan and approve — gate

Size chunks by coherent observable delivery, ownership, dependencies, and verification—not a fixed token count. Each chunk names:

- files or areas it owns;
- the observable deliverable;
- approved criteria it covers;
- one exact command or scenario the orchestrator will run to verify it.

Light and standard tiers: write the plan in this session. Deep tier: dispatch one `ship-planner` task with the issue, approved criteria, settled decisions, and targeted repository pointers. Use `schemaMode: strict`; consume its structured result from `agent://<id>`.

A plan may contain one or two chunks. More than two is a split proposal:

1. draft independently shippable child issues along verification seams;
2. preserve the approved criteria and note that criteria and approach were approved in the parent split;
3. present the split for approval;
4. on approval, create the children and turn the parent into a tracker;
5. move automation labels from the parent to unblocked children;
6. call `ship_run op=finish outcome=split children=<child-list>` and hand over.

Present the one- or two-chunk plan and wait for explicit approval. Then call:

```text
ship_run op=approve_plan planSummary=<summary> chunks=<one-or-two-chunk-list>
```

## 5. Create the working branch

After plan approval and before implementation, create or select a dedicated feature branch. Confirm it is based on the intended base branch and does not absorb unrelated user work. The pull request branch exists before any writer agent starts.

## 6. Implement with native OMP tasks

Use a fresh `ship-chunk` task for each chunk. The task context contains:

```text
# Goal
The approved task and acceptance criteria.

# Constraints
The approved plan, exact chunk boundary, no project-wide validation, UI-evidence requirements, and material decisions.

# Contract
The observable deliverable, owned areas, parent-run verification, and prior agent:// handoffs.
```

Set `schemaMode: strict`. Give each agent a stable name such as `ShipChunk1`. The agent edits the repository and returns its structured handoff through `agent://<id>`; temporary prompt and output files are unnecessary.

Sequential execution is the default. Dispatch both chunks in one `task` batch only when all are true:

- their contracts and file ownership are disjoint;
- neither consumes the other's output;
- OMP task isolation is enabled;
- the configured isolation merge strategy will integrate both results.

Verify the integrated parent checkout after isolated tasks. Never run concurrent writers in one checkout or assign overlapping files.

For a user-visible chunk, give the worker the loaded `skill://ui-evidence` contract and make actual browser evidence part of its deliverable. The orchestrator independently exercises the real surface after integration.

### Chunk verification and correction

Run the chunk's approved verification yourself. Then record the observation:

```text
ship_run op=record_chunk index=<n> agentId=<id> status=<passed|failed> summary=<summary> verification=<observed-result>
```

On failure:

1. send the exact failure evidence once to the idle chunk agent with `hub send`;
2. rerun the same verification;
3. if still red, spawn one fresh `ship-fixer` task with the failure, current diff, criteria, and prior `agent://` handoff;
4. rerun the verification;
5. if still red, call `ship_run op=finish outcome=stopped openItems=<evidence>` and report.

An isolated agent is not revivable; go directly to a fresh `ship-fixer`. Task results self-deliver, so do not poll. Use `hub wait` only when no other action is available.

## 7. Full verification and pull request

After every chunk passes:

1. run the repository's full applicable test suite once;
2. run the actual smoke scenario for the changed behavior;
3. for UI work, follow `skill://ui-evidence`: distinguish preview access from application authentication, exhaust the real route, sanctioned writable scratch data and temporary production-shell fixture harness, then publish evidence; use `un-capturable:` only when all accurate routes are unavailable, naming each attempted route and blocker;
4. inspect the resulting change as the user would;
5. commit on the feature branch;
6. push with the native `github` tool when it can resolve the branch, otherwise use one explicit Git push;
7. create the PR with `github op=pr_create`;
8. include the issue, approved criteria checklist, chunk summaries, verification, and UI evidence in the body;
9. watch Actions with `github op=run_watch`; use its failed-log artifact when red.

A failing full suite or smoke scenario follows the same fresh `ship-fixer` policy. The PR is not ready while required verification is red.

Record the open PR only after local verification and required CI are green:

```text
ship_run op=record_pr prUrl=<url> tests=<local-and-CI-status>
```

## 8. Review — one round, two maximum

Run one round through the loaded `skill://codex-review`; the repository's GitHub Codex review is authoritative and a local reviewer is not a fallback. Its watcher is a finite background command under OMP; let completion self-deliver instead of polling. If the skill or watcher becomes unavailable, stop and repair the plugin installation.

- valid: one fresh `ship-fixer` task for the round, then verify, push, and refresh affected UI evidence;
- invalid: reply with `(resolver, round N)` and concrete evidence.

Record the round:

```text
ship_run op=record_review index=<round> reviewOutcome=<outcome> fixed=<n> rejected=<n> outstanding=<n> behaviorChanged=<bool>
```

Run round two only for deep tier or when round-one fixes changed behavior. At two rounds, hand over any remaining finding rather than looping.

## 9. Hand over

Report:

- PR URL;
- every approved criterion with status and evidence;
- local tests, smoke scenario, and CI status;
- review outcomes;
- UI evidence or `un-capturable:` reasons;
- anything still open.

Call `ship_run op=finish outcome=pr-open` with exactly one `criteriaStatus` entry per approved criterion and any `openItems`. Never merge; the human merges.
