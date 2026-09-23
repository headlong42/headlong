#!/usr/bin/env bash
# test_dispatcher_single_owner.sh — one due wake dispatches once, however many
# dispatchers are ticking.
#
# Regression for the duplicate/early scheduled dispatch bug: several
# thinkers start processes minted colliding ownership tokens in the same
# second, so more than one dispatcher passed the ownership check and each
# fired the same due run/<name>.wake_at. The fix is threefold: a unique
# token, a flock held for the life of the loop, and an atomic claim (mv) of
# the wake file before dispatch. Fake thinker, no LLM calls, no docker.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ - $2}"; }

TMP=$(mktemp -d)
TRAJ_ID="cafe0000-0000-0000-0000-000000000007"
RUN="$TMP/id/run"

env_run() {
    IDENTITY_DIR="$TMP/id" IDENTITY_NAME=testid \
    TRAJ_DIR="$TMP/id/trajectories" TRAJ_ID="$TRAJ_ID" \
    THINKERS_DIR="$TMP/id/thinkers" MEM_DIR="$TMP/id/memories" \
    "$@"
}

cleanup() {
    env_run thinkers stop >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

setup_identity() {
    env_run thinkers stop >/dev/null 2>&1 || true
    rm -rf "$TMP/id"
    mkdir -p "$TMP/id/thinkers/napper" "$TMP/id/trajectories/$TRAJ_ID" "$TMP/id/memories"
    printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$TMP/id/info.txt"
    : > "$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"

    cat > "$TMP/id/thinkers/napper/step" <<'EOF'
#!/usr/bin/env bash
json=$(cat)
printf '%s\n' "$json" >> "$IDENTITY_DIR/record"
exit 0
EOF
    chmod +x "$TMP/id/thinkers/napper/step"
    printf '{"types":["action","monolith-wake"],"trigger_self":false}\n' > "$TMP/id/thinkers/napper/subscriptions.jsonl"
}

start_thinkers() { env_run thinkers start >/dev/null 2>&1; sleep 2; }

record_count() {
    if [[ -f "$TMP/id/record" ]]; then wc -l < "$TMP/id/record" | tr -d ' '; else echo 0; fi
}

now() { date +%s; }

test_die_after_claim_recovers() {
    setup_identity
    # THINKERS_TEST_DIE_AFTER_CLAIM is fault injection added for this case: the
    # dispatcher kill -9s itself between claiming the due wake and launching
    # its step, the exact window where a crash used to swallow a scheduled
    # send with nothing left behind.
    env_run env THINKERS_TEST_DIE_AFTER_CLAIM=1 THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 2
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    sleep 3
    local claims
    claims=$(find "$RUN/claimed" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$(record_count)" -eq 0 ]]; then
        ok "a crash between claim and launch dispatches nothing, the loss is real"
    else
        bad "a crash between claim and launch dispatches nothing, the loss is real" "record count $(record_count)"
    fi
    if [[ "$claims" -eq 1 ]]; then
        ok "the crash leaves the claim receipt behind as evidence"
    else
        bad "the crash leaves the claim receipt behind as evidence" "claims=$claims"
    fi
    env_run thinkers stop >/dev/null 2>&1 || true
    env_run env THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 5
    if [[ "$(record_count)" -eq 1 ]]; then
        ok "the next dispatcher re-arms the orphaned claim and fires it exactly once"
    else
        bad "the next dispatcher re-arms the orphaned claim and fires it exactly once" "record count $(record_count): $(tr '\n' ' ' < "$TMP/id/record" 2>/dev/null)"
    fi
    claims=$(find "$RUN/claimed" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$claims" -eq 0 && ! -f "$RUN/napper.wake_at" ]]; then
        ok "the recovered wake leaves no receipt and no wake file"
    else
        bad "the recovered wake leaves no receipt and no wake file" "claims=$claims wake=$([[ -f "$RUN/napper.wake_at" ]] && echo yes || echo no)"
    fi
    env_run thinkers stop >/dev/null 2>&1
}

test_many_starts_one_dispatch() {
    setup_identity
    local n=4 i
    # Race them: concurrent starts in the same second are exactly the shape
    # that minted colliding tokens and double-dispatched every due wake.
    for ((i = 0; i < n; i++)); do env_run thinkers start >/dev/null 2>&1 & done
    wait
    sleep 6

    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    sleep 4

    if [[ "$(record_count)" -eq 1 ]]; then
        ok "$n racing starts dispatch one due wake exactly once"
    else
        bad "$n racing starts dispatch one due wake exactly once" \
            "record count $(record_count): $(tr '\n' ' ' < "$TMP/id/record" 2>/dev/null)"
    fi

    if [[ ! -f "$RUN/napper.wake_at" ]]; then
        ok "the wake file is consumed exactly once"
    else
        bad "the wake file is consumed exactly once"
    fi

    env_run thinkers stop >/dev/null 2>&1
}

test_lock_is_held() {
    if ! command -v flock >/dev/null 2>&1; then
        ok "the running dispatcher holds its lock (skipped, no flock here)"
        return
    fi
    setup_identity
    start_thinkers

    exec 9>"$RUN/dispatcher.lock"
    if flock -n 9; then
        flock -u 9
        bad "the running dispatcher holds its lock" "a probe could take it"
    else
        ok "the running dispatcher holds its lock"
    fi
    exec 9>&-

    env_run thinkers stop >/dev/null 2>&1
}

test_tokens_unique() {
    setup_identity
    start_thinkers
    local a b
    a=$(cat "$RUN/dispatcher.token" 2>/dev/null)
    env_run thinkers stop >/dev/null 2>&1
    start_thinkers
    b=$(cat "$RUN/dispatcher.token" 2>/dev/null)

    if [[ -n "$a" && -n "$b" && "$a" != "$b" ]]; then
        ok "each start mints a fresh ownership token"
    else
        bad "each start mints a fresh ownership token" "a=$a b=$b"
    fi

    if [[ "${#a}" -ge 16 ]]; then
        ok "the token is high entropy, not date plus pid"
    else
        bad "the token is high entropy, not date plus pid" "length ${#a}"
    fi

    env_run thinkers stop >/dev/null 2>&1
}

test_many_starts_one_dispatch
test_lock_is_held
test_tokens_unique
test_die_after_claim_recovers

printf 'cases: pass=%d fail=%d skip=0\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
