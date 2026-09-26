#!/usr/bin/env bash
set -uo pipefail

# deploy/thinkers-tmp-reaper.sh — sweep the shared temp dir of what a
# killed run left behind. Runs as the shellm user from
# headlong-thinkers-silence@<identity>.service, every five minutes, next to
# the silence and disk checks. Only the box deploy (deploy/setup.sh,
# deploy/update.sh) installs that unit; the laptop installer never does.
#
# Why: a command inside a wake that calls `mktemp`, copies something big and
# is then killed by the inactivity watchdog never runs its cleanup. Wakes
# share the real /tmp (no PrivateTmp on the dispatcher unit), so the leak
# accumulates across wakes. 2026-09-16 and 09-17: Audel's own
# trajectory-check skill wrote 1.6 GB copies of its trajectory a dozen times
# an hour and filled the 38 GB root disk twice; the second time took the
# mind down for fourteen hours. `bin/shellm` now points TMPDIR at the run
# dir, which dies with the run, so this is the backstop for hard-coded
# /tmp paths and for runs killed before their EXIT trap.
#
# Safety rules, in order of what they rule out:
#   - never runs as root: root-owned temp files are not ours to judge;
#   - the temp root must resolve to a path inside a known temp tree
#     (/tmp, /var/tmp, macOS /var/folders); anything else, including /,
#     $HOME or an ancestor of $HOME, is refused with a message;
#   - only entries directly under the temp root, only ones owned by the
#     invoking user, never through symlinks (-type f / -type d), names
#     passed NUL-delimited, and trees removed without crossing mount points;
#   - and only when old enough:
#       files  > HEADLONG_TMP_REAP_MB (100 MB) and older than
#                HEADLONG_TMP_REAP_MIN (30 min)
#       dirs   shellm-run.* / shellm-exec.* older than
#                HEADLONG_TMP_REAP_DIR_HOURS (24 h)
#       files  tmp.* older than HEADLONG_TMP_REAP_DIR_HOURS
#
# Usage: thinkers-tmp-reaper.sh [APP_DIR IDENTITY]   (args accepted, unused)

BIG_MB="${HEADLONG_TMP_REAP_MB:-100}"
BIG_MIN="${HEADLONG_TMP_REAP_MIN:-30}"
DIR_HOURS="${HEADLONG_TMP_REAP_DIR_HOURS:-24}"

refuse() { printf 'thinkers-tmp-reaper: refusing: %s\n' "$1" >&2; exit 0; }

[[ "$(id -u)" -eq 0 ]] && refuse "running as root"
me=$(id -un)

TMP_ROOT="${HEADLONG_TMP_ROOT:-${TMPDIR:-/tmp}}"
[[ -d "$TMP_ROOT" ]] || exit 0
# Resolve symlinks and relative parts before judging the path.
TMP_ROOT=$(cd "$TMP_ROOT" 2>/dev/null && pwd -P) || exit 0
case "$TMP_ROOT" in
    /tmp|/var/tmp|/private/tmp|/private/var/tmp) ;;
    /tmp/*|/var/tmp/*|/private/tmp/*|/private/var/tmp/*|/var/folders/*|/private/var/folders/*) ;;
    *) refuse "$TMP_ROOT is not inside a known temp tree" ;;
esac
for guard in / "${HOME:-/nonexistent}" "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)"; do
    [[ -n "$guard" ]] || continue
    [[ "$TMP_ROOT" == "$guard" ]] && refuse "$TMP_ROOT is $guard"
    [[ "${guard#"$TMP_ROOT"/}" != "$guard" ]] && refuse "$TMP_ROOT contains $guard"
done

files=0 dirs=0 kb=0
# du prints the name after the size; a name with a newline would spill
# into a second line, so keep only the first field of the first line.
size_kb() {
    local v
    v=$(du -sk "$1" 2>/dev/null | head -n 1 | awk '{print $1}')
    [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'
}
# remove_tree DIR: depth-first, never across a mount point, never through a
# symlink (find does not follow them without -L).
remove_tree() { find "$1" -xdev -depth -delete 2>/dev/null; [[ ! -e "$1" ]]; }

# 1. big, stale files (the trajectory copies)
while IFS= read -r -d '' f; do
    kb=$(( kb + $(size_kb "$f") ))
    rm -f "$f" 2>/dev/null && files=$((files + 1))
    printf 'reaped file %s\n' "$f"
done < <(find "$TMP_ROOT" -maxdepth 1 -mindepth 1 -user "$me" -type f -size +"${BIG_MB}M" -mmin +"$BIG_MIN" -print0 2>/dev/null)

# 2. run dirs whose owner died before cleanup
while IFS= read -r -d '' d; do
    kb=$(( kb + $(size_kb "$d") ))
    remove_tree "$d" && dirs=$((dirs + 1))
    printf 'reaped dir %s\n' "$d"
done < <(find "$TMP_ROOT" -maxdepth 1 -mindepth 1 -user "$me" -type d \( -name 'shellm-run.*' -o -name 'shellm-exec.*' \) -mmin +"$(( DIR_HOURS * 60 ))" -print0 2>/dev/null)

# 3. small mktemp leftovers, a day old
while IFS= read -r -d '' f; do
    kb=$(( kb + $(size_kb "$f") ))
    rm -f "$f" 2>/dev/null && files=$((files + 1))
done < <(find "$TMP_ROOT" -maxdepth 1 -mindepth 1 -user "$me" -type f -name 'tmp.*' -mmin +"$(( DIR_HOURS * 60 ))" -print0 2>/dev/null)

if (( files + dirs > 0 )); then
    printf '%s [thinkers-tmp-reaper] reaped %d files, %d dirs, %d MB from %s\n' \
        "$(date -u +%FT%TZ)" "$files" "$dirs" "$(( kb / 1024 ))" "$TMP_ROOT"
fi
exit 0
