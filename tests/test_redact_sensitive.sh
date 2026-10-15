#!/usr/bin/env bash
# tests/test_redact_sensitive.sh — redact_sensitive masks every provider key.
#
# Usage: tests/test_redact_sensitive.sh
#
# The function is extracted from bin/shellm and exercised directly (sourcing
# the whole script would run it). Every provider key env var's value must
# come back masked, and the sk-ant- pattern is masked even with no env var
# carrying the value.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

eval "$(sed -n '/^redact_sensitive()/,/^}/p' "$REPO/bin/shellm")"
if ! declare -f redact_sensitive >/dev/null; then
    bad "redact_sensitive extracted from bin/shellm"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

for var in ANTHROPIC_API_KEY LLM_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY \
           GEMINI_API_KEY OPENCODE_API_KEY; do
    secret="key-$$-$RANDOM$RANDOM"
    export "$var=$secret"
    out=$(redact_sensitive "before $secret after")
    if [[ "$out" != *"$secret"* && "$out" == *redacted* ]]; then
        ok "$var value is masked"
    else
        bad "$var value is masked" "$out"
    fi
    unset "$var"
done

out=$(redact_sensitive "token sk-ant-abc123XYZ here")
if [[ "$out" == *'<redacted-anthropic-key>'* && "$out" != *sk-ant-abc123XYZ* ]]; then
    ok "sk-ant- pattern is masked without the env var"
else
    bad "sk-ant- pattern is masked without the env var" "$out"
fi


# Credential shapes that arrive as text (a person pastes them) carry no env var
# to match against, so the shape rules are what catch them. These are the
# shapes that were actually found in the mind log during the 2026-09-25
# exposure audit.
shape_case() {
    local name="$1" secret="$2" out
    out=$(redact_sensitive "before $secret after")
    if [[ "$out" != *"$secret"* && "$out" == *redacted* ]]; then
        ok "$name shape is masked"
    else
        bad "$name shape is masked" "$out"
    fi
}
shape_case "github-classic"    "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
shape_case "github-fine"       "github_pat_AAAAAAAAAAAAAAAAAAAAAA_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
shape_case "slack-cookie"      "xoxc-123456789012-123456789012-abcdef0123456789abcdef0123456789abcdef"
shape_case "slack-app"         "xoxe-1-0000000000-1234567890abcdef-abcdefghijklmnopqrstuv"
shape_case "huggingface"       "hf_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
shape_case "google"            "AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYzAbCdEf"
shape_case "aws"               "AKIAIOSFODNN7EXAMPLE"
shape_case "jwt"               "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghij0123456789"
shape_case "openai-project"    "sk-proj-0123456789abcdef.0123456789abcdef0123456789abcdef0123456789abcdef"
shape_case "basic-auth-url"    "https://user:SuperSecretPass123@host.example"

# A credential env var outside the provider set is masked by value too. This
# uses TWILIO_AUTH_TOKEN, which has no shape rule of its own, so a clean result
# here is the value pass alone and not a lucky pattern match. The assertion is
# on the whole var value: value masking matches the value the env var holds,
# not some substring of it.
secret="twilio-$$-$RANDOM$RANDOM$RANDOM$RANDOM-credential"
export TWILIO_AUTH_TOKEN="$secret"
out=$(redact_sensitive "before $secret after")
if [[ "$out" != *"$secret"* && "$out" == *redacted* ]]; then
    ok "TWILIO_AUTH_TOKEN value is masked"
else
    bad "TWILIO_AUTH_TOKEN value is masked" "$out"
fi
unset TWILIO_AUTH_TOKEN

# Prose that merely resembles a token shape must come back unchanged.
plain="see https://github.com/headlong42/headlong/pull/8 and http://host.example:8080/api plus xox-shaped mention hf_word and sk- short note 12345"
out=$(redact_sensitive "$plain")
if [[ "$out" == "$plain" ]]; then
    ok "prose that resembles a token is left alone"
