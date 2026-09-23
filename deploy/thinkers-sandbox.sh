#!/usr/bin/env bash
set -euo pipefail

# deploy/thinkers-sandbox.sh — install or remove the runtime sandbox drop-in
# for headlong-thinkers@<identity>.service, from one flag.
#
# Usage:
#   thinkers-sandbox.sh install APP_DIR [SHELLM_HOME] [UNIT_DIR]   write/remove the drop-in; prints installed|removed|unchanged
#   thinkers-sandbox.sh render  APP_DIR [SHELLM_HOME]              print the drop-in that install would write
#   thinkers-sandbox.sh status  APP_DIR [SHELLM_HOME] [UNIT_DIR]   print on|off (flag) and present|absent (drop-in)
#
# Flag: HEADLONG_SANDBOX in APP_DIR/.env (or the environment, which wins).
# Default ON. Set HEADLONG_SANDBOX=0 and re-run deploy/update.sh to remove
# the drop-in; the change reaches a running mind at its next
# `headlong-thinkersctl restart <identity>`.
#
# What the sandbox does. Every wake runs inside the thinkers unit's cgroup,
# so these mount rules apply to the run and to anything it backgrounds:
#
#   the whole filesystem       read-only   (ProtectSystem=strict)
#   the shellm home            writable    (tool caches, ~/.headlong state, backups)
#   the app checkout           read-only   (bin, thinkers, tools, deploy, .env)
#   the identity directory     writable    (memories, prompts, thinker copies,
#                                            workdir, its own clone of the repo;
#                                            at HEADLONG_IDENTITIES_DIR/<name>
#                                            when the root was moved out)
#   /tmp and /var/tmp          writable    (shared with the bridges, so a file
#                                            the mind writes for `chat send-file`
#                                            is still visible to them)
#   .env.bridge                unreadable  (the Slack bridge tokens; see
#                                            deploy/split-bridge-env.sh)
#
# Not NoNewPrivileges: sudoers already limits the shellm user to the
# headlong-thinkersctl wrapper, and that is the documented way for a mind
# to restart itself safely (the wake note and `thinkers stop` both point
# at it); it still works under the read-only root (verified 2026-09-15).
#
# The mind keeps sovereignty over its own identity directory and loses the
# ability to edit the shared runtime in place, to create identities beside
# its own, or to read the bridge's tokens. 2026-09-14: a wake created a second
# identity under .identities/, started two web servers and a nested
# dispatcher, and wedged its own wake loop for seven hours; every earlier
# self-inflicted incident (08-14, 09-08, 09-09, 09-12) also went through a
# door this closes. Contributions to the runtime go through the mind's own
# clone and pull requests, as they already do.
#
# Nested paths are honoured by systemd in path order (a longer path mounted
# later wins), which is what lets .identities/<name> be writable inside a
# read-only app checkout. Verified on systemd 255 (Ubuntu 24.04).

action="${1:?usage: thinkers-sandbox.sh install|render|status APP_DIR [SHELLM_HOME] [UNIT_DIR]}"
APP_DIR="${2:?APP_DIR required}"
SHELLM_HOME="${3:-$(dirname "$APP_DIR")}"
UNIT_DIR="${4:-/etc/systemd/system}"
DROPIN_DIR="$UNIT_DIR/headlong-thinkers@.service.d"
DROPIN="$DROPIN_DIR/sandbox.conf"

env_value() {  # env_value NAME -> the environment wins, then APP_DIR/.env
    local v="${!1:-}"
    if [[ -z "$v" && -r "$APP_DIR/.env" ]]; then
        v=$(sed -n "s/^[[:space:]]*$1=//p" "$APP_DIR/.env" | tail -n 1 | tr -d '"'"'" | tr -d '[:space:]')
    fi
    printf '%s' "$v"
}

flag_on() {
    local v
    v=$(env_value HEADLONG_SANDBOX)
    case "${v:-1}" in
        0|false|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

# Where the identities really live. systemd does not resolve symlinks in
# ReadWritePaths (probed 2026-09-15: a link at app/.identities pointing at
# /var/lib left both paths read-only), so when the identities root lives
# outside the checkout and is linked back (layer 0 of
# design/runtime_isolation.md), the writable mount must land on the real
# directory: the link at app/.identities is resolved, or
# HEADLONG_IDENTITIES_DIR in .env names it outright.
identities_dir() {
    local v d
    v=$(env_value HEADLONG_IDENTITIES_DIR)
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    d="$SHELLM_HOME/app/.identities"
    # No override: a bind mount (the provisioned layout) is a real directory
    # and needs nothing; a symlink is followed so that layout works too.
    if [[ -L "$d" ]]; then
        readlink -f -- "$d" 2>/dev/null || printf '%s' "$d"
    else
        printf '%s' "$d"
    fi
}

render() {
    cat <<CONF
# Installed by deploy/thinkers-sandbox.sh from HEADLONG_SANDBOX in
# $APP_DIR/.env (default on). Do not edit: set HEADLONG_SANDBOX=0 there
# and re-run deploy/update.sh to remove it. Takes effect on the next
# headlong-thinkersctl restart <identity>.
[Service]
ProtectSystem=strict
ReadWritePaths=$SHELLM_HOME /tmp /var/tmp
ReadOnlyPaths=$SHELLM_HOME/app
ReadWritePaths=$(identities_dir)/%i
InaccessiblePaths=-$SHELLM_HOME/app/.env.bridge
CONF
}

case "$action" in
    render)
        render
        ;;
    status)
        if flag_on; then printf 'on '; else printf 'off '; fi
        if [[ -f "$DROPIN" ]]; then echo present; else echo absent; fi
        ;;
    install)
        if flag_on; then
            if [[ -f "$DROPIN" ]] && render | cmp -s - "$DROPIN"; then
                echo unchanged
            else
                mkdir -p "$DROPIN_DIR"
                render > "$DROPIN.tmp"
                mv "$DROPIN.tmp" "$DROPIN"
                echo installed
            fi
        else
            if [[ -f "$DROPIN" ]]; then
                rm -f "$DROPIN"
                rmdir "$DROPIN_DIR" 2>/dev/null || true
                echo removed
            else
                echo unchanged
            fi
        fi
        ;;
    *)
        echo "error: unknown action: $action (want install|render|status)" >&2
        exit 2
        ;;
esac
