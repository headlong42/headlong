#!/usr/bin/env bash
# tests/test_llm_json_schema.sh — `llm --json-schema FILE` asks an OpenAI-style
# provider for one object matching the schema (response_format json_schema,
# strict), and is absent from the payload otherwise. curl is stubbed the same
# way as test_llm_openrouter_routing.sh: it keeps the payload file bin/llm
# hands it and answers with one SSE chunk. No network.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/home/.headlong"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "-d@"* ]] && cp "${a#-d@}" "$PAYLOAD_OUT" 2>/dev/null
    [[ "$a" == @* ]] && cp "${a#@}" "$PAYLOAD_OUT" 2>/dev/null
done
printf 'data: {"choices":[{"delta":{"content":"{\\"action\\":\\"reply\\"}"}}]}\n\n'
printf 'data: [DONE]\n'
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" PAYLOAD_OUT="$WORK/payload.json"
printf '{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["reply","defer","no_reply"]},"message":{"type":"string"}},"required":["action","message"]}\n' > "$WORK/schema.json"

run_llm() {   # [llm args...]
    : > "$PAYLOAD_OUT"
    ( cd "$WORK/run" && printf 'hi' | env -u LLM_PROVIDER -u SHELLM_HOME HOME="$WORK/home" HEADLONG_HOME="$WORK/home/.headlong" \
        OPENROUTER_API_KEY="test-key" OPENAI_API_KEY="test-key" ANTHROPIC_API_KEY="test-key" \
        "$REPO/bin/llm" "$@" ) > "$WORK/out" 2> "$WORK/err"
}
q() { jq -r "$1" "$PAYLOAD_OUT" 2>/dev/null; }

run_llm -m openai/gpt-4o-mini
[[ "$(q 'has("response_format")')" == "false" ]] && ok "no flag: no response_format in the payload" || bad "no flag: no response_format in the payload" "got $(q '.response_format')"

run_llm -m openai/gpt-4o-mini --json-schema "$WORK/schema.json"
[[ "$(q '.response_format.type')" == "json_schema" ]] && ok "--json-schema sets response_format.type json_schema" || bad "--json-schema sets response_format.type json_schema" "got $(q '.response_format')"
[[ "$(q '.response_format.json_schema.strict')" == "true" ]] && ok "the schema is strict" || bad "the schema is strict" "got $(q '.response_format.json_schema.strict')"
[[ "$(q '.response_format.json_schema.schema.required | join(",")')" == "action,message" ]] && ok "the file's schema is carried verbatim" || bad "the file's schema is carried verbatim" "got $(q '.response_format.json_schema.schema')"
[[ "$(q '.model')" == "openai/gpt-4o-mini" && "$(q '.messages | length')" == "1" ]] && ok "the rest of the payload is unchanged" || bad "the rest of the payload is unchanged"
grep -q '"action":"reply"' "$WORK/out" && ok "the reply text streams through untouched" || bad "the reply text streams through untouched" "got $(cat "$WORK/out")"

run_llm -m openai/gpt-4o-mini --json-schema "$WORK/missing.json"
[[ $? -ne 0 ]] && grep -q "Schema file not found" "$WORK/err" && ok "a missing schema file is an error" || bad "a missing schema file is an error" "$(cat "$WORK/err")"

run_llm -m claude-sonnet-4-5 --json-schema "$WORK/schema.json"
grep -q "json-schema ignored" "$WORK/err" && ok "anthropic warns and ignores the flag" || bad "anthropic warns and ignores the flag" "$(head -2 "$WORK/err")"

echo; echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
