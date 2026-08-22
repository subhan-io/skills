---
name: pr-media-upload
description: Upload an image or video and get a permanent public URL to embed in a GitHub PR description (or issue/comment). Use whenever you need to put a screenshot, screen recording, GIF, or demo clip into a PR body — agents can't drag-drop into GitHub's web uploader, so host the file on S3 and embed the URL instead. Triggers — pr screenshot, pr video, embed image in pr, pr description image, upload media for pr, demo gif in pr, attach image to pull request.
allowed-tools: Bash
---

# PR Media Upload

Agents can't use GitHub's drag-drop attachment uploader (that path needs a browser
session, not a token). So to put media in a PR description, host the file somewhere
public and embed the URL. This skill uploads to a dedicated public S3 bucket and
hands you back a permanent URL.

## Finding `upload.sh`

**`upload.sh` lives next to this file, in the skill's own directory — not in the repo
you're working in.** The skill is installed once per machine and runs against whatever
repo happens to be the cwd, so resolve the script against the directory this SKILL.md
was loaded from. On the symlink install that's:

```bash
upload=~/.claude/skills/pr-media-upload/upload.sh
```

On Claude's plugin path it's `"$CLAUDE_PLUGIN_ROOT"/skills/pr-media-upload/upload.sh`.
Codex installs it below `~/.codex/plugins/cache/<marketplace>/pr-media-upload/`.
In every host, the reliable option is the directory this file was loaded from. Set `$upload`
once and reuse it; the examples below assume it.

The script itself is cwd-independent — run it from any repo, with a relative or
absolute file path.

## TL;DR

```bash
# 1. upload — prints ONE line: the public URL
url=$("$upload" ./screenshot.png)

# 2a. image → markdown
gh pr edit 123 --body "$(printf '## Changes\n\n![screenshot](%s)\n' "$url")"

# 2b. video → <video> tag (GitHub renders an inline player from the tag)
gh pr edit 123 --body "$(printf '## Demo\n\n<video src="%s" controls width="640"></video>\n' "$url")"
```

`upload.sh` is the one entry point — it pulls the scoped uploader creds from
Infisical, picks the right `Content-Type`, uploads, and echoes the URL. It writes
only the URL to stdout (progress goes to stderr) so `url=$(...)` is safe.

## Embedding rules

- **Images** (`.png .jpg .jpeg .gif .webp`) — use markdown `![alt](url)`. GitHub
  fetches the image once through its camo proxy and caches it, so this is cheap and
  the S3 URL is never exposed to viewers.
- **Video** (`.mp4 .mov .webm`) — use a raw HTML tag on its own line:
  `<video src="url" controls width="640"></video>`. GitHub allows this tag and
  renders an inline player. Unlike images, video streams **directly from S3 to each
  viewer** (no camo), so prefer short clips. If a view ever shows a bare link instead
  of a player, the URL still works — it's a plain link to a playable file.

## Multiple files / building a body

Upload each file, collect the URLs, then assemble the body once:

```bash
shot=$("$upload" ./before.png)
demo=$("$upload" ./demo.mp4)
gh pr edit 123 --body "$(cat <<EOF
## What changed

Before:

![before]($shot)

Demo:

<video src="$demo" controls width="640"></video>
EOF
)"
```

The same URLs work in issues and PR/issue comments — anywhere GitHub renders markdown.

- **Self-contained HTML** (`.html`) — served as `text/html`, so the URL opens as a page
  in any browser. This is how `ship-issue` publishes its plan explainer so a human on
  another device can read it while the agent runs on a remote box. Only for pages with
  everything inline; a page that references sibling files has nowhere to load them from.

## Caveats — read once

- **Public + permanent.** Every uploaded object is world-readable forever (no expiry).
  Don't upload anything secret, internal, or PII. There's no auth on read.
- **Write-only creds.** The uploader IAM user can `PutObject` and nothing else — it
  can't list, read, overwrite-protect, or delete. If you need to delete an object,
  that's a manual admin action (`aws s3 rm ...` with privileged creds).
- **Keys are random** (`pr/YYYY/MM/<uuid>.<ext>`) so URLs are unguessable-ish and
  never collide. Re-running on the same file produces a new URL each time.

## Requirements

`infisical` (logged in, or a machine identity in the environment) and `aws` on PATH.
No AWS profile and no `.env` needed — and no per-repo setup at all: nothing here reads
the current repo's config.

## Infrastructure (reference — already provisioned)

| Thing | Value |
|---|---|
| Bucket | `subhanio-pr-assets` (public-read via bucket policy, ACLs disabled) |
| Region | `eu-west-2` |
| URL shape | `https://subhanio-pr-assets.s3.eu-west-2.amazonaws.com/<key>` |
| Uploader IAM user | `pr-assets-uploader` — inline policy `s3:PutObject` on this bucket only |
| Creds | Infisical project `75f1046c-8450-4039-92fd-14472c6a0bd7`, path `/pr-assets` (`dev` + `prod`): `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` |

Because the creds live in Infisical (not just a local AWS profile), this works from
any agent that can `infisical run` — local or remote/cloud. No app endpoint, no
deploy surface: upload is a direct `aws s3 cp`.

**The `--projectId` flag in `upload.sh` is load-bearing — don't "simplify" it away.**
Without it, `infisical run` resolves the project from the nearest `.infisical.json`,
so running the skill from a repo with its own Infisical config would look up
`/pr-assets` in *that* project and fail. Passing the project id and `--path`
explicitly is what makes the skill work from an arbitrary repo.
