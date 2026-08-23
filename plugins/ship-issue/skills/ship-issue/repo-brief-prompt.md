You are preparing an evidence brief for GitHub issue **#{{ISSUE_NUMBER}}** in `{{REPO}}`.

**{{ISSUE_TITLE}}** — {{ISSUE_URL}}

```text
{{ISSUE_BODY}}
```

The human confirmed the criteria with these notes:

{{CRITERIA_NOTES}}

Read only. Work in `{{WORKTREE}}`, which is cut from `origin/{{BASE_BRANCH}}`. Do not edit,
commit, push, create a worktree, or make any external change. Your job is to pay the repository
discovery cost once and give the planner traceable evidence.

Detected commands are leads, not facts:

- install: `{{INSTALL_CMD}}`
- test: `{{TEST_CMD}}`
- typecheck: `{{TYPECHECK_CMD}}`
- lint: `{{LINT_CMD}}`
- issue-stated commands: `{{ISSUE_STATED_COMMANDS}}`

Read every instruction file that applies to likely touched paths. Trace the current behavior from
entry point through its important callers and tests. Find existing patterns the implementation
should copy. Search broadly enough to disprove the first obvious approach.

Return only the structured report requested by the output schema:

- `status`: `ready`, or `blocked` when missing access or evidence prevents a reliable brief.
- `summary`: the likely implementation surface and current behavior.
- `relevantFiles`: exact paths, their purpose, important symbols, and concise evidence such as
  line references or short excerpts. Evidence must let the planner verify your claims quickly.
- `existingPatterns`: named patterns, all supporting paths, and what should be copied.
- `tests`: relevant test paths, the command that runs them when known, and what they cover.
- `instructions`: each applicable `AGENTS.md` or `CLAUDE.md`, its scope, and load-bearing rules.
- `risks`: contracts, side effects, migrations, UI evidence, or cross-package effects to inspect.
- `openQuestions`: facts you could not determine from the repository.
- `notes`: anything useful that does not fit above.

Do not propose chunks. Do not write the implementation plan. Do not turn guesses into facts.
