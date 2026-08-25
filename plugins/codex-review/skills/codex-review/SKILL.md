---
name: codex-review
description: >-
  Drive one Codex review round on a GitHub PR — request the review, wait until it
  has actually settled, read the head commit's findings, and judge which are already
  resolved. Use when a PR needs a Codex review, when waiting on one, or when
  checking whether its findings are resolved.
---

# Codex review

Codex is not a GitHub check — nothing in `gh pr checks` ever reflects it. You post
the `@codex review` trigger, the review lands minutes later in one of two shapes (a
PR review plus inline comments when it has findings; a plain issue comment when it
does not), and the only completion signal is that the bot has covered the head
commit *and* gone quiet for the settle window (120s). `scripts/codex-wait.sh` (in
this skill's directory) encodes all of that:

```
scripts/codex-wait.sh status   <pr> [--quiet]   # snapshot: not-requested | awaiting | arriving | settled
scripts/codex-wait.sh request  <pr> [--force]   # post the trigger (exit 5 = already requested for this head — fine)
scripts/codex-wait.sh watch    <pr>             # block until settled — ALWAYS run backgrounded
scripts/codex-wait.sh findings <pr> [--all]     # head commit's findings, with staleness and resolution counts
```

One round is: `request`, then `watch` as a background command (it blocks up to 15
minutes; end your turn and let its completion re-invoke you — in a harness without
background commands, poll `status` every few minutes instead), then `findings`.

## Rules the script enforces — do not second-guess them

- **Read only a `settled` review.** Codex posts inline comments in bursts *after*
  the review body; reading an `arriving` review gives a truncated finding set and
  you fix half the review.
- **Coverage is the `**Reviewed commit:** <sha>` line**, not timestamps. A review
  of an older commit is not a review of head. Any push moves head, so the state
  returns to `not-requested` — a re-review after fixes is intended, not a bug.
- **A finding's `commit_id` lies.** GitHub advances it as head moves, so an old
  finding reads as new. `findings` reports `raisedOn` (the original commit) for
  exactly this reason.
- **Replies are not resolution.** Branch on `resolverReplyCount` and
  `counts.unresolved`, never `replyCount` — a human asking codex a follow-up is a
  reply too. Resolution is evidenced by a reply carrying the `(resolver, round N)`
  marker; when you resolve or rebut a finding, tag your reply with that marker so
  later rounds count it.
- **`watch` exit 4 means codex still looked silent — confirm before believing it.**
  Check the bot's PR reviews *and* issue comments for a `Reviewed commit:` line
  matching head; a verdict in an unexpected shape is indistinguishable from silence
  at the script's level. If it truly is silent, report that rather than
  re-triggering on a loop.

The round is complete when `counts.unresolved` is zero for the head commit — every
finding either fixed and pushed, or answered with a `(resolver, round N)` rebuttal.
Count prior rounds by that marker in **both** the PR's issue comments and its
review-comment replies; thread replies never appear in `gh pr view --json comments`.
