#!/usr/bin/env bash
# Exercise the execution supervisor with a TERM-ignoring child. Set
# SHELLM_TEST_DOCKER_IMAGE to also test a real, network-disabled Docker container.
# Linux GitHub Actions runners also run Docker; other hosts opt in explicitly.
# The default local case needs no Docker daemon or API credentials.
set -uo pipefail
if [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == Linux ]]; then
    SHELLM_TEST_DOCKER_IMAGE="${SHELLM_TEST_DOCKER_IMAGE:-ubuntu:24.04}"
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
container="" exec_pid=""
cleanup() {
    [[ -z "$exec_pid" ]] || { kill "$exec_pid" 2>/dev/null || true; wait "$exec_pid" 2>/dev/null || true; }
    [[ -z "$container" ]] || docker rm -f "$container" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
pass=0 fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
eval "$(sed -n '/^_kill_exec_tree()/,/^}/p' "$REPO/bin/shellm")"
eval "$(sed -n '/^_supervise_exec()/,/^}/p' "$REPO/bin/shellm")"
eval "$(sed -n '/^execute_code()/,/^}/p' "$REPO/bin/shellm")"
_SHELLM_EXTRA_BINS=()
_SHELLM_CONTAINER=""

# Both parent and grandchild ignore TERM. Job control puts the grandchild in
# another process group, as a nested run can do. Its heartbeat must stop too.
producer_bash=bash
code='trap "" TERM
set -m
"$PRODUCER_BASH" -p -c '\''trap "" TERM; echo "$EUID" > producer.uid; echo ready > ready; end=$((SECONDS+15)); while [ $SECONDS -lt $end ]; do echo tick >> heartbeat; sleep 0.05; done; echo completed > completed'\'' &
wait'
read_probe() {
    if [[ "$_SHELLM_DOCKER_MODE" -eq 1 ]]; then
        docker exec "$container" bash -c 'wc -l < /work/heartbeat 2>/dev/null || echo 0'
    else
        wc -l < "$WORK/heartbeat" 2>/dev/null || echo 0
    fi
}
run_case() {
    local label="$1" workspace="$WORK" i=0 before after elapsed start rc=0
    [[ "$_SHELLM_DOCKER_MODE" -eq 0 ]] || workspace=/work
    execute_code "$workspace" "$code" PATH="$PATH" PRODUCER_BASH="$producer_bash" > "$WORK/output" 2>&1 &
    exec_pid=$!
    while [[ "$i" -lt 100 ]]; do
        if [[ "$_SHELLM_DOCKER_MODE" -eq 1 ]]; then
            docker exec "$container" test -f /work/ready && break
        elif [[ -f "$WORK/ready" ]]; then
            break
        fi
        sleep 0.1
        i=$((i+1))
    done
    if [[ "$i" -eq 100 ]]; then bad "$label producer becomes ready"; return; fi
    start=$SECONDS
    kill "$exec_pid"
    wait "$exec_pid" || rc=$?
    elapsed=$((SECONDS-start))
    exec_pid=""
    before=$(read_probe)
    sleep 0.3
    after=$(read_probe)
    if [[ "$rc" -eq 143 && "$elapsed" -lt 5 && "$before" -gt 0 && "$after" -eq "$before" ]]; then
        ok "$label cancellation stops a TERM-ignoring descendant before returning"
    else
        bad "$label cancellation stops a TERM-ignoring descendant before returning (rc=$rc, ${elapsed}s, $before -> $after)"
    fi

    # A normal block still preserves its exit code and forwarded environment.
    execute_code "$workspace" 'printf "%s\n" "$EXEC_PROBE"; exit 7' EXEC_PROBE=forwarded > "$WORK/normal" 2>&1 &
    exec_pid=$!
    rc=0; wait "$exec_pid" || rc=$?
    exec_pid=""
    if [[ "$rc" -eq 7 ]] && grep -qx forwarded "$WORK/normal"; then
        ok "$label preserves exit status and environment on normal completion"
    else
        bad "$label preserves exit status and environment on normal completion"
    fi
}
_SHELLM_DOCKER_MODE=0
run_case local
if [[ -n "${SHELLM_TEST_DOCKER_IMAGE:-}" ]]; then
    container=$(docker run -d --rm --init --network none --user 12345:12345 "$SHELLM_TEST_DOCKER_IMAGE" sleep 120) || exit 1
    docker exec --user 0:0 "$container" bash -c 'mkdir /work; chmod 777 /work' || exit 1
    # Model the sandbox's passwordless sudo without installing packages or
    # enabling network: this disposable container alone gets a setuid Bash.
    docker exec --user 0:0 "$container" bash -c 'cp /bin/bash /work/rootbash; chmod 4755 /work/rootbash' || exit 1
    producer_bash=/work/rootbash
    docker exec -d "$container" bash -c 'echo $$ > /work/sibling.pid; exec sleep 120'
    _SHELLM_CONTAINER="$container"
    _SHELLM_DOCKER_MODE=1
    run_case docker
    if [[ "$(docker exec "$container" cat /work/producer.uid)" -eq 0 ]]; then
        ok "Docker cancellation also stops a root-owned descendant"
    else
        bad "Docker fixture creates a root-owned descendant"
    fi
    if docker exec "$container" bash -c 'read -r pid < /work/sibling.pid; kill -0 "$pid"'; then
        ok "cancelling one Docker execution leaves an unrelated execution alive"
    else
        bad "cancelling one Docker execution leaves an unrelated execution alive"
    fi
    remaining=$(docker exec "$container" bash -c 'shopt -s nullglob; paths=(/tmp/shellm-exec.*); echo "${#paths[@]}"')
    if [[ "$remaining" -eq 0 ]]; then ok "Docker execution control directories are removed"; else bad "Docker execution control directories are removed"; fi
fi
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
