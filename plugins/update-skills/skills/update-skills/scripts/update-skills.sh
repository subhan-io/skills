#!/usr/bin/env bash
# update-skills.sh — update every subhan-skills plugin to the latest head,
# for Claude Code, Codex, and Antigravity, with each CLI's native plugin commands.
#
# Claude: refresh the marketplace, then update each installed plugin per scope
# (project-scoped installs update from their own project directory). Codex:
# plugins load from the marketplace snapshot, so one snapshot upgrade updates
# them all. Antigravity: reinstall any installed plugin whose manifest points
# at subhan-io/skills.
set -uo pipefail

MARKETPLACE="${1:-subhan-skills}"
AGY_REPO="${AGY_SKILLS_REPO:-https://github.com/subhan-io/skills}"
fail=0

versions_claude() {
  claude plugin list --json 2>/dev/null \
    | jq -r --arg mp "@$MARKETPLACE" \
        '.[] | select(.id | endswith($mp)) | "\(.id)\t\(.scope)\t\(.version)\t\(.projectPath // "")"' \
    | sort -u
}

echo "== Claude Code =="
if command -v claude >/dev/null 2>&1; then
  before="$(versions_claude)"
  claude plugin marketplace update "$MARKETPLACE" || fail=1
  while IFS=$'\t' read -r id scope _version project_path; do
    [ -n "$id" ] || continue
    echo "-- updating $id (scope: $scope)"
    if [ "$scope" = "project" ] && [ -n "$project_path" ]; then
      (cd "$project_path" && claude plugin update -y -s "$scope" "$id") || fail=1
    else
      claude plugin update -y -s "$scope" "$id" || fail=1
    fi
  done < <(printf '%s\n' "$before")
  echo "-- versions before:"; printf '%s\n' "$before" | cut -f1-3
  echo "-- versions after:";  versions_claude | cut -f1-3
else
  echo "claude CLI not found" >&2; fail=1
fi

echo
echo "== Codex =="
if command -v codex >/dev/null 2>&1; then
  codex plugin marketplace upgrade "$MARKETPLACE" || fail=1
  codex plugin list
else
  echo "codex CLI not found" >&2; fail=1
fi

echo
echo "== Antigravity =="
if command -v agy >/dev/null 2>&1; then
  agy_updated=0
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    manifest=""
    for candidate in "$path/.antigravity-plugin/plugin.json" "$path/plugin.json"; do
      if [ -f "$candidate" ]; then manifest="$candidate"; break; fi
    done
    [ -n "$manifest" ] || continue
    repo="$(jq -r '.repository // ""' "$manifest" 2>/dev/null || true)"
    [ "$repo" = "$AGY_REPO" ] || continue
    echo "-- updating $name"
    if [ "$name" = "$MARKETPLACE" ]; then
      agy plugin install "$AGY_REPO" || fail=1
    else
      agy plugin install "$AGY_REPO/tree/main/plugins/$name" || fail=1
    fi
    agy_updated=$((agy_updated + 1))
  done < <(agy plugin list --json 2>/dev/null | jq -r '.[] | "\(.name)\t\(.path)"')
  if [ "$agy_updated" -eq 0 ]; then
    echo "no $MARKETPLACE plugins installed in agy (run: agy plugin install $AGY_REPO)"
  else
    agy plugin list
  fi
else
  echo "agy CLI not found (skipping)"
fi

exit "$fail"
