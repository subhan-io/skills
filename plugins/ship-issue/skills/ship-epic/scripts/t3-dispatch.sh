#!/usr/bin/env bash
# Dispatch a prompt as a real T3 Code thread — it appears in the sidebar with a
# full live transcript, unlike an Agent-tool subagent or a bare `claude -p`.
#
# Usage:
#   t3-dispatch.sh --project-root <abs-path> --title "ship-issue #23" \
#     --prompt-file <file> [--model <model>] [--worktree <abs-path> --branch <name>]
#   t3-dispatch.sh settle <threadId>     # clear the thread's attention marker
#
# Prints the created threadId on stdout.
#
# Auth: pairs with the local t3 server on first use (t3 pair → /oauth/token)
# and caches the bearer at ~/.local/state/ship-issue/t3-token.json (~30-day
# expiry; re-pairs automatically when a dispatch gets a 401).
set -euo pipefail

MODEL="claude-fable-5"
WORKTREE="" BRANCH="" PROJECT_ROOT="" TITLE="" PROMPT_FILE="" SETTLE_THREAD=""
if [ "${1:-}" = "settle" ]; then SETTLE_THREAD="${2:?settle needs a threadId}"; shift 2; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2;;
    --title) TITLE="$2"; shift 2;;
    --prompt-file) PROMPT_FILE="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --worktree) WORKTREE="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done
if [ -z "$SETTLE_THREAD" ] && { [ -z "$PROJECT_ROOT" ] || [ -z "$TITLE" ] || [ -z "$PROMPT_FILE" ]; }; then
  echo "required: --project-root --title --prompt-file (or: settle <threadId>)" >&2; exit 2
fi

T3_HOME="${T3CODE_HOME:-$HOME/.t3}"
ORIGIN=$(python3 -c "import json;print(json.load(open('$T3_HOME/userdata/server-runtime.json'))['origin'])")
STATE_DIR="$HOME/.local/state/ship-issue"; mkdir -p "$STATE_DIR"
TOKEN_FILE="$STATE_DIR/t3-token.json"

mint_token() {
  local pairing
  pairing=$(t3 pair --label ship-epic-dispatch --ttl 5m 2>/dev/null | sed -n 's/^Token: //p')
  [ -n "$pairing" ] || { echo "t3 pair produced no token (server running?)" >&2; exit 1; }
  curl -fsS -m 10 -X POST "$ORIGIN/oauth/token" \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    --data-urlencode "subject_token=$pairing" \
    --data-urlencode 'subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap' \
    --data-urlencode 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
    --data-urlencode 'client_label=ship-epic-dispatch' > "$TOKEN_FILE"
}

bearer() { python3 -c "import json;print(json.load(open('$TOKEN_FILE'))['access_token'])"; }

dispatch() { # $1 = json payload; prints http code, body to /tmp/t3-dispatch-resp
  curl -sS -m 15 -X POST "$ORIGIN/api/orchestration/dispatch" \
    -H "authorization: Bearer $(bearer)" -H 'content-type: application/json' \
    -d "$1" -o /tmp/t3-dispatch-resp.$$ -w '%{http_code}'
}

[ -f "$TOKEN_FILE" ] || mint_token

uuid() { python3 -c "import uuid;print(uuid.uuid4())"; }

if [ -n "$SETTLE_THREAD" ]; then
  SETTLE="{\"type\":\"thread.settle\",\"commandId\":\"$(uuid)\",\"threadId\":\"$SETTLE_THREAD\"}"
  CODE=$(dispatch "$SETTLE")
  if [ "$CODE" = "401" ]; then mint_token; CODE=$(dispatch "$SETTLE"); fi
  [ "$CODE" = "200" ] || { echo "thread.settle failed ($CODE): $(cat /tmp/t3-dispatch-resp.$$)" >&2; exit 1; }
  rm -f /tmp/t3-dispatch-resp.$$
  exit 0
fi

PROJECT_ID=$(python3 - "$PROJECT_ROOT" <<'EOF'
import json,sqlite3,sys,os
root=os.path.realpath(sys.argv[1])
c=sqlite3.connect(os.path.expanduser(os.environ.get('T3CODE_HOME',os.path.expanduser('~/.t3')))+'/userdata/state.sqlite')
rows=[r for r in c.execute("select project_id,workspace_root from projection_projects where deleted_at is null")]
for pid,ws in rows:
    if os.path.realpath(ws)==root: print(pid); break
else: sys.exit(f"no t3 project with workspace_root {root}")
EOF
)

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
THREAD_ID=$(uuid)
PROMPT=$(python3 -c "import json,sys;print(json.dumps(open(sys.argv[1]).read()))" "$PROMPT_FILE")
BRANCH_JSON=null; [ -n "$BRANCH" ] && BRANCH_JSON="\"$BRANCH\""
WORKTREE_JSON=null; [ -n "$WORKTREE" ] && WORKTREE_JSON="\"$WORKTREE\""

CREATE=$(cat <<EOF
{"type":"thread.create","commandId":"$(uuid)","threadId":"$THREAD_ID",
 "projectId":"$PROJECT_ID","title":$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$TITLE"),
 "modelSelection":{"instanceId":"claudeAgent","model":"$MODEL"},
 "runtimeMode":"full-access","interactionMode":"default",
 "branch":$BRANCH_JSON,"worktreePath":$WORKTREE_JSON,"createdAt":"$NOW"}
EOF
)
CODE=$(dispatch "$CREATE")
if [ "$CODE" = "401" ]; then mint_token; CODE=$(dispatch "$CREATE"); fi
[ "$CODE" = "200" ] || { echo "thread.create failed ($CODE): $(cat /tmp/t3-dispatch-resp.$$)" >&2; exit 1; }

TURN=$(cat <<EOF
{"type":"thread.turn.start","commandId":"$(uuid)","threadId":"$THREAD_ID",
 "message":{"messageId":"$(uuid)","role":"user","text":$PROMPT,"attachments":[]},
 "runtimeMode":"full-access","interactionMode":"default","createdAt":"$NOW"}
EOF
)
CODE=$(dispatch "$TURN")
[ "$CODE" = "200" ] || { echo "thread.turn.start failed ($CODE): $(cat /tmp/t3-dispatch-resp.$$)" >&2; exit 1; }
rm -f /tmp/t3-dispatch-resp.$$
echo "$THREAD_ID"
