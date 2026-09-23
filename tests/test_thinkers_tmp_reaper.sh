#!/usr/bin/env bash
# test_thinkers_tmp_reaper.sh — deploy/thinkers-tmp-reaper.sh
#
# Usage: tests/test_thinkers_tmp_reaper.sh
#
# In a private temp root: a big stale file goes, a big fresh file stays, a
# small stale tmp.* goes, a small fresh one stays, a day-old shellm-run dir
# goes, a fresh one stays, and a stale dir with another name is not touched.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SCRIPT="$REPO/deploy/thinkers-tmp-reaper.sh"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/root"; mkdir -p "$ROOT"

age() { # age PATH SECONDS
    local when=$(( $(date +%s) - $2 ))
    touch -d "@$when" "$1" 2>/dev/null || touch -t "$(date -r "$when" +%Y%m%d%H%M.%S)" "$1"
}
big() { # sparse, so the test is cheap; find judges by st_size
    truncate -s 150M "$1" 2>/dev/null || mkfile -n 150m "$1" 2>/dev/null || dd if=/dev/zero of="$1" bs=1m count=150 2>/dev/null
}

big "$ROOT/tmp.bigold";  age "$ROOT/tmp.bigold" 3600
big "$ROOT/tmp.bignew"
: > "$ROOT/tmp.smallold"; age "$ROOT/tmp.smallold" 90000
: > "$ROOT/tmp.smallnew"
mkdir -p "$ROOT/shellm-run.old/tmp" "$ROOT/shellm-run.new" "$ROOT/shellm-exec.old" "$ROOT/keep-me.old"
: > "$ROOT/shellm-run.old/tmp/x"
age "$ROOT/shellm-run.old" 90000; age "$ROOT/shellm-exec.old" 90000; age "$ROOT/keep-me.old" 90000

out=$(HEADLONG_TMP_ROOT="$ROOT" bash "$SCRIPT" /nonexistent ident 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "exits 0" || bad "exits 0" "rc=$rc $out"

[[ -e "$ROOT/tmp.bigold" ]]      && bad "big stale file reaped"        || ok "big stale file reaped"
[[ -e "$ROOT/tmp.bignew" ]]      && ok "big fresh file kept"           || bad "big fresh file kept"
[[ -e "$ROOT/tmp.smallold" ]]    && bad "small stale tmp.* reaped"     || ok "small stale tmp.* reaped"
[[ -e "$ROOT/tmp.smallnew" ]]    && ok "small fresh tmp.* kept"        || bad "small fresh tmp.* kept"
[[ -d "$ROOT/shellm-run.old" ]]  && bad "stale shellm-run dir reaped"  || ok "stale shellm-run dir reaped"
[[ -d "$ROOT/shellm-exec.old" ]] && bad "stale shellm-exec dir reaped" || ok "stale shellm-exec dir reaped"
[[ -d "$ROOT/shellm-run.new" ]]  && ok "fresh shellm-run dir kept"     || bad "fresh shellm-run dir kept"
[[ -d "$ROOT/keep-me.old" ]]     && ok "stale dir with another name kept" || bad "stale dir with another name kept"
grep -q 'reaped 2 files, 2 dirs' <<< "$out" && ok "summary line counts what went" || bad "summary line counts what went" "$out"

# nothing to do → no summary line, still exit 0
out=$(HEADLONG_TMP_ROOT="$ROOT" bash "$SCRIPT" 2>&1); rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && ok "quiet when there is nothing to reap" || bad "quiet when there is nothing to reap" "rc=$rc $out"

# a missing root is not an error
HEADLONG_TMP_ROOT="$TMP/nope" bash "$SCRIPT" >/dev/null 2>&1 && ok "missing root exits 0" || bad "missing root exits 0"

# --- safety: roots it must refuse, and names it must handle ------------------
mkdir -p "$ROOT"
: > "$ROOT/tmp.bait"; age "$ROOT/tmp.bait" 90000
refused() { # refused ROOT LABEL: script exits 0, says "refusing", touches nothing
    local out
    out=$(HEADLONG_TMP_ROOT="$1" bash "$SCRIPT" 2>&1); local rc=$?
    if [[ "$rc" -eq 0 ]] && grep -q 'refusing' <<< "$out" && [[ -e "$ROOT/tmp.bait" ]]; then ok "refuses $2"
    else bad "refuses $2" "rc=$rc $out"; fi
}
refused / "the root directory"
refused "$HOME" "HOME"
refused /usr "a system dir"
FAKE_HOME="$TMP/homeish/tmp"; mkdir -p "$FAKE_HOME"
if out=$(HOME="$TMP/homeish" HEADLONG_TMP_ROOT="$TMP" bash "$SCRIPT" 2>&1) && grep -q 'refusing' <<< "$out"; then
    ok "refuses an ancestor of HOME even inside the temp tree"
else bad "refuses an ancestor of HOME even inside the temp tree" "$out"; fi
# HOME_ancestor check must not misfire when HOME merely shares a prefix string
mkdir -p "$TMP/rootx"; : > "$TMP/rootx/tmp.old"; age "$TMP/rootx/tmp.old" 90000
HOME="$TMP/rootxy" HEADLONG_TMP_ROOT="$TMP/rootx" bash "$SCRIPT" >/dev/null 2>&1
[[ -e "$TMP/rootx/tmp.old" ]] && bad "prefix-only HOME match does not block" || ok "prefix-only HOME match does not block"
# a symlink root resolves before the check
ln -s / "$ROOT/to-root"
refused "$ROOT/to-root" "a symlink to /"
rm -f "$ROOT/to-root"
# symlinked entries are never followed: a stale symlink named like a run dir
# is left alone, and a symlink inside a stale run dir does not reach its target
mkdir -p "$TMP/target"; : > "$TMP/target/keep"
ln -s "$TMP/target" "$ROOT/shellm-run.link"; age "$ROOT/shellm-run.link" 90000
mkdir -p "$ROOT/shellm-run.withlink"; ln -s "$TMP/target" "$ROOT/shellm-run.withlink/out"; age "$ROOT/shellm-run.withlink" 90000
HEADLONG_TMP_ROOT="$ROOT" bash "$SCRIPT" >/dev/null 2>&1
[[ -e "$TMP/target/keep" ]] && ok "symlink targets outside the root survive" || bad "symlink targets outside the root survive"
[[ -L "$ROOT/shellm-run.link" ]] && ok "a symlink named like a run dir is not touched" || bad "a symlink named like a run dir is not touched"
[[ -e "$ROOT/shellm-run.withlink" ]] && bad "stale run dir holding a symlink is removed" || ok "stale run dir holding a symlink is removed"
# names with spaces and newlines
big "$ROOT/tmp.with space"; age "$ROOT/tmp.with space" 3600
big "$ROOT/tmp.line1
line2"; age "$ROOT/tmp.line1
line2" 3600
HEADLONG_TMP_ROOT="$ROOT" bash "$SCRIPT" >/dev/null 2>&1
[[ -e "$ROOT/tmp.with space" ]] && bad "name with a space reaped" || ok "name with a space reaped"
[[ -e "$ROOT/tmp.line1
line2" ]] && bad "name with a newline reaped" || ok "name with a newline reaped"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
