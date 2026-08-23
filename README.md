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

### pr-media-upload

Uploads a screenshot, GIF, video, or HTML demo to a public S3 bucket and prints a permanent URL
for a GitHub PR, issue, or comment. Requires logged-in `infisical` and the AWS CLI. Uploads are
public and permanent; never upload secret or personal material.
