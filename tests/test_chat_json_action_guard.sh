#!/usr/bin/env bash
# tests/test_chat_json_action_guard.sh — `chat send` refuses a structured
# JSON action object as a message body (bin/chat `_refuse_json_body`), the
# guard added in PR 149 after the responder's model returned
# {"action":"no_reply","message":""} padded with whitespace and six copies
# reached a Slack thread.
#
# Usage: tests/test_chat_json_action_guard.sh
#
# Builds a throwaway trajectory, then checks: a plain JSON action object is
# refused with a non-zero exit and no message step written; fenced,
# single-quoted, BOM/CR-prefixed, and whitespace-padded variants are all
# refused; an action key on the 40th line is caught while one on the 41st
# line passes the scan window; --force overrides the guard; and ordinary
# plain text still sends. No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID CHAT_REPEAT_WINDOW 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=ada
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000c4"
mkdir -p "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf 'default_send_from=%s\n' "$ME" > "$WORK/home/.chatrc"
export CHATRC="$WORK/home/.chatrc"
export CHAT_REPEAT_WINDOW=0

printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00.000Z"}\n' "$TRAJ_ID" > "$TRAJ"

messages() { grep -c '"type":"message"' "$TRAJ"; }

# --- plain JSON action object is refused ------------------------------------
before=$(messages)
if chat send --to slack-C0BMVH6LM4K '{"action":"no_reply","message":""}' >/dev/null 2>&1; then
    bad "plain JSON action object refused (sent when it should not)"
else
    [[ $(messages) -eq "$before" ]] && ok "plain JSON action object refused" \
                                   || bad "plain JSON action object refused (wrote a message)"
fi

# --- whitespace-padded action object (the 2026-09-20/21 failure) ------------
before=$(messages)
padded='  {  "action"  :  "no_reply",  "message"  :  ""  }  '
if chat send --to slack-C0BMVH6LM4K "$padded" >/dev/null 2>&1; then
    bad "whitespace-padded action object refused"
else
    [[ $(messages) -eq "$before" ]] && ok "whitespace-padded action object refused" \
                                   || bad "whitespace-padded action object refused (wrote a message)"
fi

# --- fenced action object ----------------------------------------------------
before=$(messages)
if printf '%s\n' '```json' '{"action":"no_reply","message":""}' '```' \
     | chat send --to slack-C0BMVH6LM4K >/dev/null 2>&1; then
    bad "fenced action object refused"
else
    [[ $(messages) -eq "$before" ]] && ok "fenced action object refused" \
                                   || bad "fenced action object refused (wrote a message)"
fi

# --- single-quoted action key ------------------------------------------------
before=$(messages)
if chat send --to slack-C0BMVH6LM4K "{'action':'no_reply','message':''}" >/dev/null 2>&1; then
    bad "single-quoted action key refused"
else
    [[ $(messages) -eq "$before" ]] && ok "single-quoted action key refused" \
                                   || bad "single-quoted action key refused (wrote a message)"
fi

# --- BOM + CR prefix ---------------------------------------------------------
before=$(messages)
bom_cr=$(printf '\xef\xbb\xbf{"action":"no_reply","message":""}\r\n')
if chat send --to slack-C0BMVH6LM4K "$bom_cr" >/dev/null 2>&1; then
    bad "BOM/CR-prefixed action object refused"
else
    [[ $(messages) -eq "$before" ]] && ok "BOM/CR-prefixed action object refused" \
                                   || bad "BOM/CR-prefixed action object refused (wrote a message)"
fi

# --- action key on line 40 (inside the window) -------------------------------
before=$(messages)
{
    printf '{'
    for i in $(seq 1 39); do printf '  "pad%d": 0,\n' "$i"; done
    printf '  "action": "no_reply"\n}'
} > "$WORK/line40.json"
if chat send --to slack-C0BMVH6LM4K < "$WORK/line40.json" >/dev/null 2>&1; then
    bad "action key on line 40 refused"
else
    [[ $(messages) -eq "$before" ]] && ok "action key on line 40 refused" \
                                   || bad "action key on line 40 refused (wrote a message)"
fi

# --- action key on line 41 (past the window, NOT refused) --------------------
before=$(messages)
{
    printf '{'
    for i in $(seq 1 40); do printf '  "pad%d": 0,\n' "$i"; done
    printf '  "action": "no_reply"\n}'
} > "$WORK/line41.json"
if chat send --to slack-C0BMVH6LM4K < "$WORK/line41.json" >/dev/null 2>&1; then
    [[ $(messages) -eq $((before + 1)) ]] && ok "action key on line 41 passes the 40-line window" \
                                        || bad "action key on line 41 passes the 40-line window (no message written)"
else
    bad "action key on line 41 passes the 40-line window (refused)"
fi

# --- --force overrides --------------------------------------------------------
before=$(messages)
if chat send --force --to slack-C0BMVH6LM4K '{"action":"no_reply","message":""}' >/dev/null 2>&1; then
    [[ $(messages) -eq $((before + 1)) ]] && ok "--force overrides the guard" \
                                        || bad "--force overrides the guard (no message written)"
else
    bad "--force overrides the guard (refused)"
fi

# --- plain text still sends ---------------------------------------------------
before=$(messages)
if chat send --to slack-C0BMVH6LM4K "hello there" >/dev/null 2>&1; then
    [[ $(messages) -eq $((before + 1)) ]] && ok "plain text still sends" \
                                        || bad "plain text still sends (no message written)"
else
    bad "plain text still sends (refused)"
fi

echo ""
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
