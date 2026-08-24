#!/usr/bin/env bash
# codex-wait.sh — request a Codex review and know when it has actually finished.
#
# Codex is not a GitHub check: there is no run to wait on and nothing in `gh pr checks` will
# ever reflect it. You post the "@codex review" trigger, the review lands minutes later, and the
# only completion signal is that the bot has gone quiet.
#
# It lands in one of TWO shapes, and you do not get to pick which:
#   - a PR review (state COMMENTED) plus inline comments — when it has findings
#   - a plain issue comment                              — when it does not ("no major issues")
# Both carry the "Reviewed commit:" line. Watching only one of them is how you time out waiting
# for a review that already arrived.
#
#   codex-wait.sh status   <pr> [--quiet]  # JSON snapshot (--quiet = bare state word)
#   codex-wait.sh request  <pr> [--force]  # post the "@codex review" trigger comment
#   codex-wait.sh watch    <pr>            # block until settled — RUN IT BACKGROUNDED
#   codex-wait.sh findings <pr> [--all]    # inline findings for the head commit
#
# state:
#   not-requested — no trigger newer than the head commit, and no review covering it
#   awaiting      — trigger posted for this head commit, nothing back yet
#   arriving      — a review covering head exists but codex spoke <settle window> ago
#   settled       — review covers head and codex has been quiet for the settle window
#
# TWO RULES THIS SCRIPT EXISTS TO ENFORCE, both learned the hard way in dispatch-agents:
#
#   1. Do not read an `arriving` review. Codex posts its inline comments in BURSTS after the
#      review body, so a short quiet window (10s, say) reads a truncated finding set and the
#      resolver silently fixes half the review. 120s of silence is the real signal.
#   2. "Covers head" is decided by the `**Reviewed commit:** <sha>` line in the review body,
#      NOT by timestamps. A review of the pre-rework commit is not a review of this PR.
#   3. An inline finding's `.commit_id` is ADVANCED by GitHub as the head moves, so a finding
#      raised two rounds ago reports the current head and reads as new. `.original_commit_id`
#      is where it was actually raised — `findings` reports that as `raisedOn`.
#   4. Prior resolution is evidenced by a reply carrying the "(resolver, round N)" marker, NOT
#      by the thread merely having replies in it: a human asking codex a follow-up question is
#      a reply too, and treating that as "already handled" silently drops a live finding.
#      `replyCount` is conversation; `resolverReplyCount` (and `counts.unresolved`) is the one
#      to branch on.
#
# Exit codes: 0 ok | 4 watch timed out | 5 request refused (already requested) | 1 other.
set -euo pipefail
source "$(dirname "$0")/common.sh"

: "${CODEX_BOT:=chatgpt-codex-connector[bot]}"
: "${CODEX_TRIGGER:=@codex review}"
: "${CODEX_SETTLE_SECONDS:=120}"   # quiet period after the last codex comment before reading
: "${CODEX_TIMEOUT_SECONDS:=900}"  # watch gives up after this rather than blocking forever
: "${CODEX_POLL_SECONDS:=30}"      # remote API — do not poll tighter

CMD="${1:-}"; PR="${2:-}"
[ -n "$CMD" ] && [ -n "$PR" ] || die "usage: codex-wait.sh status|request|watch|findings <pr> [opts]"
shift 2 || true
FORCE=false; ALL=false; QUIET=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --all)   ALL=true ;;
    --quiet) QUIET=true ;;
    *) die "unknown option: $arg" ;;
  esac
done
SLUG="$(repo_slug)"

# `gh api --paginate` emits one JSON array PER PAGE, so past the first page the captured value is
# several adjacent arrays — not a JSON value, and `jq --argjson` rejects it outright. Slurping and
# flattening here keeps every caller a single valid array. Done with jq rather than gh's own
# `--slurp` so this does not require a recent gh.
api_list() { gh api "$1" --paginate | jq -s 'add // []'; }

