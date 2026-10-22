#!/usr/bin/env bash
# The default prompt teaches bash fences without repeating forbidden tool tags.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/shellm-prompt-markup.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Load only the prompt functions, not shellm startup (which loads .env files
# and can start a run). Source a file for compatibility with macOS bash 3.2.
for fn in usage_text build_system_prompt; do
    sed -n "/^$fn() {/,/^}/p" "$REPO/bin/shellm"
done > "$WORK/functions"
# shellcheck disable=SC1090
source "$WORK/functions"

# Test the built-in prompt even when launched from an identity's environment.
unset SHELLM_SYSTEM_PROMPT
export SHELLM_ENV=local
export SHELLM_CONTEXT_SCOPE=traj
export SHELLM_CONTEXT_BLOCK_LIMIT=8192
export SHELLM_CONTEXT_WHOLE_BLOCKS=1
export SHELLM_CONTEXT_RUN_TAIL_BLOCK=50
export SHELLM_STDOUT_PROMPT_LIMIT=2048
build_system_prompt "" 0 > "$WORK/prompt"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# Positive assertions prevent an empty or overridden prompt from passing.
for instruction in 'exactly ONE ```bash code block' \
    'opening ```bash fence MUST start on its OWN new line'; do
    if grep -F "$instruction" "$WORK/prompt" >/dev/null; then
        ok "default prompt retains: $instruction"
    else
        bad "default prompt is missing: $instruction"
    fi
done

# Check rendered text, not source: the parser legitimately contains these
# literals. Match the parameter prefix so any parameter name is caught.
for tag in '<tool_call>' '<function=bash>' '<parameter=' '<bash>'; do
    if grep -F "$tag" "$WORK/prompt" >/dev/null; then
        bad "default prompt repeats forbidden markup: $tag"
    else
        ok "default prompt omits forbidden markup: $tag"
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
