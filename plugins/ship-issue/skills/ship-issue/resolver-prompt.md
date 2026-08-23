You are resolving the Codex review findings on **PR #{{PR_NUMBER}}** in `{{REPO}}`
(issue #{{ISSUE_NUMBER}}). This is **round {{ROUND}} of {{MAX_ROUNDS}}**.

Worktree `{{WORKTREE}}`, branch `{{BRANCH}}`. Run everything from inside it.

- install: `{{INSTALL_CMD}}`
- test: `{{TEST_CMD}}`
- typecheck: `{{TYPECHECK_CMD}}`
- lint: `{{LINT_CMD}}`
- the gate the issue itself names: `{{ISSUE_STATED_COMMANDS}}`

Where the issue names its own gate and it differs from the detected commands, **the issue wins**
— in a workspace the real check is frequently app-local (`cd apps/foo && pnpm check`) while
detection reports the root scripts. A fix to app-local code that only ever ran the root commands
is unverified, however green those came back. Run both.

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

**End every in-thread reply with `(resolver, round {{ROUND}})`, not just the round summary.**
That marker is what `codex-wait.sh findings` counts as `resolverReplyCount`, and it is how the
next round tells a finding you have already answered from one still outstanding. A thread you
replied to without the marker reads as unresolved — `counts.unresolved` will overstate the work
left, and the next resolver may redo yours.
- **Finding is out of scope** → say so on the comment and, if it is worth doing, note it for a
  follow-up issue. Do not expand the PR.

Findings marked `outdated` or `staleAgainstHead` refer to code that has since moved. Check
whether they still apply to head before acting; if they don't, say that rather than reverting
to the old shape. `raisedOn` is the commit a finding was actually raised against — GitHub keeps
advancing a comment's own `commit_id` as head moves, so a finding from an earlier round looks
current until you read `raisedOn`.

**A finding with `resolverReplyCount` above zero was answered by an earlier round** — read that
thread before touching it, because re-fixing settled work is how a run burns its second round on
the first round's findings. `replyCount` is not the same signal: it counts any reply at all,
including a human asking codex a follow-up, so a finding can be live and chatty at once. When the
two disagree, read the thread and decide; never skip a finding on `replyCount` alone.

Hard rules:

- **Never weaken or delete a test** to resolve a finding.
- Never make a change you cannot justify. "The bot asked" is not a justification.
- Keep the diff proportionate — resolving a P3 note should not restructure a module.
- **If a fix changes what the user sees, re-shoot the screenshot** and update the PR body with
  the new URL — a stale shot is worse than none, because it certifies a state that no longer
  exists. Capture it the same way the implementers did: a **throwaway Playwright script against a
  temporary, uncommitted harness route seeded with mock data**, on a dev server you start on an
  ephemeral port, torn down completely so none of it lands in the diff. Stop that server by the
  PID you recorded, never `pkill -f <port>` — the pattern matches your own shell and kills your
  session. Publish with the `pr-media-upload` skill; search for it rather than assuming a depth:
  `find "$HOME/.codex/plugins" "$HOME/.claude/plugins" "$HOME/.claude/skills" -path '*pr-media-upload/upload.sh' -type f -perm -u+x 2>/dev/null | head -1`.
  **Never `agent-browser`, the browser MCP tools, the in-app browser pane, or a preview deploy** —
  those need real auth and real data and cannot be reproduced from the diff.
- **Updating the PR body: check the exit code.** `gh pr edit` fails outright against hosts where
  Projects (classic) is sunset unless `gh` is recent, and it fails *silently* from the caller's
  point of view — the body simply does not change. `gh api repos/<slug>/pulls/<n> -X PATCH -F
  body=@file` always works.

## Finishing

1. Run every verification command from inside the worktree; they must pass.
2. Commit and push.
3. Post one PR comment summarising the round: what you fixed, what you rebutted and why, what
   you deferred. End it with `(resolver, round {{ROUND}})`. **Post it as an issue comment on the
   PR** (`gh pr comment`) even if you also reply in a finding's own thread — that marker is how
   the orchestrator counts rounds against the cap, and a reply inside a review thread does not
   show up in `gh pr view --json comments`. Replying in-thread as well is good practice: it puts
   the resolution where the finding is.
4. **Do not merge**, and do not re-trigger codex — the orchestrator handles the next round.

Return only the structured resolver report requested by the output schema. Give every finding an
ID, a `fixed`, `rebutted`, `deferred`, or `unresolved` disposition, and concrete evidence. Include
actual verification exit codes, pushed SHAs, replacement screenshots or an `uncapturable` reason,
and concise notes. Use `green` only when this round completed as intended; otherwise use `stopped`
or `escalate`.
