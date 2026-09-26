#!/usr/bin/env bash
set -euo pipefail

# deploy/bootstrap-slack-identity.sh — idempotent bootstrap for the Slack
# persona: create the identity if missing, install its persona prompt, and
# make sure the monolith thinker dispatcher is running.
#
# Runs as the shellm user via headlong-slack-agent.service (oneshot); safe to
# re-run any time. Usage: bootstrap-slack-identity.sh [APP_DIR]

APP_DIR="${1:-/opt/shellm/app}"
cd "$APP_DIR"
# bin/ holds the mind's commands (thinkers, traj, chat); tools/ holds the
# operator commands (identity, persona). The 2026-08-20 bin/ -> tools/ move
# left `identity` off this PATH, which broke every fresh persona boot with
# "identity: command not found" (first seen on the Harris box, 2026-09-14;
# Audel's identity already existed so its box never re-ran that step).
export PATH="$APP_DIR/bin:$APP_DIR/tools:$PATH"
for cmd in identity thinkers; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' not on PATH ($PATH)" >&2; exit 1; }
done

# Root .env carries SHELLM_SLACK_IDENTITY (and the API keys thinkers need)
if [[ -f "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env"
    set +a
fi
name="${SHELLM_SLACK_IDENTITY:-audel}"

# The identity CLI treats IDENTITY_DIR as the identities ROOT when no
# identity is active (same convention as the web server's control plane).
unset IDENTITY_NAME
export IDENTITY_DIR="$APP_DIR/.identities"
mkdir -p "$IDENTITY_DIR"

if [[ ! -d "$IDENTITY_DIR/$name" ]]; then
    echo "==> Creating identity '$name'"
    identity new "$name"
fi

# Persona prompt: a per-identity file under deploy/personas/ wins (Harris has
# its own; Audel predates the directory), else the shared template. Copied
# once at creation only — the live copy is edited in the identity dir.
persona_src="$APP_DIR/deploy/personas/$name.md"
[[ -f "$persona_src" ]] || persona_src="$APP_DIR/deploy/slack-persona.md"
if [[ ! -f "$IDENTITY_DIR/$name/core_identity_prompt.md" && -f "$persona_src" ]]; then
    echo "==> Installing persona prompt from ${persona_src#"$APP_DIR"/}"
    cp "$persona_src" "$IDENTITY_DIR/$name/core_identity_prompt.md"
fi

# Activate the identity (exports IDENTITY_NAME, TRAJ_DIR, THINKERS_DIR, ...).
# activate is written for interactive shells: its internal greps (e.g. for an
# absent think_model= line) legitimately fail, which is fatal under this
# script's set -euo pipefail — so relax the guards around the source.
set +eu
set +o pipefail
# shellcheck disable=SC1090,SC1091
source "$IDENTITY_DIR/$name/activate"
set -eu
set -o pipefail
[[ -n "${IDENTITY_NAME:-}" ]] || { echo "error: activate did not set IDENTITY_NAME" >&2; exit 1; }

# Always stop, then start, so the dispatcher runs with the environment THIS
# invocation sourced. On first boot the unit starts before the SSM .env
# lands; a surviving dispatcher keeps that stale environment (wrong model,
# no keys) forever. Stop unconditionally — `thinkers stop` is idempotent.
# An earlier version detected a running dispatcher first with
# `thinkers status | grep -q`, which under pipefail loses a SIGPIPE race
# (grep -q exits at first match, status dies writing the rest, the matched
# check reads as false) — that silent miss left Audel keyless in the workspace
# on 2026-08-04 until manually cycled. Detection is exactly the kind of
# step that fails silently; don't detect, just stop.
echo "==> Restarting thinkers with current environment"
# Prefer the per-identity systemd unit (own cgroup; see
# deploy/headlong-thinkers@.service) — its start path also stops any stale
# dispatcher and re-sources the env. Fall back to the direct start on boxes
# provisioned before the unit existed.
if [[ -x /usr/local/bin/headlong-thinkersctl ]] \
    && sudo -n /usr/local/bin/headlong-thinkersctl restart "$name"; then
    echo "==> Thinkers running under headlong-thinkers@$name"
else
    echo "==> thinkers unit unavailable — starting directly (legacy path)"
    # --self: this oneshot is an authorized stop path (it restarts the
    # dispatcher right below), so opt out of the in-flight-step guard in
    # `thinkers stop` rather than rely on how narrowly it matches. A
    # dispatcher from an earlier bootstrap run shares this cgroup
    # (headlong-slack-agent's), but is not that unit's main process, so
    # stopping it sweeps nothing.
    thinkers stop --self || true
    echo "==> Starting monolith + responder thinkers"
    thinkers start monolith responder
fi

echo "==> Persona '$name' ready"