else
    bad "prose that resembles a token is left alone" "$out"
fi

# Existing provider values are credentials even when short. Pattern characters
# in a value are literal; they must neither broaden the match nor escape it.
for var in OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY OPENCODE_API_KEY; do
    for secret in localpw 'x*y?[z]'; do
        export "$var=$secret"
        out=$(redact_sensitive "before $secret after xxyaz")
        if [[ "$out" == 'before <redacted-api-key> after xxyaz' ]]; then
            ok "$var short literal value is masked"
        else
            bad "$var short literal value is masked" "$out"
        fi
        unset "$var"
    done
done

# Exercise the streaming caller, not just a complete string passed to sed.
# Preserve its returned cursor and PEM state exactly as run_loop does.
eval "$(sed -n '/^_stream_new_output()/,/^}/p' "$REPO/bin/shellm")"
WORK=$(mktemp -d) || exit 1
# Build synthetic delimiters without literal secret-scanner matches.
pem_begin=$(printf '%s' '-----BEGIN ' 'PRIVATE KEY-----')
pem_end=$(printf '%s' '-----END ' 'PRIVATE KEY-----')
trap 'rm -rf "$WORK"' EXIT
# Used by the extracted function.
# shellcheck disable=SC2034
QUIET=0
stream_poll() {
    read -r cursor pem_open <<< "$(_stream_new_output "$WORK/output" "$cursor" "$pem_open" 2>> "$WORK/display")"
}
stream_clean() {
    local label="$1"
    if ! grep -q 'PRIVATE_BODY' "$WORK/display" && grep -q 'redacted' "$WORK/display"; then
        ok "$label masks the private-key body"
    else
        bad "$label masks the private-key body" "$(cat "$WORK/display")"
    fi
}
for kind in '' 'RSA ' 'EC ' 'OPENSSH ' 'ENCRYPTED '; do
    cursor=0; pem_open=0
    : > "$WORK/display"
    printf '%s\n' 'ordinary before' "-----BEGIN ${kind}PRIVATE KEY-----" \
        'PRIVATE_BODY_fixture' "-----END ${kind}PRIVATE KEY-----" 'ordinary after' > "$WORK/output"
    stream_poll
    stream_clean "${kind}PEM in one poll"
    if grep -q 'ordinary before' "$WORK/display" && grep -q 'ordinary after' "$WORK/display"; then
        ok "${kind}PEM preserves surrounding lines"
    else
        bad "${kind}PEM preserves surrounding lines"
    fi
done
cursor=0; pem_open=0
: > "$WORK/display"
printf '%s\n' 'ordinary before' "$pem_begin" > "$WORK/output"
stream_poll
stream_poll  # no new output must preserve the open block
printf '%s\n' 'PRIVATE_BODY_first' >> "$WORK/output"
stream_poll
# A partial line waits until its terminating newline arrives.
printf '%s' 'PRIVATE_BODY_second' >> "$WORK/output"
stream_poll
printf '\n%s\n%s\n' "$pem_end" 'ordinary after' >> "$WORK/output"
stream_poll
stream_clean 'PEM across polls and partial lines'
if grep -q 'ordinary before' "$WORK/display" && grep -q 'ordinary after' "$WORK/display"; then
    ok 'split PEM preserves surrounding lines'
else
    bad 'split PEM preserves surrounding lines'
fi
before=$(cat "$WORK/display")
stream_poll
if [[ "$(cat "$WORK/display")" == "$before" ]]; then
    ok 'unchanged output is not repeated'
else
    bad 'unchanged output is not repeated'
