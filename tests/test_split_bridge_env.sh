#!/usr/bin/env bash
# test_split_bridge_env.sh — deploy/split-bridge-env.sh moves exactly the
# Slack bridge tokens out of the root .env, seeds the alert token once, is
# idempotent, and leaves everything else alone.
#
# Usage: tests/test_split_bridge_env.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SCRIPT="$REPO/deploy/split-bridge-env.sh"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/app"; mkdir -p "$APP"
ENV="$APP/.env"; BRIDGE="$APP/.env.bridge"

cat > "$ENV" <<'ENVF'
# LLM key — dedicated
OPENROUTER_API_KEY=sk-or-mind
# Slack bridge
SLACK_BOT_TOKEN=xoxb-bridge-1
SLACK_APP_TOKEN=xapp-bridge-1
SHELLM_SLACK_IDENTITY=audel
SHELLM_MODEL=some/model
SLACK_PEER_BOT_USERS=U1
#SLACK_BOT_TOKEN=xoxb-old-commented
ENVF
chmod 600 "$ENV"

# 1. first split
out=$(bash "$SCRIPT" "$APP")
grep -q 'moved 2 bridge token' <<< "$out" && ok "moves the two live token lines" || bad "moves the two live token lines" "$out"
! grep -q '^SLACK_BOT_TOKEN=\|^SLACK_APP_TOKEN=' "$ENV" && ok ".env no longer holds the tokens" || bad ".env no longer holds the tokens"
grep -q '^SLACK_BOT_TOKEN=xoxb-bridge-1$' "$BRIDGE" && grep -q '^SLACK_APP_TOKEN=xapp-bridge-1$' "$BRIDGE" && ok ".env.bridge holds them" || bad ".env.bridge holds them" "$(cat "$BRIDGE")"
for k in OPENROUTER_API_KEY=sk-or-mind SHELLM_SLACK_IDENTITY=audel SHELLM_MODEL=some/model SLACK_PEER_BOT_USERS=U1; do
    grep -q "^$k$" "$ENV" || bad "kept $k"
done
grep -q '^SLACK_PEER_BOT_USERS=U1$' "$ENV" && ok "non-secret Slack settings stay in .env" || bad "non-secret Slack settings stay"
grep -q '^#SLACK_BOT_TOKEN=xoxb-old-commented$' "$ENV" && ok "commented-out lines untouched" || bad "commented-out lines untouched"
grep -q '^HEADLONG_ALERT_TOKEN=xoxb-bridge-1$' "$ENV" && ok "alert token seeded from the bot token" || bad "alert token seeded" "$(grep ALERT "$ENV")"
grep -q 'dedicated alert-only' "$ENV" && ok "seed comment says how to finish the split" || bad "seed comment"
[[ "$(stat -c %a "$BRIDGE" 2>/dev/null || stat -f %Lp "$BRIDGE")" == 600 ]] && ok ".env.bridge is mode 600" || bad ".env.bridge is mode 600"
ls "$APP"/.env.bak-split-* >/dev/null 2>&1 && ok "backup written" || bad "backup written"

# 2. idempotent
out=$(bash "$SCRIPT" "$APP")
grep -q 'nothing to move' <<< "$out" && ok "second run is a no-op" || bad "second run is a no-op" "$out"
[[ "$(grep -c '^HEADLONG_ALERT_TOKEN=' "$ENV")" -eq 1 ]] && ok "alert token not duplicated" || bad "alert token not duplicated"

# 3. a re-pushed .env with a rotated token propagates into .env.bridge
printf 'SLACK_BOT_TOKEN=xoxb-bridge-2\n' >> "$ENV"
bash "$SCRIPT" "$APP" >/dev/null
grep -q '^SLACK_BOT_TOKEN=xoxb-bridge-2$' "$BRIDGE" && [[ "$(grep -c '^SLACK_BOT_TOKEN=' "$BRIDGE")" -eq 1 ]] \
    && ok "rotated token replaces the old one in .env.bridge" || bad "rotated token replaces" "$(cat "$BRIDGE")"
grep -q '^SLACK_APP_TOKEN=xapp-bridge-1$' "$BRIDGE" && ok "untouched app token survives the re-split" || bad "app token survives"
grep -q '^HEADLONG_ALERT_TOKEN=xoxb-bridge-1$' "$ENV" && ok "an existing alert token is not overwritten" || bad "existing alert token kept"

# 4. no .env at all
rm -f "$ENV"
bash "$SCRIPT" "$APP" >/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && ok "missing .env exits 0" || bad "missing .env exits 0"

# 5. the bridge unit loads .env.bridge and the alert scripts use the alert token
grep -q 'EnvironmentFile=-@SHELLM_HOME@/app/.env.bridge' "$REPO/deploy/headlong-slack-bridge.service" \
    && ok "slack bridge unit loads .env.bridge" || bad "slack bridge unit loads .env.bridge"
for s in thinkers-death-alert thinkers-failure-alert thinkers-silence-alert; do
    grep -q 'Bearer $ALERT_TOKEN' "$REPO/deploy/$s.sh" && grep -q 'HEADLONG_ALERT_TOKEN' "$REPO/deploy/$s.sh" \
        && ok "$s posts with HEADLONG_ALERT_TOKEN" || bad "$s posts with HEADLONG_ALERT_TOKEN"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
