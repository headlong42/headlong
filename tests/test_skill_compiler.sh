#!/usr/bin/env bash
# tests/test_skill_compiler.sh — offline checks for skills/skill-compiler: the
# compile skip-list refuses side-effect skills before any model call, a missing
# skill dies cleanly, the phrase pool carries the tool's own output vocabulary,
# the cache is self-describing with POOL-EXACT / POOL-FRAGMENT / INVENTED literal
# labels and VERIFIED only on pool-attested literals, and the shipped script
# carries no identity-specific absolute paths. No LLM calls, no network: the
# teacher and the test runner are stubs on PATH.
#
# Usage: tests/test_skill_compiler.sh

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SC="$REPO/skills/skill-compiler/skill-compiler"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sc-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/stubs"
mkdir -p "$STUB"

cat > "$STUB/llm" <<'STUBLEOF'
#!/usr/bin/env bash
[ -n "${STUB_LLM_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LLM_LOG"
cat <<'JSON'
[
  {"name":"greet-pool-exact","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["Hello, phrase-pool world!"]},
  {"name":"greet-pool-fragment","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["phrase-pool world"]},
  {"name":"greet-invented","prompt":"Run the greeting skill and report what it prints.","expect":"final","expect_contains":["ZzyzxNotInPool"]}
]
JSON
STUBLEOF

cat > "$STUB/shellm" <<'STUBLEOF'
#!/usr/bin/env bash
[ -n "${STUB_SHELLM_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_SHELLM_LOG"
: "${TRAJ_DIR:?stub shellm needs TRAJ_DIR}"
mkdir -p "$TRAJ_DIR"
{
  printf '%s\n' '{"type":"shell-output","stdout":"Hello, phrase-pool world! | phrase-pool world | ZzyzxNotInPool"}'
  printf '%s\n' '{"type":"final","content":"Reported. Hello, phrase-pool world! and phrase-pool world and ZzyzxNotInPool."}'
} > "$TRAJ_DIR/stub-run.jsonl"
STUBLEOF

cat > "$STUB/skills" <<'STUBLEOF'
#!/usr/bin/env bash
exit 0
STUBLEOF
chmod +x "$STUB/llm" "$STUB/shellm" "$STUB/skills"
export PATH="$STUB:$PATH"

# Fixture skill: one script whose output is the vocabulary the pool must carry.
FIX="$WORK/skills/fixture-greet"
mkdir -p "$FIX"
cat > "$FIX/fixture_greet.py" <<'PYEOF'
#!/usr/bin/env python3
print("Hello, phrase-pool world!")
PYEOF
cat > "$FIX/SKILL.md" <<'MDEOF'
---
name: fixture-greet
description: Greet a caller with the phrase-pool greeting.
---

# fixture-greet

Run `python3 fixture_greet.py` to print the greeting.

```text
Hello, phrase-pool world!
```
MDEOF

run_sc() { SKILLS_DIR="$WORK/skills" SKILLS_KERNEL_DIR="$WORK/kernel" "$SC" "$@"; }

echo "# skill-compiler offline harness"
echo

if [ -x "$SC" ]; then ok "compiler script is executable"; else bad "compiler script is executable" "missing $SC"; fi
if bash -n "$SC" 2>/dev/null; then ok "compiler script parses"; else bad "compiler script parses"; fi

if grep -q '\.identities/' "$SC"; then
  bad "ship script has no identity-specific paths" "found .identities/ reference"
else
  ok "ship script has no identity-specific paths"
fi
if grep -q '/opt/shellm/' "$SC"; then
  bad "ship script has no absolute install paths" "found /opt/shellm reference"
else
  ok "ship script has no absolute install paths"
fi

# Skip-list: refused before any teacher call, and the teacher is never invoked.
export STUB_LLM_LOG="$WORK/llm.log"
rm -f "$STUB_LLM_LOG"
out=$(run_sc compile --skill github-api 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'skip-list'; then
  ok "skip-listed skill is refused at compile time"
else
  bad "skip-listed skill is refused at compile time" "rc=$rc out=${out:0:120}"
fi
if [ -e "$STUB_LLM_LOG" ]; then
  bad "skip-listed skill never reaches the teacher" "teacher was called: $(head -c 120 "$STUB_LLM_LOG")"
else
  ok "skip-listed skill never reaches the teacher"
fi

out=$(run_sc compile --skill no-such-skill 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'not found'; then
  ok "missing skill dies with a clean error"
else
  bad "missing skill dies with a clean error" "rc=$rc out=${out:0:120}"
fi

# Phrase pool: the tool's own output vocabulary, no count-bearing phantom lines.
pool=$(run_sc pool --skill fixture-greet)
if printf '%s' "$pool" | jq -e 'index("Hello, phrase-pool world!")' >/dev/null 2>&1; then
  ok "phrase pool carries the tool's real output literal"
else
  bad "phrase pool carries the tool's real output literal" "pool=${pool:0:160}"
fi

# Full compile against the stubs: cache must be self-describing and label every
# literal's provenance, verifying only on pool-attested vocabulary.
rm -rf "$REPO/skills/skill-compiler/.compiled/fixture-greet.json" "$REPO/skills/skill-compiler/.compiled/fixture-greet.md"
out=$(run_sc compile --skill fixture-greet --num-tests 3 --max-iterations 3 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "compile runs end to end against stubs"; else bad "compile runs end to end against stubs" "rc=$rc out=${out:0:300}"; fi

CACHE="$REPO/skills/skill-compiler/.compiled/fixture-greet.json"
if [ -f "$CACHE" ] && jq -e '.summary and .tests' "$CACHE" >/dev/null 2>&1; then
  ok "cache json is self-describing (summary plus tests)"
else
  bad "cache json is self-describing (summary plus tests)" "missing or shape-wrong: $CACHE"
fi

if [ -f "$CACHE" ] && jq -e '.summary | .total == 3 and .passed == 3 and .verified == 2 and .green_on_invented == 1' "$CACHE" >/dev/null 2>&1; then
  ok "summary counts: 3 passed, 2 verified, 1 green on invented"
else
  bad "summary counts: 3 passed, 2 verified, 1 green on invented" "summary=$(jq -c '.summary' "$CACHE" 2>/dev/null)"
fi

if [ -f "$CACHE" ] && jq -e '[.tests[] | .literal_labels[]] | sort == (["INVENTED","POOL-EXACT","POOL-FRAGMENT"] | sort)' "$CACHE" >/dev/null 2>&1; then
  ok "literal labels: POOL-EXACT, POOL-FRAGMENT, INVENTED"
else
  bad "literal labels: POOL-EXACT, POOL-FRAGMENT, INVENTED" "labels=$(jq -c '[.tests[] | .literal_labels]' "$CACHE" 2>/dev/null)"
fi

if [ -f "$CACHE" ] && jq -e '[.tests[] | .verification] | sort == (["GREEN-ON-INVENTED","VERIFIED","VERIFIED"] | sort)' "$CACHE" >/dev/null 2>&1; then
  ok "verification: only pool-attested passes count as VERIFIED"
else
  bad "verification: only pool-attested passes count as VERIFIED" "status=$(jq -c '[.tests[] | .verification]' "$CACHE" 2>/dev/null)"
fi

MD_CACHE="$REPO/skills/skill-compiler/.compiled/fixture-greet.md"
if [ -f "$MD_CACHE" ] && grep -q '## Summary: 3 / 3 passed, 2 / 3 verified' "$MD_CACHE" && grep -q '## Pass verification' "$MD_CACHE"; then
  ok "markdown cache carries the summary and the pass verification section"
else
  bad "markdown cache carries the summary and the pass verification section" "file=$MD_CACHE"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
