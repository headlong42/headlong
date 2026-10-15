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
export SHELLM_ENV=local

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"

pass=0
fail=0
skip=0
skipcase() { skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }
want() { [[ -n "${TEST_FILTER:-}" && "$1" != *"$TEST_FILTER"* ]] && return 0; "$1"; }
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ - $2}"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/dispatcher-owner.XXXXXX") || exit 1
TRAJ_ID="cafe0000-0000-0000-0000-000000000007"
RUN="$TMP/id/run"

env_run() {
    IDENTITY_DIR="$TMP/id" IDENTITY_NAME=testid \
    TRAJ_DIR="$TMP/id/trajectories" TRAJ_ID="$TRAJ_ID" \
    THINKERS_DIR="$TMP/id/thinkers" MEM_DIR="$TMP/id/memories" \
    "$@"
}

cleanup() {
    if [[ -n "${paused_fixture:-}" ]]; then
        printf '%s' "$paused_fixture" > "$RUN/dispatcher.pid"
        kill -CONT "$paused_fixture" 2>/dev/null || true
    fi
    rm -f "$TMP/id/hold"
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

test_crash_after_launch_does_not_double_fire() {
    # The window this closes: the dispatcher claims the due wake, launches the
    # step, and is killed before it clears its receipt. The send has already gone
    # out. If the stale-claim sweep re-arms that receipt the same wake is sent a
    # second time, which is the duplicate post this change exists to stop.
    #
    # The rm shim exercises receipt cleanup in this implementation. A version
    # without receipts does not reach this injection point.
    setup_identity
    local shim="$TMP/shim2" shimlog="$TMP/shim2.log" crashflag="$TMP/crash2.fired"
    local realmv realrm sent_before sent_after leftovers i
    realmv=$(command -v mv)
    realrm=$(command -v rm)
    mkdir -p "$shim"
    : > "$shimlog"
    rm -f "$crashflag"

    cat > "$shim/rm" <<SHIM
#!/usr/bin/env bash
# Crash injection for test_crash_after_launch_does_not_double_fire: the send is
# already out by the time the dispatcher clears its receipt. Kill it here and
# the receipt is left behind, which is exactly what a real crash in that window
# leaves. Exit without running the real rm so the leftover survives.
for _a in "\$@"; do
    case "\$_a" in
        */claimed/napper|*/sent/napper)
            if [[ ! -f "\$SHIM_CRASH_FLAG" ]]; then
                : > "\$SHIM_CRASH_FLAG"
                printf '%s\n' "\$_a" >> "\$SHIM_LOG"
                kill -KILL "\$PPID" 2>/dev/null
                exit 1
            fi
            ;;
    esac
done
exec "\$SHIM_REAL_RM" "\$@"
SHIM
    chmod +x "$shim/rm"

    env_run env PATH="$shim:$PATH" \
        SHIM_REAL_RM="$realrm" SHIM_LOG="$shimlog" SHIM_CRASH_FLAG="$crashflag" \
        THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 2

    printf '%s' "$(( $(now) - 5 ))" > "$RUN/napper.wake_at"
    for ((i = 0; i < 10; i++)); do
        [[ -f "$crashflag" ]] && break
        sleep 1
    done

    if [[ -f "$crashflag" ]]; then
        ok "the dispatcher dies after the send with its receipt still on disk"
    else
        bad "the dispatcher dies after the send with its receipt still on disk" \
            "no crash flag, shim log: $(tr '\n' ' ' < "$shimlog" 2>/dev/null)"
    fi

    sent_before=$(record_count)
    if [[ "$sent_before" -eq 1 ]]; then
        ok "the wake goes out exactly once before the crash"
    else
        bad "the wake goes out exactly once before the crash" "record count $sent_before"
    fi

    # Recover directly: an explicit stop would cancel pending claim receipts.
    env_run env THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 6

    sent_after=$(record_count)
    if [[ "$sent_after" -eq 1 ]]; then
        ok "the next dispatcher does not send the same wake again"
    else
        bad "the next dispatcher does not send the same wake again" \
            "record count $sent_after: $(tr '\n' ' ' < "$TMP/id/record" 2>/dev/null)"
    fi

    leftovers=$(find "$RUN/claimed" "$RUN/sent" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$leftovers" -eq 0 ]]; then
        ok "the leftover receipt is dropped without re-arming the wake"
    else
        bad "the leftover receipt is dropped without re-arming the wake" \
            "leftovers: $(find "$RUN/claimed" "$RUN/sent" -type f 2>/dev/null | tr '\n' ' ')"
    fi

    env_run thinkers stop >/dev/null 2>&1 || true
}

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
    # Recover directly: an explicit stop would cancel pending claim receipts.
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

test_stale_claim_keeps_freshest_wake() {
    setup_identity
    env_run env THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 2
    mkdir -p "$RUN/claimed"
    # A claim is an mv of the wake file, so its content is that wake's own due
    # time, and a crash leaves it behind mtime-old. Plant that leftover for a due
    # time far out, plus a fresher wake_at for the same name due sooner.
    printf '%s' "$(( $(now) + 30 ))" > "$RUN/claimed/napper"
    touch -d '2 minutes ago' "$RUN/claimed/napper" 2>/dev/null || touch -t 202001010000 "$RUN/claimed/napper"
    printf '%s' "$(( $(now) + 2 ))" > "$RUN/napper.wake_at"
    sleep 6
    if [[ "$(record_count)" -eq 1 ]]; then
        ok "a stale claim never clobbers a fresher wake_at, the nearer occurrence fires"
    else
        bad "a stale claim never clobbers a fresher wake_at, the nearer occurrence fires"             "record count $(record_count), wake_at=$(cat "$RUN/napper.wake_at" 2>/dev/null || echo gone)"
    fi
    if [[ ! -f "$RUN/claimed/napper" ]]; then
        ok "the colliding claim is consumed exactly once"
    else
        bad "the colliding claim is consumed exactly once"
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
    # Check after every 15-second lock waiter has had time to settle.
    sleep 18

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
        skipcase "the running dispatcher holds its lock: flock unavailable"
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

test_lock_timeout_exits() {
    if ! command -v flock >/dev/null 2>&1; then
        skipcase "lock timeout: flock unavailable"
        return
    fi
    setup_identity

    # Hold the dispatcher lock from the test process with nobody else to
    # release it. A fresh start blocks its full 15s window on the lock,
    # then exits 0 rather than hanging or firing. The start leaves its own
    # token behind (it takes over first) but never becomes a dispatcher,
    # so nothing must dispatch.
    local i
    mkdir -p "$RUN"
    exec 9>"$RUN/dispatcher.lock"
    flock -x 9 2>/dev/null

    # The lock wait runs in the background child. Startup holds its stdout
    # pipe until setup completes or that child exits. Check the timeout log
    # as well: nothing may dispatch after the failed start.
    env_run thinkers start >/dev/null 2>&1
    local timed_out=0
    for ((i = 0; i < 25; i++)); do
        grep -q "lock timeout waiting for the incumbent - exiting" "$RUN/logs/dispatcher.log" 2>/dev/null && { timed_out=1; break; }
        sleep 1
    done

    if [[ "$timed_out" -eq 1 ]]; then
        ok "a blocked start waits out its lock window and reports the timeout"
    else
        bad "a blocked start waits out its lock window and reports the timeout" "no timeout line after 25s; log: $(tr '\n' ' ' < "$RUN/logs/dispatcher.log" 2>/dev/null)"
    fi

    if [[ "$(record_count)" -eq 0 ]]; then
        ok "a timed-out start never becomes a dispatcher, nothing fires"
    else
        bad "a timed-out start never becomes a dispatcher, nothing fires" "record count $(record_count)"
    fi

    flock -u 9 2>/dev/null
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

    if [[ "$a" =~ ^[0-9a-f]{32}$ && "$b" =~ ^[0-9a-f]{32}$ ]]; then
        ok "tokens contain exactly 16 bytes encoded as hex"
    else
        bad "tokens contain exactly 16 bytes encoded as hex" "a=$a b=$b"
    fi

    env_run thinkers stop >/dev/null 2>&1
}

test_shim_crash_mid_send_recovers() {
    # Hook-independent crash between the claim and the send. No
    # THINKERS_TEST_DIE_AFTER_CLAIM here: a PATH shim for mv, the command
    # bin/thinkers uses to move a due wake into its claim slot, performs the
    # real move and then kills the dispatcher before it can send. The
    # injection lives entirely in this test file, so the case reproduces the
    # crash window without the test-only hook in bin/thinkers. A version
    # without receipts does not reach this injection point.
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
    # Recover directly: an explicit stop would cancel pending claim receipts.
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

test_stale_claim_non_numeric_wake_at() {
    # The two sweep branches that keep a non-numeric wake_at: a claim with
    # a readable due time is re-armed into the wake_at (the empty file is
    # garbage the scheduler would otherwise drop), and a claim with an
    # unreadable due time is dropped outright, leaving the garbage wake_at
    # for the scheduler's own non-numeric cleanup. Both must never fire the
    # occurrence early.
    setup_identity
    env_run env THINKERS_CLAIM_STALE_SECS=1 thinkers start >/dev/null 2>&1
    sleep 2
    mkdir -p "$RUN/claimed"

    # Branch 1: readable claim due time, non-numeric wake_at. The sweep
    # replaces the garbage wake_at with the claim's real due time, so the
    # wake survives as a valid future schedule instead of being dropped by
    # the scheduler's own non-numeric cleanup.
    printf '%s' "$(( $(now) + 600 ))" > "$RUN/claimed/napper"
    touch -d '2 minutes ago' "$RUN/claimed/napper" 2>/dev/null || touch -t 202001010000 "$RUN/claimed/napper"
    printf 'garbage-not-a-time' > "$RUN/napper.wake_at"
    sleep 5

    if [[ "$(cat "$RUN/napper.wake_at" 2>/dev/null)" =~ ^[0-9]+$ ]]; then
        ok "a readable stale claim is re-armed into a garbage wake_at instead of dropped"
    else
        bad "a readable stale claim is re-armed into a garbage wake_at instead of dropped" "wake_at=$(cat "$RUN/napper.wake_at" 2>/dev/null)"
    fi
    if [[ ! -f "$RUN/claimed/napper" ]]; then
        ok "the re-armed claim is consumed exactly once"
    else
        bad "the re-armed claim is consumed exactly once"
    fi
    rm -f "$RUN/napper.wake_at"

    # Branch 2: both claim and wake_at unreadable. The claim is dropped and
    # the garbage wake_at is left for the scheduler, which removes it on its
    # own pass: nothing fires because no due time is readable anywhere.
    printf 'also-garbage' > "$RUN/claimed/napper"
    touch -d '2 minutes ago' "$RUN/claimed/napper" 2>/dev/null || touch -t 202001010000 "$RUN/claimed/napper"
    printf 'still-garbage' > "$RUN/napper.wake_at"
    sleep 5

    if [[ ! -f "$RUN/napper.wake_at" && "$(record_count)" -eq 0 ]]; then
        ok "an unreadable claim leaves a garbage wake_at alone, the scheduler drops it and nothing fires"
    else
        bad "an unreadable claim leaves a garbage wake_at alone, the scheduler drops it and nothing fires" "wake=$( [[ -f "$RUN/napper.wake_at" ]] && cat "$RUN/napper.wake_at" || echo gone) records=$(record_count)"
    fi
    if [[ ! -f "$RUN/claimed/napper" ]]; then
        ok "an unreadable claim is dropped exactly once"
    else
        bad "an unreadable claim is dropped exactly once"
    fi

    env_run thinkers stop >/dev/null 2>&1
}


test_waiter_preserves_incumbent() {
    if ! command -v flock >/dev/null 2>&1; then
        skipcase "incumbent timeout test: flock unavailable"
        return
    fi
    setup_identity
    start_thinkers
    local incumbent token fifo tails i
    incumbent=$(cat "$RUN/dispatcher.pid")
    token=$(cat "$RUN/dispatcher.token")
    fifo=$(cat "$RUN/fifo_path")
    tails=$(cat "$RUN/tail_pids")
    paused_fixture="$incumbent"
    # Freeze only our disposable dispatcher, then simulate its lost PID file.
    # It cannot observe the contender's token while the 15s wait expires.
    kill -STOP "$incumbent"
    rm -f "$RUN/dispatcher.pid"
    printf 'keep' > "$RUN/pending/timeout-sentinel"
    env_run thinkers start >/dev/null 2>&1
    for ((i=0; i<25; i++)); do
        grep -q 'lock timeout waiting' "$RUN/logs/dispatcher.log" && break
        sleep 1
    done
    if [[ -p "$fifo" && -f "$RUN/pending/timeout-sentinel" &&
          -f "$RUN/sub_map" && -f "$RUN/traj_files" && -s "$RUN/dispatcher.token" &&
          "$(cat "$RUN/tail_pids" 2>/dev/null)" == "$tails" &&
          "$(cat "$RUN/fifo_path" 2>/dev/null)" == "$fifo" ]]; then
        ok "timed-out contender preserves incumbent runtime"
    else bad "timed-out contender preserves incumbent runtime"; fi
    # Restore its ownership so the test can prove the preserved loop still works.
    printf '%s' "$token" > "$RUN/dispatcher.token"
    printf '%s' "$incumbent" > "$RUN/dispatcher.pid"
    rm -f "$RUN/pending/timeout-sentinel"
    kill -CONT "$incumbent"
    paused_fixture=""
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    for ((i=0; i<50; i++)); do
        [[ "$(record_count)" -eq 1 ]] && break
        sleep 0.1
    done
    if [[ "$(record_count)" -eq 1 ]]; then ok "incumbent still dispatches after contender timeout"
    else bad "incumbent still dispatches after contender timeout"; fi
    env_run thinkers stop >/dev/null 2>&1
}

test_named_start_keeps_kick() {
    setup_identity
    env_run thinkers start napper >/dev/null 2>&1
    local i
    for ((i=0; i<50; i++)); do
        [[ "$(record_count)" -eq 1 ]] && break
        sleep 0.1
    done
    if [[ "$(record_count)" -eq 1 ]]; then ok "named start queues its kick after runtime setup"
    else bad "named start queues its kick after runtime setup"; fi
    env_run thinkers stop >/dev/null 2>&1
}

test_drain_restart_releases_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        skipcase "drain/restart lock test: flock unavailable"
        return
    fi
    setup_identity
    cat > "$TMP/id/thinkers/napper/step" <<'EOF'
#!/usr/bin/env bash
cat >> "$IDENTITY_DIR/record"
printf '\n' >> "$IDENTITY_DIR/record"
while [[ -f "$IDENTITY_DIR/hold" ]]; do sleep 0.1; done
EOF
    touch "$TMP/id/hold"
    start_thinkers
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    local i old_step
    for ((i=0; i<50; i++)); do
        [[ "$(record_count)" -eq 1 ]] && break
        sleep 0.1
    done
    old_step=$(awk 'NR==1 {print $1}' "$RUN/step_pids")
    if [[ -z "$old_step" ]]; then bad "long step started"; return; fi
    env_run thinkers stop >/dev/null 2>&1
    env_run thinkers start >/dev/null 2>&1
    sleep 17
    if kill -0 "$old_step" 2>/dev/null; then ok "old step still drains during restart"
    else bad "old step still drains during restart"; fi
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    for ((i=0; i<50; i++)); do
        [[ "$(record_count)" -eq 2 ]] && break
        sleep 0.1
    done
    if [[ "$(record_count)" -eq 2 ]]; then ok "replacement dispatches while old step drains"
    else bad "replacement dispatches while old step drains"; fi
    rm -f "$TMP/id/hold"
    sleep 1
    env_run thinkers stop >/dev/null 2>&1
}

test_crashed_owner_releases_feeder_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        skipcase "feeder lock test: flock unavailable"
        return
    fi
    setup_identity
    start_thinkers
    local dispatcher feeder i
    dispatcher=$(cat "$RUN/dispatcher.pid")
    feeder=$(head -n 1 "$RUN/tail_pids")
    # Both ids were created by this test's disposable identity.
    kill -KILL "$dispatcher"
    sleep 1
    if kill -0 "$feeder" 2>/dev/null; then ok "feeder survives its dispatcher for the probe"
    else bad "feeder survives its dispatcher for the probe"; fi
    exec 9>"$RUN/dispatcher.lock"
    if flock -n 9; then
        ok "surviving feeder does not retain dispatcher lock"
        flock -u 9
    else bad "surviving feeder does not retain dispatcher lock"; fi
    exec 9>&-
    env_run thinkers start >/dev/null 2>&1
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    for ((i=0; i<50; i++)); do
        [[ "$(record_count)" -eq 1 ]] && break
        sleep 0.1
    done
    if [[ "$(record_count)" -eq 1 ]]; then ok "restart after crash dispatches once"
    else bad "restart after crash dispatches once"; fi
    env_run thinkers stop >/dev/null 2>&1
}

test_stop_cancels_claims() {
    setup_identity
    mkdir -p "$RUN/claimed" "$RUN/sent"
    printf 'napper\nother\n' > "$RUN/active_thinkers"
    printf '1' > "$RUN/claimed/napper"
    printf '1' > "$RUN/claimed/other"
    printf '1' > "$RUN/sent/napper"
    env_run thinkers stop napper >/dev/null 2>&1
    if [[ ! -f "$RUN/claimed/napper" && ! -f "$RUN/sent/napper" && -f "$RUN/claimed/other" ]]; then
        ok "named stop cancels only that thinker's receipts"
    else bad "named stop cancels only that thinker's receipts"; fi
    env_run thinkers stop >/dev/null 2>&1
    if [[ ! -f "$RUN/claimed/other" ]]; then ok "stop-all cancels every claim"
    else bad "stop-all cancels every claim"; fi
    env_run env THINKERS_CLAIM_STALE_SECS=0 thinkers start >/dev/null 2>&1
    sleep 3
    if [[ "$(record_count)" -eq 0 ]]; then ok "cancelled claims do not wake after restart"
    else bad "cancelled claims do not wake after restart"; fi
    env_run thinkers stop >/dev/null 2>&1
}

want test_waiter_preserves_incumbent
want test_named_start_keeps_kick
want test_drain_restart_releases_lock
want test_crashed_owner_releases_feeder_lock
want test_stop_cancels_claims
want test_stale_claim_non_numeric_wake_at
want test_many_starts_one_dispatch
want test_lock_timeout_exits
want test_lock_is_held
want test_tokens_unique
want test_die_after_claim_recovers
want test_shim_crash_mid_send_recovers
want test_crash_after_launch_does_not_double_fire
want test_stale_claim_keeps_freshest_wake

printf 'cases: pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]] || exit 1
