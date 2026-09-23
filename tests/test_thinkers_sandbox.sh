#!/usr/bin/env bash
# test_thinkers_sandbox.sh — deploy/thinkers-sandbox.sh: the drop-in follows
# HEADLONG_SANDBOX (default on), installs and removes idempotently, and
# carries the mount rules the sandbox is made of.
#
# Usage: tests/test_thinkers_sandbox.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SCRIPT="$REPO/deploy/thinkers-sandbox.sh"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
APP="$HOME_DIR/app"
UNITS="$TMP/units"
mkdir -p "$APP" "$UNITS"
DROPIN="$UNITS/headlong-thinkers@.service.d/sandbox.conf"

run() { env -u HEADLONG_SANDBOX bash "$SCRIPT" "$@"; }

# 1. render: the rules
out=$(run render "$APP" "$HOME_DIR")
grep -q '^ProtectSystem=strict$' <<< "$out" && ok "render: whole filesystem read-only" || bad "render: whole filesystem read-only"
grep -q "^ReadWritePaths=$HOME_DIR /tmp /var/tmp$" <<< "$out" && ok "render: home and temp dirs writable" || bad "render: home and temp dirs writable" "$out"
grep -q "^ReadOnlyPaths=$APP$" <<< "$out" && ok "render: app checkout read-only" || bad "render: app checkout read-only"
grep -q "^ReadWritePaths=$APP/.identities/%i$" <<< "$out" && ok "render: the identity directory writable (per instance)" || bad "render: identity dir writable"
grep -q "^InaccessiblePaths=-$APP/.env.bridge$" <<< "$out" && ok "render: bridge tokens unreadable" || bad "render: bridge tokens unreadable"
! grep -q 'NoNewPrivileges' <<< "$out" && ok "render: sudo wrapper path left open (no NoNewPrivileges)" || bad "render: NoNewPrivileges must stay out (self-restart path)"
[[ "$(sed -n '/^\[Service\]/,$p' <<< "$out" | grep -c '^\[')" -eq 1 ]] && ok "render: single [Service] section" || bad "render: single [Service] section"

# 2. install with no .env: default on
r=$(run install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == installed && -f "$DROPIN" ]] && ok "install: default (no .env) writes the drop-in" || bad "install: default writes the drop-in" "$r"
r=$(run install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == unchanged ]] && ok "install: second run unchanged" || bad "install: second run unchanged" "$r"
[[ "$(run status "$APP" "$HOME_DIR" "$UNITS")" == "on present" ]] && ok "status: on present" || bad "status: on present"

# 3. flag off in .env removes it
printf 'OPENROUTER_API_KEY=x\nHEADLONG_SANDBOX=0\n' > "$APP/.env"
r=$(run install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == removed && ! -f "$DROPIN" ]] && ok "install: HEADLONG_SANDBOX=0 removes the drop-in" || bad "install: flag off removes" "$r"
[[ ! -d "$UNITS/headlong-thinkers@.service.d" ]] && ok "install: empty drop-in dir removed" || bad "install: empty drop-in dir removed"
r=$(run install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == unchanged ]] && ok "install: off stays off, unchanged" || bad "install: off unchanged" "$r"
[[ "$(run status "$APP" "$HOME_DIR" "$UNITS")" == "off absent" ]] && ok "status: off absent" || bad "status: off absent"

# 4. quoted / spaced values and re-enable
printf 'HEADLONG_SANDBOX="1"\n' > "$APP/.env"
r=$(run install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == installed && -f "$DROPIN" ]] && ok "install: quoted 1 re-installs" || bad "install: quoted 1 re-installs" "$r"
printf 'HEADLONG_SANDBOX=off\n' > "$APP/.env"
[[ "$(run install "$APP" "$HOME_DIR" "$UNITS")" == removed ]] && ok "install: 'off' is off" || bad "install: 'off' is off"

# 5. environment wins over .env
printf 'HEADLONG_SANDBOX=0\n' > "$APP/.env"
r=$(HEADLONG_SANDBOX=1 bash "$SCRIPT" install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == installed ]] && ok "install: environment overrides .env" || bad "install: environment overrides .env" "$r"

# 6. a stale drop-in with different content is rewritten
printf '[Service]\nProtectSystem=full\n' > "$DROPIN"
printf 'HEADLONG_SANDBOX=1\n' > "$APP/.env"
r=$(run install "$APP" "$HOME_DIR" "$UNITS")
[[ "$r" == installed ]] && grep -q 'ProtectSystem=strict' "$DROPIN" && ok "install: stale drop-in rewritten" || bad "install: stale drop-in rewritten" "$r"

# 7. a moved identities root: the writable mount names the real directory
printf 'HEADLONG_SANDBOX=1\nHEADLONG_IDENTITIES_DIR=/var/lib/headlong/identities\n' > "$APP/.env"
out=$(run render "$APP" "$HOME_DIR")
grep -q '^ReadWritePaths=/var/lib/headlong/identities/%i$' <<< "$out" && ok "render: HEADLONG_IDENTITIES_DIR moves the writable mount" || bad "render: HEADLONG_IDENTITIES_DIR" "$out"
grep -q "^ReadOnlyPaths=$APP$" <<< "$out" && ok "render: app checkout still read-only with a moved root" || bad "render: app still read-only"
out=$(HEADLONG_IDENTITIES_DIR=/srv/ids bash "$SCRIPT" render "$APP" "$HOME_DIR")
grep -q '^ReadWritePaths=/srv/ids/%i$' <<< "$out" && ok "render: environment overrides .env for the root" || bad "render: env override for root"
printf 'HEADLONG_SANDBOX=1\n' > "$APP/.env"
real="$TMP/var-lib-identities"; mkdir -p "$real"; ln -s "$real" "$APP/.identities"
real_resolved=$(cd "$real" && pwd -P)   # macOS: /var is itself a link to /private/var
out=$(run render "$APP" "$HOME_DIR")
grep -q "^ReadWritePaths=$real_resolved/%i$" <<< "$out" && ok "render: a linked .identities resolves to its real directory" || bad "render: linked .identities resolves" "$out"
rm -f "$APP/.identities"

# 8. the shipped installers call it
grep -q 'thinkers-sandbox.sh' "$REPO/deploy/update.sh" && grep -q 'thinkers-sandbox.sh' "$REPO/deploy/setup.sh" \
    && ok "update.sh and setup.sh install the drop-in" || bad "update.sh and setup.sh install the drop-in"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
