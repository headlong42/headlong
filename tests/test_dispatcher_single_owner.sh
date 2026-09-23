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

test_shim_crash_mid_send_recovers() {
    # Hook-independent crash between the claim and the send. No
    # THINKERS_TEST_DIE_AFTER_CLAIM here: a PATH shim for mv, the command
    # bin/thinkers uses to move a due wake into its claim slot, performs the
    # real move and then kills the dispatcher before it can send. The
    # injection lives entirely in this test file, so the case reproduces the
    # crash window without any test-only hook in bin/thinkers, and it runs
    # against pre-receipt code where the send was swallowed with nothing left
    # behind.
    setup_identity

    local shim="$TMP/shim" shimlog="$TMP/shim.log" crashflag="$TMP/crash.fired"
    local realmv claims
    realmv="$(command -v mv)"
    mkdir -p "$shim"
    : > "$shimlog"

    cat > "$shim/mv" <<SHIM
#!/usr/bin/env bash
# Crash injection for test_shim_crash_mid_send_recovers: run the real mv, then
# kill the dispatcher right after it claims a due wake and before it sends.
printf 'mv %s\n' "\$*" >> "\$SHIM_LOG"
"\$SHIM_REAL_MV" "\$@"; rc=\$?
src="\$1"; dst="\${!#}"
case "\$dst" in
  */claimed/*)
    case "\$src" in
      *.wake_at)
        printf 'crash-injected ppid=%s src=%s dst=%s\n' "\$PPID" "\$src" "\$dst" >> "\$SHIM_LOG"
        : > "\$SHIM_CRASH_FLAG"
        kill -9 "\$PPID" 2>/dev/null
        ;;
    esac
    ;;
esac
exit \$rc
SHIM
    chmod +x "$shim/mv"

    # The dispatcher runs with our shim first on PATH, so its claim mv is the
    # injected one. The shim is not exported to the fake thinker step.
    env_run env PATH="$shim:$PATH" \
        SHIM_REAL_MV="$realmv" SHIM_LOG="$shimlog" SHIM_CRASH_FLAG="$crashflag" \
        THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 2

    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    sleep 3

    if [[ -f "$crashflag" ]]; then
        ok "the shim crash fires between the claim and the send"
    else
        bad "the shim crash fires between the claim and the send" \
            "no crash flag, shim log: $(tr '\n' ' ' < "$shimlog" 2>/dev/null)"
    fi

    if [[ "$(record_count)" -eq 0 ]]; then
        ok "the crash swallows the send, nothing dispatches"
    else
        bad "the crash swallows the send, nothing dispatches" "record count $(record_count)"
    fi

    claims=$(find "$RUN/claimed" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$claims" -eq 1 ]]; then
        ok "the crash leaves the claim receipt behind as evidence"
    else
        bad "the crash leaves the claim receipt behind as evidence" "claims=$claims"
    fi

    # Recovery: a fresh dispatcher sweeps the orphaned claim and fires it.
    env_run thinkers stop >/dev/null 2>&1 || true
    env_run env THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 5

    if [[ "$(record_count)" -eq 1 ]]; then
        ok "the next dispatcher fires the recovered send exactly once"
    else
        bad "the next dispatcher fires the recovered send exactly once" \
            "record count $(record_count): $(tr '\n' ' ' < "$TMP/id/record" 2>/dev/null)"
    fi

    claims=$(find "$RUN/claimed" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$claims" -eq 0 && ! -f "$RUN/napper.wake_at" ]]; then
        ok "the recovered send leaves no claim receipt and no wake file"
    else
        bad "the recovered send leaves no claim receipt and no wake file" \
            "claims=$claims wake=$([[ -f "$RUN/napper.wake_at" ]] && echo yes || echo no)"
    fi

    env_run thinkers stop >/dev/null 2>&1
}

test_many_starts_one_dispatch
test_lock_is_held
test_tokens_unique
test_die_after_claim_recovers
test_shim_crash_mid_send_recovers

printf 'cases: pass=%d fail=%d skip=0\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
