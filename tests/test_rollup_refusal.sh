#!/usr/bin/env bash
# test_rollup_refusal.sh — a block the summary model cannot or will not write
#
# Usage: tests/test_rollup_refusal.sh
#
# Why: the tier-1 build walks forward and died on the first block it could
# not summarize, which threw away the whole --context output. On 2026-10-03
# Anthropic's content filter refused one ordinary window of Harris's log, so
# every wake for 12 days rebuilt that block, died, and woke with no life
# summary at all. These tests pin the new behavior: a refusal seals a
# placeholder and the build moves on, any other failure stops the build but
# still prints what exists, and one call seals a bounded number of blocks.
#
# The `llm` CLI is stubbed (canned rollup JSON, calls logged): no network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

# --- stub llm: refuses REFUSE-ME, fails FLAKY while $FLAKY_ON exists --------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf 'CALL\n%s\n---\n' "$input" >> "$LLM_LOG"
if [[ "$input" == *REFUSE-ME* ]]; then
    echo "llm: error: refused: the provider content filter blocked this request (finish_reason content_filter)" >&2
    exit 1
fi
if [[ "$input" == *FLAKY* && -e "$FLAKY_ON" ]]; then
    echo "llm: error: empty response: stream ended without emitting anything" >&2
    exit 1
fi
n=$(printf '%s' "$input" | wc -l | tr -d ' ')
printf '{"summary":"rollup of %s lines","themes":["testing"],"step_ids":["st000001"]}' "$n"
EOF
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export LLM_LOG="$WORK/llm.log" FLAKY_ON="$WORK/flaky_on"
unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL ROLLUP_MAX_SEALS 2>/dev/null || true

TRAJ_ROOT="$WORK/trajectories"

mk_traj() { # mk_traj <run-name> <n-signal-steps> [<step-no> <marker>]
    local run="$TRAJ_ROOT/$1" i content
    mkdir -p "$run/rollups"
    printf '{"start_index":0,"updated":"t"}\n' > "$run/rollups/meta.json"
    printf '{"type":"trajectory","step_id":"%s-0000-4000-8000-000000000000","ts":"t0"}\n' \
        "${1%%-*}" > "$run/trajectory.jsonl"
    for (( i = 1; i <= $2; i++ )); do
        content="thinking about topic $i"
        [[ "$i" == "${3:-}" ]] && content="$content $4"
        printf '{"type":"thought","step_id":"st%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"%s"}\n' \
            "$i" $((i % 60)) "$content" >> "$run/trajectory.jsonl"
    done
}

blockfile() { # blockfile <run-name> <tier> <s> <e>
    printf '%s/%s/rollups/t%s/%012d-%012d.json' "$TRAJ_ROOT" "$1" "$2" "$3" "$4"
}
sealed() { ls "$TRAJ_ROOT/$1/rollups/t1" 2>/dev/null | wc -l | tr -d ' '; }
calls_with() { grep -c "$1" "$LLM_LOG"; }
ctx() { recap "$1" --traj_dir "$TRAJ_ROOT" --context --raw-tail 0 "${@:2}" 2>"$WORK/stderr"; }

# ---------------------------------------------------------------------------
# 1. Refusal: block [10,20) is refused. It is sealed as a placeholder after
#    one call, the blocks after it seal, and the staircase prints.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj aaaa1111-root 55 13 REFUSE-ME
out=$(ctx aaaa1111)
rc=$?
check "refusal: exits 0"                     test "$rc" -eq 0
check "refusal: all five t1 blocks sealed"   test "$(sealed aaaa1111-root)" = "5"
check "refusal: block marked refused"        test "$(jq -r .refused "$(blockfile aaaa1111-root 1 10 20)")" = "true"
check "refusal: placeholder summary"         grep -q 'Not summarized' "$(blockfile aaaa1111-root 1 10 20)"
check "refusal: one call, no retry"          test "$(calls_with REFUSE-ME)" = "1"
check_not "refusal: good block not marked"   grep -q refused "$(blockfile aaaa1111-root 1 20 30)"
check "refusal: staircase printed"           grep -q 'YOUR LIFE SO FAR' <<<"$out"
check "refusal: placeholder line shown"      grep -q 'Not summarized' <<<"$out"
check "refusal: later block shown"           grep -q 'steps 40–50' <<<"$out"
: > "$LLM_LOG"
ctx aaaa1111 >/dev/null
check "refusal: next call does not retry it" test "$(calls_with REFUSE-ME)" = "0"

# ---------------------------------------------------------------------------
# 2. Other failure: block [20,30) fails. The build stops there, the block
#    stays unsealed for the next call, and what exists still prints.
# ---------------------------------------------------------------------------
: > "$LLM_LOG"
mk_traj bbbb2222-root 55 23 FLAKY
touch "$FLAKY_ON"
out=$(ctx bbbb2222)
rc=$?
check "failure: exits 0"                     test "$rc" -eq 0
check "failure: blocks before it sealed"     test -f "$(blockfile bbbb2222-root 1 10 20)"
check_not "failure: failed block unsealed"   test -f "$(blockfile bbbb2222-root 1 20 30)"
check_not "failure: build stopped there"     test -f "$(blockfile bbbb2222-root 1 30 40)"
check "failure: staircase still printed"     grep -q 'steps 10–20' <<<"$out"
check "failure: stop noted on stderr"        grep -q 'stopping the build' "$WORK/stderr"
rm -f "$FLAKY_ON"
ctx bbbb2222 >/dev/null
check "failure: next call seals the rest"    test "$(sealed bbbb2222-root)" = "5"
check_not "failure: not marked refused"      grep -q refused "$(blockfile bbbb2222-root 1 20 30)"

# ---------------------------------------------------------------------------
# 3. Cap: nine pending blocks, ROLLUP_MAX_SEALS=4. Each call seals four;
#    --backfill has no cap.
# ---------------------------------------------------------------------------
mk_traj cccc3333-root 95
out=$(ROLLUP_MAX_SEALS=4 ctx cccc3333)
rc=$?
check "cap: exits 0"                         test "$rc" -eq 0
check "cap: four sealed on the first call"   test "$(sealed cccc3333-root)" = "4"
check "cap: oldest blocks first"             test -f "$(blockfile cccc3333-root 1 30 40)"
check "cap: noted on stderr"                 grep -q 'the cap for one call' "$WORK/stderr"
check "cap: staircase printed"               grep -q 'YOUR LIFE SO FAR' <<<"$out"
ROLLUP_MAX_SEALS=4 ctx cccc3333 >/dev/null
check "cap: eight after the second call"     test "$(sealed cccc3333-root)" = "8"
mk_traj dddd4444-root 95
ROLLUP_MAX_SEALS=4 ctx dddd4444 --backfill >/dev/null
check "cap: --backfill seals everything"     test "$(sealed dddd4444-root)" = "9"
ROLLUP_MAX_SEALS=x ctx dddd4444 >/dev/null
check "cap: a bad value is refused"          grep -q 'ROLLUP_MAX_SEALS must be a number' "$WORK/stderr"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
