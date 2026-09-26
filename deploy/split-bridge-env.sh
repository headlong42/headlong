#!/usr/bin/env bash
set -euo pipefail

# deploy/split-bridge-env.sh — move the Slack bridge's tokens out of the
# root .env into .env.bridge, which the mind cannot read.
#
# Usage: split-bridge-env.sh APP_DIR        (idempotent; run by update.sh,
#                                             setup.sh and the box user_data)
#
# Why. The root .env is sourced into every wake (deploy/thinkers-service.sh),
# so the mind has held the Slack bot and app tokens since day one; on
# 2026-09-14 it copied the whole file into a second identity it created.
# The bridge is the only process that needs those tokens. After this
# split:
#
#   APP_DIR/.env          everything the mind and the dash need: LLM keys,
#                         model names, channel ids, thinker knobs,
#                         HEADLONG_ALERT_TOKEN (see below)
#   APP_DIR/.env.bridge   SLACK_BOT_TOKEN and SLACK_APP_TOKEN, mode 600,
#                         loaded by headlong-slack-bridge.service only and
#                         listed as InaccessiblePaths in the thinkers
#                         sandbox (deploy/thinkers-sandbox.sh)
#
# Telegram already has this shape (/etc/shellm/telegram.env, root-owned,
# a separate unit user); this brings Slack level with it.
#
# The alert scripts (thinkers-death/failure/silence-alert.sh) run inside
# the thinkers unit, so they cannot read .env.bridge either. They post
# with HEADLONG_ALERT_TOKEN from .env. On first split that is seeded as a
# COPY of the bot token so alerts keep working, with a comment saying so:
# the split is only complete once you replace it with a token from a
# dedicated alert-only Slack app (chat:write to the alert channel). Until
# then a mind that reads .env still holds a token that can post as the
# bot; it just cannot open the Socket Mode connection (that needs the app
# token, which is gone from .env).
#
# The SSM parameter a rebuilt box bootstraps from still holds the full
# file; the box user_data runs this split right after writing .env, so a
# rebuild lands in the same place.

APP_DIR="${1:?usage: split-bridge-env.sh APP_DIR}"
ENV="$APP_DIR/.env"
BRIDGE="$APP_DIR/.env.bridge"
KEYS="SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_CLI_XOXB SLACK_CLI_XAPP"

[[ -f "$ENV" ]] || { echo "split-bridge-env: no $ENV; nothing to do"; exit 0; }

# Lines to move: an uncommented KEY=... for any bridge key.
pattern=""
for k in $KEYS; do pattern="${pattern}${pattern:+|}${k}"; done
moving=$(grep -E "^[[:space:]]*(${pattern})=" "$ENV" || true)
if [[ -z "$moving" ]]; then
    echo "split-bridge-env: no bridge tokens in $ENV; nothing to move"
    exit 0
fi

owner=$(stat -c '%U:%G' "$ENV" 2>/dev/null || stat -f '%Su:%Sg' "$ENV")
stamp=$(date -u +%Y%m%dT%H%M%SZ)
cp -p "$ENV" "$ENV.bak-split-$stamp"

# .env.bridge: append. Only the keys moving THIS time are replaced there,
# so a re-push of the root env with one rotated token propagates it and
# leaves the other tokens as they were.
moving_keys=$(printf '%s\n' "$moving" | sed -n 's/^[[:space:]]*\([A-Z_]*\)=.*/\1/p' | sort -u)
moving_pattern=""
for k in $moving_keys; do moving_pattern="${moving_pattern}${moving_pattern:+|}${k}"; done
tmpb=$(mktemp "$APP_DIR/.env.bridge.XXXXXX")
if [[ -f "$BRIDGE" ]]; then
    grep -Ev "^[[:space:]]*(${moving_pattern})=" "$BRIDGE" > "$tmpb" || true
else
    printf '# Slack bridge tokens. Loaded by headlong-slack-bridge.service only;\n# unreadable from inside a wake (thinkers sandbox). Written by\n# deploy/split-bridge-env.sh from the root .env.\n' > "$tmpb"
fi
printf '%s\n' "$moving" >> "$tmpb"
chmod 600 "$tmpb"
chown "$owner" "$tmpb" 2>/dev/null || true
mv "$tmpb" "$BRIDGE"

# .env: drop the moved lines, seed the alert token if absent.
tmpe=$(mktemp "$APP_DIR/.env.XXXXXX")
grep -Ev "^[[:space:]]*(${pattern})=" "$ENV" > "$tmpe" || true
if ! grep -qE '^[[:space:]]*HEADLONG_ALERT_TOKEN=' "$tmpe"; then
    bot=$(printf '%s\n' "$moving" | sed -n 's/^[[:space:]]*SLACK_BOT_TOKEN=//p' | tail -n 1)
    if [[ -n "$bot" ]]; then
        printf '\n# Slack tokens moved to .env.bridge by deploy/split-bridge-env.sh (%s).\n' "$stamp" >> "$tmpe"
        printf '# HEADLONG_ALERT_TOKEN is what the box alert scripts post with. Seeded as a\n# copy of the bot token; replace it with a dedicated alert-only app token to\n# finish the split (see deploy/split-bridge-env.sh).\n' >> "$tmpe"
        printf 'HEADLONG_ALERT_TOKEN=%s\n' "$bot" >> "$tmpe"
    fi
else
    printf '\n# Slack tokens moved to .env.bridge by deploy/split-bridge-env.sh (%s).\n' "$stamp" >> "$tmpe"
fi
chmod 600 "$tmpe"
chown "$owner" "$tmpe" 2>/dev/null || true
mv "$tmpe" "$ENV"

n=$(printf '%s\n' "$moving" | wc -l | tr -d ' ')
echo "split-bridge-env: moved $n bridge token line(s) to $BRIDGE (backup $ENV.bak-split-$stamp)"
