#!/usr/bin/env bash
# test_runtime_boundary_line.sh — the wake prompt's Runtime line states the
# read-only boundary only when the checkout really is unwritable from where
# the wake runs (the thinkers sandbox, deploy/thinkers-sandbox.sh).
#
# Usage: tests/test_runtime_boundary_line.sh
#
# Calls _runtime_line from thinkers/_lib/common.sh against a throwaway git
# checkout whose bin/ holds a stub shellm. Writable bin: no boundary
# sentence. bin without write permission: the sentence, naming the checkout
# and the identity directory. Skipped for root, who can write anywhere.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

if [[ "$(id -u)" -eq 0 ]]; then
    echo "skip: running as root, every directory is writable"
    echo; echo "0 passed, 0 failed"; exit 0
fi

W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
ROOT="$W/checkout"
mkdir -p "$ROOT/bin" "$W/ident/thinkers"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/shellm"; chmod +x "$ROOT/bin/shellm"
git -C "$ROOT" init -q && git -C "$ROOT" -c user.email=t@t -c user.name=t add -A && git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qm "stub checkout"

line() {
    ( export PATH="$ROOT/bin:$PATH" IDENTITY_DIR="$W/ident"
      # shellcheck disable=SC1091
      source "$REPO/thinkers/_lib/common.sh" >/dev/null 2>&1
      _runtime_line )
}

out=$(line)
grep -q '^Runtime: headlong [0-9a-f]\{7,\} (stub checkout)' <<< "$out" && ok "runtime line names the stub checkout" || bad "runtime line names the stub checkout" "$out"
! grep -q 'read-only inside a wake' <<< "$out" && ok "writable checkout: no boundary sentence" || bad "writable checkout: no boundary sentence" "$out"

chmod a-w "$ROOT/bin"
ROOT_REAL=$(cd "$ROOT" && pwd -P)   # macOS: /var is a symlink to /private/var
out=$(line)
grep -q "The checkout at $ROOT_REAL is read-only inside a wake" <<< "$out" && ok "unwritable checkout: boundary sentence names the checkout" || bad "unwritable checkout: boundary sentence" "$out"
grep -q "Your identity directory ($W/ident) is yours to write" <<< "$out" && ok "boundary sentence names the identity directory" || bad "boundary names identity dir" "$out"
grep -q 'own clone and a pull request' <<< "$out" && ok "boundary sentence says where runtime changes go" || bad "boundary says where changes go"
[[ "$(wc -l <<< "$out")" -eq 1 ]] && ok "still one line" || bad "still one line" "$(wc -l <<< "$out") lines"
chmod u+w "$ROOT/bin"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
