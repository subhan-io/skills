#!/usr/bin/env bash
# codex-review.sh — drive the Codex review that gates the adversarial reviewer (SKILL step 2).
#
# Codex reviews are not a GitHub check, so there is no run to wait on: you post the
# "@codex review" trigger comment and the review lands later as a PR review + inline
# comments from the connector bot. This script requests it, tells you whether the review
# in hand covers the PR's *current* head commit, and blocks until it has stopped arriving.
#
#   codex-review.sh status   <pr> [--quiet]  # JSON snapshot (--quiet = bare state word)
#   codex-review.sh request  <pr> [--force]  # post the "@codex review" trigger comment
#   codex-review.sh watch    <pr>            # poll until settled — RUN IT BACKGROUNDED
#   codex-review.sh findings <pr> [--all]    # normalized findings for the head commit
#
# state:
#   not-requested — no "@codex review" comment newer than the head commit, no review for it
#   awaiting      — trigger posted for this head commit, nothing back yet
#   arriving      — a review covering head exists but codex posted <settle window> ago; more
#                   comments may still land, so do not read it yet
#   settled       — review covers head and codex has been quiet for the settle window
#
# "Covers head" is decided by the `**Reviewed commit:** <sha>` line in the review body, not
# by timestamps — a review of the pre-rework commit is not a review of this PR.
#
# Exit codes: 0 ok | 4 watch timed out | 5 request refused (already requested/in hand) | 1 other.
set -euo pipefail
source "$(dirname "$0")/common.sh"

: "${CODEX_BOT:=chatgpt-codex-connector[bot]}"
: "${CODEX_TRIGGER:=@codex review}"
: "${CODEX_SETTLE_SECONDS:=120}"   # quiet period after the last codex comment before reading
: "${CODEX_TIMEOUT_SECONDS:=900}"  # watch gives up after this and hands back to the next tick
: "${CODEX_POLL_SECONDS:=30}"      # remote API — do not poll tighter

CMD="${1:-}"; PR="${2:-}"
[ -n "$CMD" ] && [ -n "$PR" ] || die "usage: codex-review.sh status|request|watch|findings <pr> [opts]"
shift 2 || true
FORCE=false; ALL=false; QUIET=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --all) ALL=true ;;
    --quiet) QUIET=true ;;
    *) die "unknown option: $arg" ;;
  esac
done
SLUG="$(repo_slug)"

