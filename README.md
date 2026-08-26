# skills

Personal agent workflows packaged for OMP, Codex, and Claude Code.

```text
plugins/<name>/skills/<name>/SKILL.md     # skill and its bundled resources
plugins/<name>/package.json               # optional OMP extension manifest
plugins/<name>/{agents,src}/               # optional OMP agents and extension code
.omp-plugin/marketplace.json               # OMP marketplace catalog
.agents/plugins/marketplace.json            # Codex marketplace catalog
.claude-plugin/marketplace.json             # Claude Code marketplace catalog
install.sh                                  # optional Claude skill symlinks
```

## Install in OMP

Add this repository as a marketplace, then install the native ship workflow and its
evidence/review companions:

```sh
omp plugin marketplace add subhan-io/skills
omp plugin install ship-issue-omp@subhan-skills
omp plugin install plan-explainer@subhan-skills
omp plugin install ui-evidence@subhan-skills
omp plugin install codex-review@subhan-skills
omp plugin install pr-media-upload@subhan-skills
```

Restart OMP after installing the extension package, then run
`/ship-issue-omp <issue-url-or-task>`. Use
`omp plugin marketplace update subhan-skills` to refresh the catalog.

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

On machines where you edit this repo, `./install.sh` can instead symlink every compatible skill into
`~/.claude/skills`. `./install.sh -n` previews the changes, and `./install.sh dispatch-agents`
links only one skill. A real directory is never replaced unless `-f` is passed.
Skills marked `omp-only: true` are intentionally excluded from these Claude symlinks.

## Adding a plugin

1. Create `plugins/<name>/skills/<name>/SKILL.md` and its bundled resources.
2. For OMP extension code or agents, add `package.json`, `src/`, and `agents/` as needed.
3. Add a Codex `.codex-plugin/plugin.json` only when the workflow works under Codex.
4. Register the plugin in the harness-specific marketplace catalogs it actually supports.
5. Validate the plugin, skill, agents, and extension before pushing.

## Plugins

### dispatch-agents

Runs one orchestrator tick over a repository's agent pipeline: shepherds open agent PRs through
checks and reviews, fans out rebase agents after merges, and dispatches unblocked
`ready-for-agent` issues to isolated implementers. GitHub labels, branches, and comments are the
state store, so a tick is resumable from a cold session.

Requires authenticated `gh`, `jq`, `git`, and `python3`. Repositories outside the original
platform setup need a `.claude/dispatch-agents.env`; see the skill itself for the complete config.

### ship-issue-omp

The OMP-native issue workflow. `/ship-issue-omp` confirms acceptance criteria and a planning
tier through the native ask UI, records gates and run events through the `ship_run` extension
tool, plans deep work with a role-routed `ship-planner`, and implements verified chunks in fresh
`ship-chunk` task sessions. It uses structured `agent://` handoffs, `hub` follow-ups, safe
parallel isolation for genuinely independent chunks, native GitHub PR/CI operations, UI
evidence, and bounded Codex review. Run state is reconstructible from the OMP session; the
machine-central ledger is `~/.local/state/ship-issue-omp/ledger.jsonl`. The human merges.

Requires authenticated `gh` and the plan-explainer, ui-evidence, codex-review, and
pr-media-upload plugins for their corresponding branches.

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