fi
cursor=0; pem_open=0
: > "$WORK/display"
printf '%s\n' "$pem_begin" 'PRIVATE_BODY_unterminated' > "$WORK/output"
stream_poll
printf '%s\n' 'PRIVATE_BODY_later' >> "$WORK/output"
stream_poll
stream_clean 'unterminated PEM across polls'
# Each execution truncates .output and starts a new cursor and PEM state.
cursor=0; pem_open=0
: > "$WORK/display"
printf '%s\n' 'next execution' > "$WORK/output"
stream_poll
if grep -q 'next execution' "$WORK/display"; then
    ok 'new execution is not suppressed after an unterminated key'
else
    bad 'new execution is not suppressed after an unterminated key'
fi

# Main can omit a flood's prefix. A header in that prefix must still hide
# bodies in the displayed tail and later polls. Ending the block resumes text.
# Used by the extracted function.
# shellcheck disable=SC2034
STREAM_MAX_LINES=2
cursor=0; pem_open=0
: > "$WORK/display"
printf '%s\n' "$pem_begin" 'PRIVATE_BODY_skipped' \
    'PRIVATE_BODY_tail1' 'PRIVATE_BODY_tail2' > "$WORK/output"
stream_poll
printf '%s\n' 'PRIVATE_BODY_next_poll' "$pem_end" 'after flood' >> "$WORK/output"
stream_poll
if ! grep -q 'PRIVATE_BODY' "$WORK/display" && grep -q 'after flood' "$WORK/display"; then
    ok 'omitted PEM delimiters still govern displayed output'
else
    bad 'omitted PEM delimiters still govern displayed output'
fi
unset STREAM_MAX_LINES

# Run the real loop too: a complete streamed block, an unterminated block,
# then a clean execution verify both call sites and the per-execution reset.
# Inherited identity paths must not override this test's disposable state home.
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR ROOT_TRAJ_ID IDENTITY_DIR IDENTITY_NAME
mkdir -p "$WORK/home" "$WORK/wd"
printf '%s\n' 'loop before' "$pem_begin" 'PRIVATE_BODY_loop' \
    "$pem_end" 'loop after' > "$WORK/pem-input"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
case " $* " in *' --thinking '*) ;; *) printf '{}\n'; exit 0 ;; esac
n=0
[[ ! -f "$REDACT_TEST_COUNTER" ]] || read -r n < "$REDACT_TEST_COUNTER"
n=$((n + 1))
printf '%s\n' "$n" > "$REDACT_TEST_COUNTER"
printf '```bash\nset +x\n'
case "$n" in
    1) cat <<'CODE'
head -n 2 "$REDACT_TEST_INPUT"
sleep 0.4
sed -n '3p' "$REDACT_TEST_INPUT"
sleep 0.4
tail -n +4 "$REDACT_TEST_INPUT"
CODE
       ;;
    2) cat <<'CODE'
sed -n '2,3p' "$REDACT_TEST_INPUT"
CODE
       ;;
    *) printf '%s\n' "printf '%s\\n' 'clean next execution'" 'FINAL=done' ;;
esac
printf '```\n'
STUB
chmod +x "$WORK/toolbin/llm"
if HOME="$WORK/home" HEADLONG_HOME="$WORK/home/.headlong" \
    PATH="$WORK/toolbin:$PATH" SHELLM_ENV=local SHELLM_MODEL=test-model \
    ANTHROPIC_API_KEY=test-key REDACT_TEST_COUNTER="$WORK/counter" REDACT_TEST_INPUT="$WORK/pem-input" \
    "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 3 'test redaction' \
    > "$WORK/loop-out" 2> "$WORK/loop-err" < /dev/null \
    && [[ "$(cat "$WORK/loop-out")" == "done" ]] \
    && ! grep -q 'PRIVATE_BODY' "$WORK/loop-err" \
    && grep -q 'loop before' "$WORK/loop-err" \
    && grep -q 'loop after' "$WORK/loop-err" \
    && grep -q 'clean next execution' "$WORK/loop-err"; then
    ok 'real loop masks PEM across polls, drains output, and resets each execution'
else
    bad 'real loop masks PEM across polls, drains output, and resets each execution' "$(tail -10 "$WORK/loop-err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
