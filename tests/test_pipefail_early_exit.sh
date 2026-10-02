#!/usr/bin/env bash
# tests/test_pipefail_early_exit.sh - a memory body larger than the 64KB pipe
# buffer must survive the summary substitution in bin/mem (both add and edit).
#
# Why: under `set -euo pipefail`, a command substitution whose pipeline ends in
# an early-exit consumer (head -1, head -c N, grep -m N) can kill the whole
# tool once the producer writes more than the consumer reads. The producer
# takes SIGPIPE (141) or jq exits 2 on its own write error, and the tool dies
# inside the substitution having printed nothing. Repro 2026-10-02: `mem add`
# with a 200KB body returned rc=1 and wrote no memory file at all, so the
# memory was lost silently. The guard is `|| true` after the consumer's
# pipeline inside the substitution.
#
# Usage: tests/test_pipefail_early_exit.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"
export PATH

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export MEM_DIR="$W/mem"
mkdir -p "$MEM_DIR"

# 200KB body: the first line is short (that is all the summary takes), the rest
# is bulk that trips the early-exit consumer.
BIG="$W/body.txt"
{ printf 'first line short\n'; head -c 200000 /dev/zero | tr '\0' 'y'; printf '\n'; } > "$BIG"
size=$(wc -c < "$BIG" | tr -d ' ')
if [ "$size" -gt 65536 ]; then
  ok "fixture body is bigger than the pipe buffer ($size bytes)"
else
  bad "fixture body is bigger than the pipe buffer" "size=$size"
fi

# 1. mem add must write the memory and exit 0
err=$(mem add --type lesson < "$BIG" 2>&1 >/dev/null)
rc=$?
files=$(find "$MEM_DIR" -name '*.md' | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$files" = 1 ]; then
  ok "mem add writes a body larger than the pipe buffer"
else
  bad "mem add writes a body larger than the pipe buffer" "rc=$rc files=$files err=$(printf '%s' "$err" | head -c 120)"
fi

# 2. and it must still take the first line as the summary
f=$(find "$MEM_DIR" -name '*.md' | head -1)
if [ -n "$f" ] && grep -q '^summary: first line short' "$f"; then
  ok "mem add records the first line as the summary"
else
  bad "mem add records the first line as the summary" "file=$f"
fi

# 3. mem edit must rewrite that body and exit 0 (edit takes the hex id)
hex=$(basename "$f" .md | sed 's/^[0-9-]*_//; s/_.*//')
BIG2="$W/body2.txt"
{ printf 'edited first line\n'; head -c 200000 /dev/zero | tr '\0' 'z'; printf '\n'; } > "$BIG2"
err2=$(mem edit "$hex" < "$BIG2" 2>&1 >/dev/null)
rc2=$?
f2=$(find "$MEM_DIR" -name "*_${hex}_*.md" | head -1)
size2=$(wc -c < "$f2" 2>/dev/null | tr -d ' ')
files2=$(find "$MEM_DIR" -name '*.md' | wc -l | tr -d ' ')
if [ "$rc2" -eq 0 ] && [ "$files2" = 1 ] && [ -n "$size2" ] && [ "$size2" -gt 200000 ]; then
  ok "mem edit rewrites a body larger than the pipe buffer ($size2 bytes)"
else
  bad "mem edit rewrites a body larger than the pipe buffer" "rc=$rc2 files=$files2 size=$size2 err=$(printf '%s' "$err2" | head -c 120)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
