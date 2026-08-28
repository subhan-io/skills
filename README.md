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

Installing only `ship-issue-omp` is incomplete: its preflight stops before the
criteria gate when a required review or UI-evidence companion is missing.

Restart OMP after installing the extension package, then run
`/ship-issue-omp <issue-url-or-task>`. Use
`omp plugin marketplace update subhan-skills` to refresh the catalog.

## Install in Codex

Add this repository as a marketplace, then install whichever plugins you want:

```sh
codex plugin marketplace add subhan-io/skills
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
/plugin install ship-issue@subhan-skills
/reload-plugins
```

Update later with `/plugin marketplace update subhan-skills`.

On machines where you edit this repo, `./install.sh` can instead symlink every compatible skill into
`~/.claude/skills`. `./install.sh -n` previews the changes, and `./install.sh ship-issue`
links only one skill. A real directory is never replaced unless `-f` is passed.
Skills marked `omp-only: true` are intentionally excluded from these Claude symlinks.

## Adding a plugin

1. Create `plugins/<name>/skills/<name>/SKILL.md` and its bundled resources.
2. For OMP extension code or agents, add `package.json`, `src/`, and `agents/` as needed.
3. Add a Codex `.codex-plugin/plugin.json` only when the workflow works under Codex.
4. Register the plugin in the harness-specific marketplace catalogs it actually supports.
5. Validate the plugin, skill, agents, and extension before pushing.

## Plugins

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

Confirms acceptance criteria and a planning tier, plans inline
(dispatching an Opus planner only for deep work), proposes an issue split past two chunks,
implements each chunk in a fresh Codex session via `scripts/run-codex.sh`, and runs one Codex
review round. Every run and every Codex session appends token usage to
`~/.local/state/ship-issue/ledger.jsonl`; `scripts/usage-report.sh` reports cost per run.
The skill carries its own Codex-harness adaptations, so the native Codex plugin runs the same
workflow. Uses the plan-explainer, ui-evidence, and codex-review plugins — install those
alongside it.

The plugin also carries `/ship-epic`, a thin wrapper for epics with native sub-issues: each
invocation is one tick that surveys the epic, ships the next unblocked sub-issue through
`/ship-issue`, and reports. The human merges between ticks. `/ship-epic afk` instead
dispatches each pick as its own t3code sidebar thread (via the local t3 server's HTTP
dispatch API) running `/ship-issue afk` — unattended light/standard runs that self-merge
on green — and drains the epic in one invocation.

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
