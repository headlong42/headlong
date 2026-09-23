#!/usr/bin/env bash
# test_monolith_run_capture.sh — the monolith step must not wait on processes
# the run leaves behind.
#
# Usage: tests/test_monolith_run_capture.sh
#
# 2026-09-14: the step captured shellm's stdout with `$( ... )`, a pipe. Two
# web servers the mind had backgrounded inside the run inherited the pipe's
# write end, so the step blocked in read() for six hours after the run had
# written its final step, its EXIT trap never armed the next wake, and the
# mind went silent. The step now captures through files. This test's shellm
# stub backgrounds a `sleep` that inherits every fd, then exits: the step
# must finish in seconds, keep the run's stdout and stderr, arm the next
# wake, and name the leftover in its log. No LLM, no docker, no dispatcher.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/monolith/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d)
cleanup() { [[ -f "$WORK/sleep.pid" ]] && kill "$(cat "$WORK/sleep.pid")" 2>/dev/null; cd /; rm -rf "$WORK"; }
trap cleanup EXIT

ID="$WORK/ident"
TID="cafe0000-0000-0000-0000-0000000000cc"
mkdir -p "$ID/memories" "$ID/trajectories/$TID" "$ID/run"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TID/trajectory.jsonl"
: > "$TRAJ"
printf 'test-token\n' > "$ID/run/dispatcher.token"

# shellm stub: appends an observation, prints a response line on stdout, a
# diagnostic on stderr, and leaves a background sleep holding every fd it
# inherited — exactly what `nohup server &` inside a run does. Its pid is
# saved so cleanup can end it.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/shellm" <<STUB
#!/usr/bin/env bash
printf '{"type":"observation","step_id":"o-1","content":"did a thing","source":"monolith"}\n' >> "$TRAJ"
echo "stub diagnostic line" >&2
echo "response from the run"
sleep 600 &
echo \$! > "$WORK/sleep.pid"
exit 0
STUB
chmod +x "$WORK/stub/shellm"
# identity and mem stubs the step calls while building its prompt
for t in identity mem recap; do printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stub/$t"; chmod +x "$WORK/stub/$t"; done

# setsid (Linux) gives the step its own process group, as the dispatcher
# does, so the leftover report has a group to look at. Absent on macOS.
setsid_cmd=""
command -v setsid >/dev/null 2>&1 && setsid_cmd=setsid

run_step() {
    IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
    TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TID" ROOT_TRAJ_ID="$TID" \
    THINKER_NAME=monolith THINK_MODEL=stub MONOLITH_TIERED_MEMORY=0 RELATED_MEMORIES=0 \
    PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" \
    $setsid_cmd bash "$STEP" > "$WORK/step.log" 2>&1
}

start=$SECONDS
printf '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}' | run_step
rc=$?
took=$((SECONDS - start))

if (( took < 30 )); then ok "step returns while a leftover process still holds its fds (${took}s)"
else bad "step returns while a leftover process still holds its fds" "took ${took}s"; fi

if [[ "$rc" -eq 0 ]]; then ok "step exit 0"; else bad "step exit 0" "rc=$rc; log: $(tail -n 5 "$WORK/step.log" | tr '\n' ' ')"; fi

if grep -q 'stub diagnostic line' "$WORK/step.log"; then ok "run stderr reaches the step log"
else bad "run stderr reaches the step log" "$(tail -n 8 "$WORK/step.log" | tr '\n' ' ')"; fi

if grep -q '\[monolith\] response from the run' "$WORK/step.log"; then ok "run stdout captured as the response"
else bad "run stdout captured as the response" "$(grep -n 'monolith\]' "$WORK/step.log" | head -3 | tr '\n' ' ')"; fi

if grep -q 'still alive after it exited' "$WORK/step.log" && grep -q 'sleep 600' "$WORK/step.log"; then
    ok "leftover background process named in the log"
else
    # On macOS without setsid the step shares the dispatcher's group and
    # skips the report; only fail on Linux where the group is the step's own.
    if [[ "$(uname)" == "Linux" ]]; then bad "leftover background process named in the log" "$(grep -n 'alive\|WARNING' "$WORK/step.log" | head -3 | tr '\n' ' ')"
    else ok "leftover report skipped outside the step's own process group (macOS)"; fi
fi

if [[ -f "$ID/run/monolith.wake_at" ]]; then ok "next wake armed by the EXIT trap"
else bad "next wake armed by the EXIT trap"; fi

leftover_tmp=""
for f in "$ID"/run/monolith_run_out.* "$ID"/run/monolith_run_err.*; do
    [[ -e "$f" ]] && leftover_tmp="$f"
done
if [[ -z "$leftover_tmp" ]]; then ok "temp capture files removed"; else bad "temp capture files removed" "$leftover_tmp"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
