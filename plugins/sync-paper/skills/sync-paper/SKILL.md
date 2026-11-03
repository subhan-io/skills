---
name: sync-paper
description: Reflect UI changes merged straight in code back into an app's Paper artboards, editing the existing layers in place.
disable-model-invocation: true
argument-hint: <app directory name> [--from <commit>]
---

# Sync code changes back to Paper

Work starts in Paper and gets built in code, but small changes also land straight in code. This skill carries those changes back, so a **shipped artboard** keeps showing what the app does. Code is the truth for a shipped artboard; Paper is the truth for anything marked `(not built)`.

Everything specific to an app lives in its map, `<repo>/.claude/sync-paper/maps/<app>.json`, versioned with the app's code: its Paper file and page, where its UI code lives, how its tokens translate, and each shipped screen with its artboard IDs and code paths. Only artboards in the map are edited. If the app has no map, follow [`MAP.md`](MAP.md) to draft one, then stop for the user to review it, because the map decides what this skill may edit. If `<repo>/.claude/sync-paper/notes.md` exists, read it for how this repo runs and previews its apps. Read the app's agent instructions before judging its diffs.

The sync is **patch**, never recapture: artboards keep their layers and sample data, and only what the diff changed moves. Real data from the app stays out of Paper.

Anything you cannot patch safely becomes an **open item**: one line naming the artboard, the commit and the reason. Open items are how the baseline can advance without losing work, so resolve each one or record it. Make every judgement call yourself, including when the run is unattended; the report is where the user sees them.

## 1. Load the state

Load Paper's guide (`get_guide` with topic `paper-mcp-instructions`). If a Paper call fails, stop and report it with the baseline unchanged, because the client may be down.

The **baseline** is the commit Paper was last synced to, stored in Paper so a sync needs no PR. It is on the map's page, in a text node inside the "00 Sync" artboard reading `Synced to <sha>`. Find it with `find_nodes`, `textValue: "Synced to *"` and the map's `pageId`, since one Paper file can hold several apps and `get_basic_info` lists only the first 100 artboards. Open items from earlier runs sit below it in the same artboard.

- `--from <commit>` overrides the baseline.
- If there is no baseline and no `--from`, stop and ask for the starting commit.

Fetch the default branch from `origin`. The **target** is that remote branch, because the local one can be far behind. Record its SHA now and use it for the whole run. If it equals the baseline and there are no open items, report that and stop.

Done when: you hold the baseline SHA, the target SHA and the list of open items.

## 2. Triage the commits

List the commits with `git log --first-parent --format='%h %s' <baseline>..<target> -- <the map's uiPaths and shared paths>`, then read each with `git show`. Give each one a verdict:

- **invisible**: a user sees no difference (API routes, tests, data fetching, performance).
- **visible**: write down each visible change in one line, in terms of the screen ("the Transcript tab's insight label now shows the creator-relative band").

Judge from the diff, not the commit title: `feat` and `perf` titles often hide either kind.

Done when: every listed commit has a verdict, and every visible commit has its list of changes.

## 3. Compare with the artboards

Match each visible change to screens through the map's `paths`, and take every artboard the change appears on, desktop and mobile. For `shared` paths, grep the app for importers to learn which screens are affected. A file matching no path is an open item, and so is an artboard ID that no longer exists.

Read each artboard with `get_jsx` and give it one verdict per change:

- **stale**: it shows the old state. Patch it.
- **current**: it already shows the new state, usually because the screen was built from this design. Leave it.
- **diverged**: it shows neither state, so the user may be designing on it. Open item.

An element that renders only in some conditions (a collaborator, a deleted-post note) is patched only onto an artboard already showing that condition. If no artboard shows it, record an open item.

Next, look for redesigns in progress: search the map's page with `find_nodes` for the copy the diff changed, and read each match's artboard with `get_node_info`. A match whose name contains `(not built)` means an open item for that copy, which you leave as it is. Ignore matches named `(archived)` or `#<issue> before/after`. A change with no copy has nothing to search for, so say in the report that this check did not run.

These become open items instead of patches:

- a change that reaches more than 5 artboards through a shared component, listing the artboards affected;
- a new screen or a restructure that replaces most of an artboard. Propose the map entry it would need in the report.

If the map has a `tokens` entry and the diff touches its `css` file, compare with `get_tokens`, translating names through the entry's `rename` rules. Compare only tokens Paper already has, and change them with `set_tokens`, which also updates every artboard using them. Tokens belong to the whole Paper file, so a map without a `tokens` entry leaves them alone and lists token changes as open items.

Done when: every visible change has a verdict on every artboard it reaches, or an open item.

## 4. Patch

Apply each stale verdict with the smallest operation that expresses it: `set_text_content` for copy, `update_styles` for appearance, `move_nodes` for order, and `write_html` with `<x-paper-clone>` for an added element. Use the file's tokens where it has them, and match neighbouring layers for layer names and sample values. A new element gets invented sample data in the style of the artboard, including when the live app has a real value to hand.

Moving a text node into a new row can leave it with `flex: 1`, which pushes its sibling to the far edge, and `update_styles` does not clear that. To add a sibling beside existing text, replace the text with `write_html` in `replace` mode, copying its font styles. Call `finish_working_on_nodes` when finished.

Done when: every stale verdict is patched, and a `get_jsx` of each edited artboard shows the new state.

## 5. Verify

Screenshot every edited artboard with `get_screenshot` and read it against Paper's review checkpoints.

Then see the change in the running app. Start it the way the repo's notes describe, capture the screen with the `ui-evidence` skill, and compare it with the artboard, at each artboard's width. Compare layout, copy and control states. Values will differ because the app shows real data. Fix any mismatch with another patch. Keep the captures out of Paper, and stop the app when finished.

A state you cannot reach, an app that will not start, or a sign-in you cannot complete is checked against the code instead; say which in the report. Respect any limit the repo sets on writing to shared data, including creating a user to sign in.

Done when: every edited artboard is screenshotted, and each is either matched against the running app or named in the report as checked against code only.

## 6. Record and report

Update the "00 Sync" artboard, as the last write to Paper: set `Synced to <target SHA>`, and below it list every open item, dropping those now resolved. On a first run, create the artboard in free space on the map's page with plain text only, and call `finish_working_on_nodes`.

Report to the user:

- each artboard patched, with what changed and the commit it came from;
- each open item;
- the commits judged invisible, one line each, so a wrong call is easy to spot;
- anything checked against code only, and any check that did not run.

A run limited to some screens leaves the baseline where it is, because the other screens still have those commits to come. A later full run sees the patched artboards as current.

Done when: the baseline reads the target SHA, and every commit in the range appears in the report.
