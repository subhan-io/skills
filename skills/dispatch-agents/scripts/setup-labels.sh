#!/usr/bin/env bash
# setup-labels.sh [--dry-run] — create every label the pipeline needs in the current repo.
#
# The labels ARE the state store: an issue with no APP_LABEL is invisible to tick-state.sh, a
# missing READY_LABEL means nothing is ever dispatchable, and a missing REVIEW_LABEL means
# finished PRs silently keep consuming a concurrency slot. Run this once per repo during
# onboarding, before the first tick.
#
# Idempotent: existing labels are reported and left exactly as they are — never recoloured or
# re-described, because a human who tuned a label's colour outranks these defaults, and a repo
# that already had `ready-for-agent` must not have its board reshuffled by an onboarding script.
# Names come from the resolved config, so a repo that renames a label in
# .claude/dispatch-agents.env gets its own names created, not these.
#
# Exit codes: 0 all labels present (created or pre-existing) | 1 one or more creations failed.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) die "usage: setup-labels.sh [--dry-run]" ;;
  esac
done

SLUG="$(repo_slug)"

# name<TAB>colour<TAB>description. Colours mirror the pipeline's first two repos so a board
# reads the same everywhere: green = ready, yellow = in flight, teal = human queue,
# bright green = deploy, red = needs a human, purple = app scope.
LABELS=$(cat <<EOF
$APP_LABEL	7057ff	Issues and PRs scoped to the $APP_LABEL app
$READY_LABEL	0E8A16	Triaged, ready to be picked up by an agent
$CLAIM_LABEL	FBCA04	Claimed by an orchestrated agent
$REVIEW_LABEL	0D5C63	Green + adversarially reviewed — human review queue
$PREVIEW_LABEL	06ED7A	Deploy a preview of $APP_LABEL from a PR
$CONFLICT_LABEL	B60205	Rebase hit a conflict only a human can resolve — auto-rebase stopped
$CRITICAL_LABEL	D93F0B	Architecturally load-bearing — dispatch this issue to the top model tier
EOF
)

existing="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"

created=0; present=0; failed=0
while IFS=$'\t' read -r name colour desc; do
  [ -n "$name" ] || continue
  if printf '%s\n' "$existing" | grep -Fxq "$name"; then
    echo "present  $name"
    present=$((present + 1))
    continue
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "would create  $name  #$colour  — $desc"
    created=$((created + 1))
    continue
  fi
  # No --force: it would overwrite a label that appeared between the list above and now, and a
  # concurrent creation means someone else already claimed the name. One attempt, output kept.
  if out=$(gh label create "$name" --color "$colour" --description "$desc" 2>&1); then
    echo "created  $name  #$colour"
    created=$((created + 1))
  elif printf '%s' "$out" | grep -qi "already exists"; then
    echo "present  $name  (raced)"
    present=$((present + 1))
  else
    echo "FAILED   $name — $(printf '%s' "$out" | tail -1)" >&2
    failed=$((failed + 1))
  fi
done <<< "$LABELS"

echo
if [ "$DRY_RUN" = true ]; then
  echo "$SLUG: $created would be created, $present already present (dry run — nothing changed)"
else
  echo "$SLUG: $created created, $present already present, $failed failed"
fi
[ "$failed" -eq 0 ] || exit 1