snapshot() {
  local head head_at reviews comments issue_comments
  head=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
  head_at=$(gh api "repos/$SLUG/commits/$head" --jq '.commit.committer.date')
  reviews=$(api_list "repos/$SLUG/pulls/$PR/reviews")
  comments=$(api_list "repos/$SLUG/pulls/$PR/comments")
  issue_comments=$(api_list "repos/$SLUG/issues/$PR/comments")

  jq -n \
    --argjson pr "$PR" --arg head "$head" --arg headAt "$head_at" --arg bot "$CODEX_BOT" \
    --arg trigger "$CODEX_TRIGGER" --argjson settle "$CODEX_SETTLE_SECONDS" \
    --argjson reviews "$reviews" --argjson comments "$comments" --argjson ic "$issue_comments" '
    ($reviews  | map(select(.user.login == $bot))) as $crev
  | ($comments | map(select(.user.login == $bot))) as $ccom
  | ($ic       | map(select(.user.login == $bot))) as $cic
  # Codex delivers its verdict in EITHER shape, and which one you get is not yours to choose:
  # a PR review (state COMMENTED, with inline comments) when it has findings, or a plain issue
  # comment when it does not. Both carry the "Reviewed commit:" line. Reading only reviews makes
  # a comment-shaped verdict invisible, so `watch` sits in `awaiting` for its whole timeout while
  # the review is already sitting on the PR.
  # A review carries the commit it judged as metadata (.commit_id); an issue comment can only say
  # so in prose. Trust the metadata first and fall back to the body, because codex does not always
  # include the "Reviewed commit:" line — a body-only reading calls a review of head uncovered and
  # waits forever for one that already exists.
  | (($crev | map({at: .submitted_at, body: (.body // ""), cid: (.commit_id // null)}))
     + ($cic | map({at: .created_at,  body: (.body // ""), cid: null}))
     | map(. + {sha: (([ .body | capture("Reviewed commit:[^\n]*?(?<sha>[0-9a-f]{7,40})").sha ] | first) // .cid)}))
      as $revs
  | ($revs | map(select(.sha as $s | $s != null and ($head | startswith($s))))) as $headRevs
  # Match the trigger only on comments the bot did not write: codex repeats the literal
  # "@codex review" string in its own help footer, so an unfiltered match reads that reply
  # as a fresh request and reports lastRequestAt as LATER than the request that caused it.
  | ([ $ic[] | select(.user.login != $bot)
             | select((.body // "") | test($trigger; "i")) | .created_at ] | sort | last) as $requestedAt
  | ((($crev | map(.submitted_at)) + ($ccom | map(.created_at)) + ($cic | map(.created_at)))
      | sort | last) as $activityAt
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
    # Bare trigger, no authorship tag: the connector matches on the comment body.
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
        echo "PR #$PR codex review TIMEOUT after ${CODEX_TIMEOUT_SECONDS}s in state '$st'"
        exit 4
      fi
      sleep "$CODEX_POLL_SECONDS"
    done
    ;;

  findings)
    head=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
    reviews=$(api_list "repos/$SLUG/pulls/$PR/reviews")
    comments=$(api_list "repos/$SLUG/pulls/$PR/comments")
    issue_comments=$(api_list "repos/$SLUG/issues/$PR/comments")
    jq -n --argjson pr "$PR" --arg head "$head" --arg bot "$CODEX_BOT" --argjson all "$ALL" \
      --argjson reviews "$reviews" --argjson comments "$comments" --argjson ic "$issue_comments" '
      # Codex badge priorities mapped onto a plain severity scale for the resolver.
      def sev: if . == "1" then "blocker" elif . == "2" then "major" else "note" end;
      # Replies live in the same collection, pointing back at the finding they answer. Count them
      # two ways on purpose: ANY reply is just conversation — the author asking codex a follow-up
      # question is a reply — while a reply carrying the resolver round marker is the only thing
      # that evidences a previous round having actually resolved the finding. Conflating them
      # lets a live finding be skipped because somebody spoke in its thread.
      ($comments | map(select(.in_reply_to_id != null))) as $allReplies
    | ($allReplies | group_by(.in_reply_to_id)
                   | map({key: (.[0].in_reply_to_id | tostring), value: length}) | from_entries) as $replies
    | ($allReplies | map(select((.body // "") | test("\\(resolver, round"; "i")))
                   | group_by(.in_reply_to_id)
                   | map({key: (.[0].in_reply_to_id | tostring), value: length}) | from_entries) as $resolved
    | ($comments
        | map(select(.user.login == $bot and .in_reply_to_id == null))
        | map(select($all or .position != null))
        | map((.body // "") as $b | {
            id, path, line: (.line // .original_line),
            severity: (([ $b | capture("badge/P(?<p>[0-9])").p ] | first | if . == null then "note" else sev end)),
            title: (([ $b | capture("</sub></sub>\\s*(?<t>[^*\n]+)").t ] | first) // ($b | split("\n")[0])),
            outdated: (.position == null),
            # GitHub ADVANCES .commit_id as head moves, so it says "fresh" about a finding raised
            # two rounds ago. .original_commit_id is where it was actually raised and is the only
            # field that distinguishes a new finding from one a previous round already fixed.
            raisedOn: .original_commit_id,
            staleAgainstHead: (.original_commit_id != $head),
            replyCount: ($replies[(.id | tostring)] // 0),
            resolverReplyCount: ($resolved[(.id | tostring)] // 0),
            url: .html_url,
            body: $b })) as $f
    # Review bodies come from both delivery shapes, for the same reason as in snapshot().
    | (($reviews | map(select(.user.login == $bot))
                 | map({at: .submitted_at, body: (.body // ""), cid: (.commit_id // "")}))
       + ($ic | map(select(.user.login == $bot))
              | map({at: .created_at, body: (.body // ""), cid: ""}))
        | map(select((.cid == $head)
                     or (.body | test("Reviewed commit:[^\n]*?" + $head[0:10])) or $all))
        | map({submittedAt: .at,
               body: (.body | gsub("(?s)<details>.*?</details>"; "") | gsub("\n{3,}"; "\n\n"))})) as $r
    | {pr: $pr, headSha: $head, reviewBodies: $r, findings: $f,
       counts: {blocker: ($f | map(select(.severity=="blocker")) | length),
                major:   ($f | map(select(.severity=="major"))   | length),
                note:    ($f | map(select(.severity=="note"))    | length),
                unresolved: ($f | map(select(.resolverReplyCount == 0)) | length)}}'
    ;;

  *) die "unknown command: $CMD" ;;
esac
