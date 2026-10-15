#!/usr/bin/env bash
# Synthetic fixtures only; no model, Docker, or network calls.
set -euo pipefail
export SHELLM_ENV=local
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../thinkers/_lib/common.sh
source "$HERE/../thinkers/_lib/common.sh"
pass=0; fail=0
check() {
    local label="$1" input="$2" expected="$3" actual
    actual=$(prompt_redact "$input") || actual='redaction failed'
    if [[ "${4:-}" == json ]]; then actual=$(printf '%s' "$actual" | jq -c .); fi
    if [[ "$actual" == "$expected" ]]; then
        pass=$((pass + 1)); printf 'ok   %s\n' "$label"
    else
        fail=$((fail + 1)); printf 'FAIL %s\n' "$label"
    fi
}
# Assemble unmistakably synthetic fixtures without literal secret-scanner matches.
pem_begin=$(printf '%s' '-----BEGIN ' 'PRIVATE KEY-----')
pem_end=$(printf '%s' '-----END ' 'PRIVATE KEY-----')
pem="$pem_begin"$'\nU1lOVEhFVElD\n'"$pem_end"
check 'plain text unchanged' $'hello\nRouting signals:\nChoose ONE' $'hello\nRouting signals:\nChoose ONE'
check 'multiline PEM preserves surrounding text' "before $pem after" 'before <redacted:private-key> after'
check 'same-line PEM preserves suffix' "before ${pem_begin}U1lOVEhFVElD${pem_end} after" 'before <redacted:private-key> after'
check 'incomplete plain PEM preserves next section' $'before\n'"$pem_begin"$'\nU1lOVEhFVElD\n\nRouting signals:\nChoose ONE' $'before\n<redacted:private-key>\n\nRouting signals:\nChoose ONE'
for content in "$pem" "$pem_begin"$'\nU1lOVEhFVElD' "$(printf '%1600s' '' | tr ' ' x)"; do
    record=$(printf '%s' "$content" | jq -Rsc '{type:"thought",content:.,source:"test"}')
    expected=$(printf '%s' "$content" | jq -Rsc 'if startswith("-----BEGIN") then "<redacted:private-key>" else . end | {type:"thought",content:.,source:"test"}')
    check 'serialized field preserves record and next section' "$record"$'\nRouting signals:\nChoose ONE' "$expected"$'\nRouting signals:\nChoose ONE'
done
auth='{"auth":"U1lOVEhFVElDOk5PVF9BX1NFQ1JFVA=="}'
record=$(printf '%s' "$auth" | jq -Rsc '{content:.}')
expected=$(printf '%s' '{"auth": "<redacted:docker-auth>"}' | jq -Rsc '{content:.}')
check 'Docker auth in serialized content' "$record" "$expected"
check 'nested Docker auth object' "$auth" '{"auth":"<redacted:docker-auth>"}' json
# Shell-local values are supported too; quoting must not turn them into globs.
GITHUB_TOKEN='synthetic[env]*value?123'
check 'literal env value' "$GITHUB_TOKEN" '<redacted:value>'
GITHUB_TOKEN=$'synthetic"value\\with\nnewlines'
record=$(printf '%s' "$GITHUB_TOKEN" | jq -Rsc '{content:.}')
check 'escaped env value in JSON' "$record" '{"content":"<redacted:value>"}'
unset GITHUB_TOKEN
check 'GitHub token' 'ghp_abcdefghijklmnopqrstuvwxyz' '<redacted:github-token>'
check 'Slack token' 'xoxb-abcdefghijklmnop' '<redacted:slack-token>'
check 'API key' 'sk-abcdefghijklmnopqrstuvwxyz' '<redacted:api-key>'
check 'API key boundary' 'task-abcdefghijklmnopqrstuvwxyz' 'task-abcdefghijklmnopqrstuvwxyz'
check 'card' '4111 1111 1111 1111' '<redacted:card>'
check 'basic auth URL' 'https://user:pass@example.test' 'https://<redacted:basic-auth>@example.test'
check 'HF token' 'hf_abcdefghijklmnopqrstuvwxyz' '<redacted:hf-token>'
check 'AWS key' "$(printf '%s' 'AKIA' 'ABCDEFGHIJKLMNOP')" '<redacted:aws-key>'
check 'Stripe key' "$(printf '%s' 'sk_live_' 'abcdefghijklmnop')" '<redacted:stripe-key>'
check 'GitHub PAT' 'github_pat_abcdefghijklmnopqrstuv' '<redacted:github-token>'
check 'Google key' 'AIzaabcdefghijklmnopqrstuvwxyz0123456789' '<redacted:google-key>'
check 'JWT' 'eyJabcdefghijkl.abcdefghijkl.abcdefghijkl' '<redacted:jwt>'
check 'Stripe webhook' 'whsec_abcdefghijkl' '<redacted:stripe-hook>'
check 'npm token' 'npm_abcdefghijklmnopqrstuvwxyz' '<redacted:npm-token>'
check 'GitLab token' 'glpat-abcdefghijkl' '<redacted:gitlab-token>'
check 'Docker PAT' 'dckr_pat-abcdefghijkl' '<redacted:docker-token>'
check 'SendGrid token' 'SG.abcdefghijkl.abcdefghijkl' '<redacted:sendgrid-key>'
check 'Twilio key' "$(printf '%s' 'SK' 'abcdef0123456789abcdef0123456789')" '<redacted:twilio-key>'
check 'Mailgun key' 'key-abcdefghijklmnopqrstuvwxyz' '<redacted:mailgun-key>'
check 'AWS secret assignment' 'aws_secret_access_key=synthetic-value' 'aws_secret_access_key=<redacted:aws-secret>'
check 'card without separators' '4111111111111111' '<redacted:card>'
check 'labelled card' 'VISA is 4111 1111 1111 1111' 'VISA is <redacted:card>'
check 'empty text' '' ''
check 'multiple PEM blocks' "$pem middle $pem end" '<redacted:private-key> middle <redacted:private-key> end'
check 'ordinary JSON formatting' '{ "content": "hello", "n": 42 }' '{ "content": "hello", "n": 42 }'
big=$(head -c 300000 /dev/zero | tr '\0' x)
check '300KB text preserved' "$big" "$big"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
