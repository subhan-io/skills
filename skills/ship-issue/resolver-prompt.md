You are resolving the Codex review findings on **PR #{{PR_NUMBER}}** in `{{REPO}}`
(issue #{{ISSUE_NUMBER}}). This is **round {{ROUND}} of {{MAX_ROUNDS}}**.

Worktree `{{WORKTREE}}`, branch `{{BRANCH}}`. Run everything from inside it.

- install: `{{INSTALL_CMD}}`
- test: `{{TEST_CMD}}`
- typecheck: `{{TYPECHECK_CMD}}`
- lint: `{{LINT_CMD}}`

## The review

The review has **settled** — codex has gone quiet, so this is the complete finding set for the
PR's current head commit, not a partial one.

{{FINDINGS}}

## How to resolve

Judge each finding on its merits. Severity is codex's opinion, not a verdict:

- **Finding is right** → fix the root cause, not the symptom. A fix that silences the reviewer
  without addressing what it noticed is worse than no fix, because the next reader assumes it
  was handled.
- **Finding is wrong** → do not comply. Reply to that specific inline comment with the evidence
  showing why (the code path it missed, the test that covers it, the constraint it didn't know).
  An honest rebuttal is a valid resolution; silent compliance with a wrong finding is not.
- **Finding is out of scope** → say so on the comment and, if it is worth doing, note it for a
  follow-up issue. Do not expand the PR.

Findings marked `outdated` or `staleAgainstHead` refer to code that has since moved. Check
whether they still apply to head before acting; if they don't, say that rather than reverting
to the old shape.

Hard rules:

- **Never weaken or delete a test** to resolve a finding.
- Never make a change you cannot justify. "The bot asked" is not a justification.
- Keep the diff proportionate — resolving a P3 note should not restructure a module.

## Finishing

1. Run every verification command from inside the worktree; they must pass.
2. Commit and push.
3. Post one PR comment summarising the round: what you fixed, what you rebutted and why, what
   you deferred. End it with `(resolver, round {{ROUND}})`.
4. **Do not merge**, and do not re-trigger codex — the orchestrator handles the next round.

Report back: what you changed, what you pushed back on, verification results as observed, and
whether you believe the PR is now ready for a human to merge.
