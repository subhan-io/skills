# Drafting an app's map

Write `<repo>/.claude/sync-paper/maps/<app>.json`, named after the app's directory, and leave committing it to the user. Copy the shape of an existing map if the repo has one.

| Field | Holds |
| --- | --- |
| `app` | The app's directory, such as `apps/prep-list`. |
| `fileId`, `pageId` | The Paper file and the page holding this app's shipped screens. |
| `uiPaths` | Directories whose commits to triage. |
| `shared` | Globs for code used across screens: the app shell, its CSS, a shared UI package. |
| `tokens` | Optional. `css` is the file defining the tokens; `rename` translates its names to Paper's, such as `{":root --x": "--color-x", "--radius-*": "unchanged"}`. |
| `screens` | One entry per screen: `name`, `route`, `paths`, and `artboards` as name → ID. |

## Steps

1. **Find the Paper file.** Run `list_resources` and read each candidate's pages with `get_basic_info`. One file can hold several apps on separate pages, so match on what the artboards show, not only the file name. If no file clearly matches, stop and ask.
2. **List the artboards.** `get_basic_info` and `get_children` stop at 100. To reach the rest, use `find_nodes` for copy from the app's routes, and `get_node_info` on a match for its `artboardId`.
3. **Find the UI code.** Read the app's layout: some apps keep it under `src/`. Set `uiPaths` to its route and component directories, and leave out API routes.
4. **Map each screen.** Pair each route with the artboards that show it, desktop and mobile, and with the code paths that render it. A map entry is a claim that the artboard shows what is shipped, so check the route exists on the remote default branch first. Leave out `(not built)`, `(archived)` and before/after artboards, explorations, and artboards for routes that no longer exist.
5. **Decide on tokens.** Add `tokens` only if Paper's file has tokens and this app owns them. Tokens apply to the whole Paper file, so when a file holds several apps, give the entry to one app at most. Read the CSS to write `rename`: apps define tokens differently, and an app's `@theme` block may be unused.

Done when: every route in the app is either mapped or listed in your report as having no artboard, and every listed artboard was left out for a stated reason.

Report the map's gaps and your judgement calls, then stop. The first sync runs after the user has reviewed the map.
