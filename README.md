# skills

Personal agent workflows packaged as native Codex plugins, with compatibility for Claude Code.

```text
plugins/<name>/.codex-plugin/plugin.json  # Codex plugin manifest
plugins/<name>/skills/<name>/SKILL.md     # skill and its bundled resources
.agents/plugins/marketplace.json          # Codex marketplace catalog
.claude-plugin/marketplace.json           # Claude Code marketplace catalog
install.sh                                # optional Claude skill symlinks
```

## Install in Codex

Add this repository as a marketplace, then install whichever plugins you want:

```sh
codex plugin marketplace add subhan-io/skills
codex plugin add dispatch-agents@subhan-skills
codex plugin add ship-issue@subhan-skills
codex plugin add pr-media-upload@subhan-skills
```

Use `codex plugin marketplace upgrade subhan-skills` to refresh the repository snapshot, and
`codex plugin list` to inspect available or installed plugins.

For local development, point Codex at the checkout instead:

```sh
codex plugin marketplace add "$PWD"
```

## Install in Claude Code

The existing Claude marketplace remains supported:

```text
/plugin marketplace add subhan-io/skills
/plugin install dispatch-agents@subhan-skills
/reload-plugins
```

Update later with `/plugin marketplace update subhan-skills`.

On machines where you edit this repo, `./install.sh` can instead symlink every skill into
`~/.claude/skills`. `./install.sh -n` previews the changes, and `./install.sh dispatch-agents`
links only one skill. A real directory is never replaced unless `-f` is passed.

## Adding a plugin

1. Create `plugins/<name>/skills/<name>/SKILL.md` and its bundled resources.
2. Add `plugins/<name>/.codex-plugin/plugin.json`; the folder and manifest names must match.
3. Add the plugin to `.agents/plugins/marketplace.json` and the compatibility entry to
   `.claude-plugin/marketplace.json`.
4. Validate the plugin and skill before pushing.

## Plugins

### dispatch-agents

Runs one orchestrator tick over a repository's agent pipeline: shepherds open agent PRs through
checks and reviews, fans out rebase agents after merges, and dispatches unblocked
`ready-for-agent` issues to isolated implementers. GitHub labels, branches, and comments are the
state store, so a tick is resumable from a cold session.

Requires authenticated `gh`, `jq`, `git`, and `python3`. Repositories outside the original
platform setup need a `.claude/dispatch-agents.env`; see the skill itself for the complete config.

### ship-issue

Takes one named issue from an isolated worktree to a merge-ready pull request. It builds a Codex
repository brief, plans with Claude Opus, stops for human approval, alternates sequential chunks
between Codex and Claude Sonnet, requests Codex review, and resolves the findings. It never merges
the PR.

Requires authenticated `gh`, `claude`, and `codex`, plus `jq`, `git`, `python3`, and GNU
`timeout`. UI screenshots additionally use the `pr-media-upload` plugin and its prerequisites.

### ship-issue-2

The lean successor to ship-issue: confirms acceptance criteria and a planning tier, plans inline
(dispatching an Opus planner only for deep work), proposes an issue split past two chunks,
implements each chunk in a fresh Codex session via `scripts/run-codex.sh`, and runs one Codex
review round. Every run and every Codex session appends token usage to
`~/.local/state/ship-issue/ledger.jsonl`; `scripts/usage-report.sh` reports cost per run.
The skill carries its own Codex-harness adaptations, so the native Codex plugin runs the same
workflow. Uses the plan-explainer, ui-evidence, and codex-review plugins — install those
alongside it.

### plan-explainer

Builds a self-contained HTML explainer page — UI mocks from the app's real design tokens,
decision forks as selectable cards, a Copy-answers button — and publishes it to a permanent
unlisted URL via pr-media-upload.

### ui-evidence

Rules for capturing screenshots or video that prove a UI change: accurate shell and commit on
any route, viewport and teardown gotchas, and an `un-capturable:` convention so shots never
quietly go missing. Publishes via pr-media-upload.

### codex-review

Drives one Codex review round on a PR with `scripts/codex-wait.sh`: requests the review, waits
until it has actually settled, reads only findings covering the head commit, and tracks
`(resolver, round N)` resolution markers across rounds.

### pr-media-upload

Uploads a screenshot, GIF, video, or HTML demo to a public S3 bucket and prints a permanent URL
for a GitHub PR, issue, or comment. Requires logged-in `infisical` and the AWS CLI. Uploads are
public and permanent; never upload secret or personal material.
