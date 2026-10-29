# Upkeep

Audit, rewrite and close out existing issues. Every change to an issue body,
field or state follows the body rules in [SKILL.md](SKILL.md). Issues the board
shows as In progress, or that have an open PR, are left alone unless the human
names them: an agent may be working from that body.

## 1. Survey

```sh
scripts/survey.sh --repo <repo> --project <n> [--app <name>] [--top-level]
```

`--app content --top-level` matches the board's per-app views. The script's
header defines each flag. Read every flagged issue in full before proposing
anything; a flag is a reason to look, not a verdict. Done when every flagged
issue has a proposed action or a stated reason to leave it.

## 2. Propose

Put the proposals to the human as one list grouped by action:

- **Rewrite**: LONG or CODE bodies, bodies in an old template, and epics whose
  Contracts or Children now describe shipped or closed work.
- **Fix fields**: DONE-OPEN status, NO-APP, NO-TYPE, a sub-issue missing its
  native parent link.
- **Close**: CHILDREN-CLOSED parents whose outcome is met; SHIPPED issues; an
  issue a merged PR (MENTIONED) did in full; duplicates, closed in favour of the
  older or fuller one.
- **Re-parent**: PARENT-CLOSED children whose work is still wanted. Move them to
  an open parent or make them top-level.
- **Stale assumption**: an issue written against a model that has since changed.
  Rewrite it, or close it with the reason, as was done for the iOS issues written
  for a single owner.

A research issue is never closed because build work in the same area shipped;
only its recorded decision closes it. Done when the human has answered each item.

## 3. Apply

- **Rewrite.** Save the current bodies to a scratch directory first; GitHub's
  edit history keeps them too. Keep every fact that lives nowhere else, in Known
  so far, Decisions or a pinned link; cut what the code, a report or the board
  already holds. Then `gh issue edit <n> --body-file <file>`.
- **Fields and parents.** `scripts/issue-fields.sh`. It refuses to move an issue
  that already has a different parent; a deliberate move is `addSubIssue` with
  `replaceParent: true`.
- **Close.** `gh issue close <n> --reason completed|"not planned" --comment` with
  a comment naming the PR, the duplicate or the reason.

Done when a fresh survey shows no flag the human chose to fix.
