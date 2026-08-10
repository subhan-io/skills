# skills

Personal agent skills, kept in one repo so every machine runs the same version.

```
skills/<name>/SKILL.md    # one directory per skill — that's the whole convention
install.sh                # symlinks them into ~/.claude/skills
.claude-plugin/           # marketplace manifest, for the plugin install path
```

## Install

Two paths. They're independent — pick one per machine.

**Symlink (recommended for machines where you also edit the skills).** Skills stay linked to the working tree, so `git pull` updates them everywhere with no reinstall:

```sh
git clone git@github.com:subhan-io/skills.git ~/Documents/code/subhan-skills
cd ~/Documents/code/subhan-skills && ./install.sh
```

`./install.sh -n` shows what it would do. `./install.sh dispatch-agents` links just one. A real
directory already sitting at `~/.claude/skills/<name>` is never clobbered without `-f`.

**Plugin marketplace (recommended for machines that only consume).** Claude Code copies the skills
into its plugin cache and manages updates:

```
/plugin marketplace add subhan-io/skills
/plugin install dispatch-agents@subhan-skills
/reload-plugins
```

Update later with `/plugin marketplace update subhan-skills`. Note that plugin skills are namespaced
by plugin (`/dispatch-agents:dispatch-agents`), whereas symlinked ones are just `/dispatch-agents`.

## Adding a skill

1. `mkdir skills/<name>` and write `SKILL.md` with `name:` + `description:` frontmatter.
2. Add an entry to `.claude-plugin/marketplace.json` (`source: "./"`, `skills: ["./skills/<name>"]`,
   `strict: false`) so the plugin path picks it up too. The symlink path needs no registration.
3. Push. Other machines: `git pull` (symlink) or `/plugin marketplace update` (plugin).

## Skills

### dispatch-agents

Runs one orchestrator tick over a repo's agent pipeline: shepherds open agent PRs through checks →
codex review → adversarial review, fans out rebase agents after merges, and dispatches unblocked
`ready-for-agent` issues to background implementers in isolated worktrees. GitHub labels, branches
and comments are the only state store, so a tick is resumable from a cold session.

Requires `gh` (authenticated), `jq`, `git`, `python3`, and a repo whose PRs are reviewed by the
[Codex GitHub app](https://chatgpt.com/codex) — the skill triggers reviews by commenting
`@codex review` and waits for them to settle.

**Per-repo config is mandatory outside subhanio-platform.** The built-in defaults name that repo's
labels and app. Drop a `.claude/dispatch-agents.env` in the target repo:

```sh
APP_LABEL=my-app                      # label identifying the app's issues
PREVIEW_LABEL=deploy-preview:my-app
BASE_BRANCH=main                      # default: master
TRACKING_ISSUE=42                     # the contracts/bulletin issue
# READY_LABEL, CLAIM_LABEL, REVIEW_LABEL, CONFLICT_LABEL, BRANCH_PREFIX,
# MAX_ATTEMPTS and the CODEX_* knobs are also overridable — see scripts/common.sh
```

Values set on the command line beat the file, so `BASE_BRANCH=trunk ./scripts/tick-state.sh` still
works for a one-off. Kill switch: `touch .claude/dispatch-agents.STOP` in the target repo.

The prompts still assume a pnpm monorepo with `pnpm test` / `typecheck --filter=<app>` /
`lint --filter=<app>`; adapting them to a different toolchain means editing
`implementer-prompt.md` and `reviewer-prompt.md`, not just the env file.

### ship-issue

Takes **one** named issue end to end and stops with a PR ready for you to merge:
fresh worktree off the current default-branch tip → opus planner (chunked to ~200k tokens per
session) → **approval gate** → sonnet implementer → PR → codex review → opus resolver, max two
resolve rounds. `/ship-issue https://github.com/owner/repo/issues/12`, or just `12`.

The sibling of `dispatch-agents`, not a replacement: that one sweeps a whole board unattended off
labels, this one runs a single issue with you in the loop and never writes code before you have
approved the plan. It never merges.

**No per-repo config.** Default branch, package manager and verification commands are detected;
whatever detection can't establish comes back as a warning to raise with you rather than a
silent assumption. Requires `gh` (authenticated), `jq`, `git`, and the
[Codex GitHub app](https://chatgpt.com/codex) on the repo — setup warns if it sees no sign of it
rather than letting the review step hang for 15 minutes.

Worktrees land in `.claude/worktrees/ship-issue-<n>` on `ship/issue-<n>` — deliberately not
`agent/issue-<n>`, so `dispatch-agents` in the same repo doesn't adopt the branch as its own.

### pr-media-upload

Uploads a screenshot, GIF or screen recording to a public S3 bucket and prints a permanent URL, so
an agent can embed media in a GitHub PR description. Agents can't use GitHub's drag-drop attachment
uploader — that needs a browser session, not a token — so hosting the file and embedding the URL is
the only route. `upload.sh <file>` writes just the URL to stdout, so `url=$(upload.sh shot.png)`
is safe.

Requires `infisical` (logged in) and the `aws` CLI. Credentials for the write-only uploader IAM
user come from Infisical, passed with an explicit `--projectId`/`--path`, so the skill works from
any repo regardless of that repo's own `.infisical.json`. No per-repo config.

Uploads are **public and permanent** — no expiry, and the scoped creds can't delete. Never upload
anything secret or personal.
