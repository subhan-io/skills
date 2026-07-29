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
