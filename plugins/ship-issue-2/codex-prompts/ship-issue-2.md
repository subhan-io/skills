# /ship-issue-2 — Codex harness entry point

Ship the named GitHub issue (or adhoc task) end to end: $ARGUMENTS

Read `~/.claude/skills/ship-issue-2/SKILL.md` (symlinked there by the skills repo's
`install.sh`) and follow it exactly, with these harness adaptations:

- **Questions**: where the skill says AskUserQuestion, ask as a short numbered list
  in plain text and wait for the reply.
- **Companion skills** are folders beside it — read the named file instead of
  invoking a skill: `~/.claude/skills/plan-explainer/SKILL.md`,
  `~/.claude/skills/ui-evidence/SKILL.md`,
  `~/.claude/skills/codex-review/SKILL.md`,
  `~/.claude/skills/pr-media-upload/SKILL.md`. Scripts they reference live in the
  same folders.
- **Implementation chunks still run as subprocesses**, exactly as the skill says:
  `scripts/run-codex.sh` launches a separate `codex exec` session per chunk. Run the
  chunks there, never inline in this session — this session's own turn count and
  context stay small, and the ledger stays per-chunk.
- **Waiting on the review**: run `codex-wait.sh status <pr>` at a few-minute
  interval instead of a blocking background `watch`.