snapshot() {
  local head head_at reviews comments issue_comments
  head=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
  head_at=$(gh api "repos/$SLUG/commits/$head" --jq '.commit.committer.date')
  reviews=$(gh api "repos/$SLUG/pulls/$PR/reviews" --paginate)
  comments=$(gh api "repos/$SLUG/pulls/$PR/comments" --paginate)
  issue_comments=$(gh api "repos/$SLUG/issues/$PR/comments" --paginate)

  jq -n \
    --argjson pr "$PR" --arg head "$head" --arg headAt "$head_at" --arg bot "$CODEX_BOT" \
    --arg trigger "$CODEX_TRIGGER" --argjson settle "$CODEX_SETTLE_SECONDS" \
    --argjson reviews "$reviews" --argjson comments "$comments" --argjson ic "$issue_comments" '
    ($reviews | map(select(.user.login == $bot))) as $crev
  | ($comments | map(select(.user.login == $bot))) as $ccom
  | ($crev | map({at: .submitted_at,
                  sha: ([ (.body // "") | capture("Reviewed commit:[^\n]*?(?<sha>[0-9a-f]{7,40})").sha ] | first)}))
      as $revs
  | ($revs | map(select(.sha as $s | $s != null and ($head | startswith($s))))) as $headRevs
  | ([ $ic[] | select((.body // "") | test($trigger; "i")) | .created_at ] | sort | last) as $requestedAt
  | ((($crev | map(.submitted_at)) + ($ccom | map(.created_at))) | sort | last) as $activityAt
  | (if $activityAt == null then null else ((now - ($activityAt | fromdateiso8601)) | floor) end) as $since
  | (if $requestedAt == null then null else ((now - ($requestedAt | fromdateiso8601)) | floor) end) as $sinceReq
  | (($headRevs | length) > 0) as $coversHead
  | (($requestedAt != null)
     and (($requestedAt | fromdateiso8601) > ($headAt | fromdateiso8601))) as $requested
  | (if $coversHead then (if $since >= $settle then "settled" else "arriving" end)
     elif $requested then "awaiting"
     else "not-requested" end) as $state
  | {pr: $pr, state: $state, headSha: $head, headCommittedAt: $headAt,
     reviewCoversHead: $coversHead, requestCoversHead: $requested,
     lastRequestAt: $requestedAt, lastActivityAt: $activityAt,
     secondsSinceActivity: $since, secondsSinceRequest: $sinceReq, settleSeconds: $settle,
     reviewedCommits: ($revs | map(.sha) | map(select(. != null)) | unique),
     liveFindings: ($ccom | map(select(.in_reply_to_id == null and .position != null)) | length),
     bot: $bot}'
}

case "$CMD" in
  status)
    if [ "$QUIET" = true ]; then snapshot | jq -r .state; else snapshot; fi
    ;;

  request)
    state=$(snapshot | jq -r .state)
    if [ "$FORCE" != true ] && [ "$state" != "not-requested" ]; then
      echo "PR #$PR codex state is '$state' — already requested for this head commit; not re-triggering (--force to override)." >&2
      exit 5
    fi
    # Bare trigger, deliberately without the "(orchestrator)" authorship tag: the connector
    # matches on the comment body, so this is the one comment that stays unadorned.
    gh pr comment "$PR" --body "$CODEX_TRIGGER" >/dev/null
    echo "requested codex review on PR #$PR (was: $state)"
    ;;

  watch)
    deadline=$(( $(date +%s) + CODEX_TIMEOUT_SECONDS ))
    last=""
    while :; do
      snap=$(snapshot 2>/dev/null || echo '{}')   # a rate-limit blip must not kill the watch
      st=$(echo "$snap" | jq -r '.state // "unknown"')
      if [ "$st" != "$last" ]; then
        echo "PR #$PR codex review: $st"
        last="$st"
      fi
      if [ "$st" = "settled" ]; then
        echo "PR #$PR codex review SETTLED — $(echo "$snap" | jq -r .liveFindings) live inline finding(s) on $(echo "$snap" | jq -r .headSha | cut -c1-10)"
        exit 0
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "PR #$PR codex review TIMEOUT after ${CODEX_TIMEOUT_SECONDS}s in state '$st' — leaving it for a later tick"
        exit 4
      fi
      sleep "$CODEX_POLL_SECONDS"
    done
    ;;

  findings)
    head=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
    reviews=$(gh api "repos/$SLUG/pulls/$PR/reviews" --paginate)
    comments=$(gh api "repos/$SLUG/pulls/$PR/comments" --paginate)
    jq -n --argjson pr "$PR" --arg head "$head" --arg bot "$CODEX_BOT" --argjson all "$ALL" \
      --argjson reviews "$reviews" --argjson comments "$comments" '
      # P1 → blocker, P2 → major, P3 → note: codex badge priorities mapped onto the
      # verdict schema severities so the reviewer can fold them in without re-inventing a scale.
      def sev: if . == "1" then "blocker" elif . == "2" then "major" else "note" end;
      ($comments
        | map(select(.user.login == $bot and .in_reply_to_id == null))
        | map(select($all or .position != null))
        | map((.body // "") as $b | {
            id, path, line: (.line // .original_line),
            priority: ([ $b | capture("badge/P(?<p>[0-9])").p ] | first),
            severity: (([ $b | capture("badge/P(?<p>[0-9])").p ] | first | if . == null then "note" else sev end)),
            title: (([ $b | capture("</sub></sub>\\s*(?<t>[^*\n]+)").t ] | first) // ($b | split("\n")[0])),
            commitId: .commit_id,
            outdated: (.position == null),
            staleAgainstHead: (.commit_id != $head),
            url: .html_url,
            body: $b })) as $f
    | ($reviews
        | map(select(.user.login == $bot))
        | map(select(((.body // "") | test("Reviewed commit:[^\n]*?" + $head[0:10])) or $all))
        | map({submittedAt: .submitted_at,
               body: ((.body // "") | gsub("(?s)<details>.*?</details>"; "") | gsub("\n{3,}"; "\n\n"))})) as $r
    | {pr: $pr, headSha: $head, reviewBodies: $r, findings: $f,
       counts: {blocker: ($f | map(select(.severity=="blocker")) | length),
                major:   ($f | map(select(.severity=="major"))   | length),
                note:    ($f | map(select(.severity=="note"))    | length)}}'
    ;;

  *) die "unknown command: $CMD" ;;
esac
