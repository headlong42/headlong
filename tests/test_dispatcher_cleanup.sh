#!/usr/bin/env bash
# Deterministic lifecycle checks with disposable state and no process signals.
# The integration suite covers real processes; these force cleanup at precise
# ownership boundaries, including Bash 3.2's empty unset-local behavior.
# Variables below are consumed by dynamically loaded product functions.
# shellcheck disable=SC2034
set -uo pipefail
export SHELLM_ENV=local
HERE="$(cd "$(dirname "$0")" && pwd)"
THINKERS_BIN="${THINKERS_BIN:-$HERE/../bin/thinkers}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dispatcher-cleanup.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
# Load definitions only; no CLI dispatch, environment files, or live identity.
sed '/^# Parse global flags/,$d' "$THINKERS_BIN" > "$TMP/functions"
# shellcheck disable=SC1091
source "$TMP/functions"
set +e
# These helpers are deliberately stubbed: tail_pids contains sentinel text,
# never real PIDs. FIFO deletion is restricted to this test's temporary tree.
_kill_tree() { printf '%s\n' "$1" >> "$TMP/killed"; }
_kill_traj_tails() { :; }
_warn_stray_tails() { :; }
_remove_own_fifo() { case "$1" in "$TMP"/*) rm -f "$1" ;; esac; }

setup() {
    IDENTITY_DIR="$TMP/id" IDENTITY_NAME=testid
    THINKERS_DIR="$IDENTITY_DIR/thinkers" TRAJ_DIR="$IDENTITY_DIR/traj" TRAJ_ID=test
    run_dir="$IDENTITY_DIR/run"
    rm -rf "$IDENTITY_DIR"
    mkdir -p "$run_dir/pending" "$run_dir/claimed" "$run_dir/sent" "$THINKERS_DIR/napper" "$TRAJ_DIR"
    printf 'winner' > "$run_dir/dispatcher.token"
    printf 'feeder-sentinel\n' > "$run_dir/tail_pids"
    printf 'subscriptions' > "$run_dir/sub_map"
    printf 'trajectory' > "$run_dir/traj_files"
    printf 'pending' > "$run_dir/pending/napper"
    printf 'fifo' > "$TMP/winner-fifo"
    printf '%s\n' "$TMP/winner-fifo" > "$run_dir/fifo_path"
    rm -f "$TMP/killed"
}
intact() {
    [[ "$(cat "$run_dir/dispatcher.token" 2>/dev/null)" == winner &&
       "$(cat "$run_dir/sub_map" 2>/dev/null)" == subscriptions &&
       "$(cat "$run_dir/traj_files" 2>/dev/null)" == trajectory &&
       "$(cat "$run_dir/tail_pids" 2>/dev/null)" == feeder-sentinel &&
       -f "$run_dir/pending/napper" && -f "$TMP/winner-fifo" &&
       "$(cat "$run_dir/fifo_path" 2>/dev/null)" == "$TMP/winner-fifo" ]]
}
test_timeout() {
    setup
    # A waiter has published its token, but has never owned the runtime.
    # Even a matching token is insufficient authority for EXIT cleanup.
    ( local fifo dispatcher_token=winner _my_tail_pids="" _dispatcher_owns_runtime=0
      _cleanup_dispatcher ) || return 1
    intact && [[ ! -f "$TMP/killed" ]]
}
test_setup_failure_superseded() {
    setup
    printf 'ours' > "$TMP/old-fifo"
    ( local fifo="$TMP/old-fifo" dispatcher_token=old _my_tail_pids="" _dispatcher_owns_runtime=1
      _cleanup_dispatcher ) || return 1
    intact && [[ ! -f "$TMP/old-fifo" && ! -f "$TMP/killed" ]]
}
test_setup_failure_owner() {
    setup
    ( local fifo="" dispatcher_token=winner _my_tail_pids="" _dispatcher_owns_runtime=1
      _cleanup_dispatcher ) || return 1
    [[ ! -f "$run_dir/dispatcher.token" && ! -f "$run_dir/sub_map" && ! -d "$run_dir/pending" ]]
}
test_ownership_loss() {
    setup
    printf 'ours' > "$TMP/old-fifo"
    # Execute the real tick ownership-loss branch without a running loop.
    sed -n '/^        _tick() {/,/^        }/p' "$THINKERS_BIN" > "$TMP/tick"
    ( local fifo="$TMP/old-fifo" dispatcher_token=old _my_tail_pids="our-feeder" _dispatcher_owns_runtime=1
      # shellcheck disable=SC1091
      source "$TMP/tick"
      _tick ) || return 1
    intact && [[ ! -f "$TMP/old-fifo" && "$(cat "$TMP/killed")" == our-feeder ]]
}
test_crashed_stop() {
    setup
    # No dispatcher PID: its EXIT trap never ran, but fifo_path survives.
    _stop_dispatcher || return 1
    [[ ! -f "$TMP/winner-fifo" && ! -f "$run_dir/fifo_path" ]]
}
test_successor_cleanup() {
    setup
    printf 'ours' > "$TMP/old-fifo"
    _cleanup_run_state "$run_dir" "old-trajectory" "$TMP/old-fifo" old || return 1
    intact && [[ ! -f "$TMP/old-fifo" && ! -f "$TMP/killed" ]]
}
test_cancel_claims() {
    setup
    printf 'napper\nother\n' > "$run_dir/active_thinkers"
    printf '1' > "$run_dir/napper.wake_at"
    printf '1' > "$run_dir/claimed/napper"
    printf '1' > "$run_dir/claimed/other"
    printf '1' > "$run_dir/sent/napper"
    cmd_stop --self napper || return 1
    [[ ! -f "$run_dir/napper.wake_at" && ! -f "$run_dir/claimed/napper" &&
       ! -f "$run_dir/sent/napper" && -f "$run_dir/claimed/other" ]] || return 1
    cmd_stop --self || return 1
    [[ ! -f "$run_dir/claimed/other" ]]
}
pass=0 fail=0
for test in test_timeout test_setup_failure_superseded test_setup_failure_owner test_ownership_loss test_crashed_stop test_successor_cleanup test_cancel_claims; do
    if "$test"; then printf 'PASS %s\n' "$test"; pass=$((pass+1))
    else printf 'FAIL %s\n' "$test"; fail=$((fail+1)); fi
done
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
