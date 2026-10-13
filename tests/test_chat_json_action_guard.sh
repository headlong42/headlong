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
# plain text still sends. Large stdin bodies exercise send and reply without
# SIGPIPE; incoming human JSON is preserved. No LLM calls, no docker.

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

WORK=$(mktemp -d) || exit 1
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

# Check the reason as well as the exit: SIGPIPE is not an intentional refusal.
refuses_file() {
    local label="$1" body="$2" before rc
    shift 2
    before=$(messages)
    chat "$@" < "$body" > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
    if [[ $rc -eq 1 && $(messages) -eq "$before" ]] \
        && grep -F 'this message is a structured action object' "$WORK/stderr" >/dev/null; then
        ok "$label"
    else
        bad "$label" "rc=$rc; messages=$(messages), expected=$before"
    fi
}

sends_file() {
    local label="$1" body="$2" before rc
    shift 2
    before=$(messages)
    chat "$@" < "$body" > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
    if [[ $rc -eq 0 && $(messages) -eq $((before + 1)) ]] \
        && jq -se --rawfile body "$body" 'last | .content == $body' "$TRAJ" >/dev/null; then
        ok "$label"
    else
        bad "$label" "rc=$rc; expected one message with the original body"
    fi
}

# Bigger than a pipe buffer, with no trailing newline (chat strips those).
awk 'BEGIN { print "hello"; for (i=0; i<10000; i++) print "ordinary message line"; printf "end" }' > "$WORK/large-text"
{
    printf '{\n"action":"reply",\n"message":"'
    awk 'BEGIN { for (i=0; i<100000; i++) printf "x" }'
    printf '"\n}'
} > "$WORK/large-action"
printf '%s' '{"action":"no_reply","message":""}' > "$WORK/action"
printf '\n```json\n%s\n```' '{"action":"no_reply","message":""}' > "$WORK/fenced-action"
printf '%s' '{"text":"hello"}' > "$WORK/ordinary-json"
printf 'Example:\n%s' '{"action":"reply"}' > "$WORK/prose"

for cmd in send reply; do
    if [[ "$cmd" == send ]]; then
        args=(--to slack-C0BMVH6LM4K)
    else
        # These are deliberate replies to the same synthetic trigger.
        args=(--follow-up --reply-to guard-test slack-C0BMVH6LM4K)
    fi
    sends_file "$cmd preserves large multiline text" "$WORK/large-text" "$cmd" "${args[@]}"
    refuses_file "$cmd refuses large action with the intended error" "$WORK/large-action" "$cmd" "${args[@]}"
    refuses_file "$cmd refuses compact action" "$WORK/action" "$cmd" "${args[@]}"
    refuses_file "$cmd refuses fenced action" "$WORK/fenced-action" "$cmd" "${args[@]}"
    refuses_file "$cmd refuses action on line 40" "$WORK/line40.json" "$cmd" "${args[@]}"
    sends_file "$cmd permits action on line 41" "$WORK/line41.json" "$cmd" "${args[@]}"
    sends_file "$cmd --force preserves large action" "$WORK/large-action" "$cmd" --force "${args[@]}"
    sends_file "$cmd --force preserves fences and blank lines" "$WORK/fenced-action" "$cmd" --force "${args[@]}"
    sends_file "$cmd preserves JSON without action" "$WORK/ordinary-json" "$cmd" "${args[@]}"
    sends_file "$cmd preserves prose with JSON" "$WORK/prose" "$cmd" "${args[@]}"
done

# Sender resolution must happen before applying an outbound-only policy.
for body in action fenced-action; do
    sends_file "explicit inbound $body reaches the identity" "$WORK/$body" \
        send --from pwa-test --to "$ME"
    printf 'default_send_from=pwa-test\n' > "$CHATRC"
    sends_file "chatrc inbound $body reaches the identity" "$WORK/$body" send
    # An explicit identity sender still gets checked even with an inbound default.
    refuses_file "explicit outbound $body overrides inbound chatrc" "$WORK/$body" \
        send --from "$ME" --to slack-C0BMVH6LM4K
    printf 'default_send_from=%s\n' "$ME" > "$CHATRC"
done

echo ""
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
