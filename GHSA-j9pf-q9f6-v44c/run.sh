#!/usr/bin/env bash
# Build first: docker build -t squid-auth-poc:7.6-7.7 build/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-squid-auth-poc:7.6-7.7}"
SCRATCH="$(mktemp -d)"
NETWORK="squid-auth-poc-${BASHPID}-${RANDOM}"
PEER="${NETWORK}-peer"
PROXY=""

cleanup() {
    if [[ -n "$PROXY" ]]; then docker rm -f "$PROXY" >/dev/null 2>&1 || true; fi
    docker rm -f "$PEER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

wait_for_port() {
    local container="$1" port="$2"
    for ((i=0; i<60; i++)); do
        if docker exec "$container" python3 -c \
            "import socket; s=socket.create_connection(('127.0.0.1', ${port}), 1); s.close()" \
            >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    docker logs "$container" >&2 || true
    echo "[runner] ${container}:${port} did not become ready" >&2
    return 1
}

docker image inspect "$IMAGE" >/dev/null
docker network create --internal "$NETWORK" >/dev/null
docker run -d --name "$PEER" --network "$NETWORK" --network-alias peerstub \
    "$IMAGE" python3 /poc/peer.py >/dev/null
wait_for_port "$PEER" 8080
mkdir -p "$HERE/output"

run_version() {
    local version="$1" label="$2" status asan_dir logs output
    output="$HERE/output/${label}-${version}.txt"
    PROXY="${NETWORK}-squid-${version//./-}"
    sed "s|@PREFIX@|/opt/squid-${version}|g" \
        "$HERE/build/squid.conf.in" > "$SCRATCH/squid.conf"

    docker run -d --name "$PROXY" --network "$NETWORK" --network-alias squid \
        -v "$SCRATCH/squid.conf:/poc/squid.conf:ro" \
        -e "ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=0:print_stacktrace=1:symbolize=1:log_path=/opt/squid-${version}/var/logs/asan" \
        "$IMAGE" "/opt/squid-${version}/sbin/squid" -N -d1 -f /poc/squid.conf >/dev/null
    wait_for_port "$PROXY" 3128

    echo "[runner] Squid ${version} (${label})"
    for ((attempt=0; attempt<10; attempt++)); do
        docker run --rm --network "$NETWORK" "$IMAGE" python3 /poc/client.py 100 \
            > "$SCRATCH/baseline-${version}.txt" 2>&1 || true
        if grep -q 'HTTP/1.1 200' "$SCRATCH/baseline-${version}.txt"; then break; fi
        sleep 1
    done
    grep -q 'HTTP/1.1 200' "$SCRATCH/baseline-${version}.txt"
    docker run --rm --network "$NETWORK" "$IMAGE" python3 /poc/client.py 300 \
        > "$SCRATCH/client-${version}.txt" 2>&1 || true
    sleep 2
    status="$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$PROXY")"
    logs="$SCRATCH/logs-${version}"
    mkdir -p "$logs"
    docker cp "$PROXY:/opt/squid-${version}/var/logs/." "$logs/" >/dev/null
    docker logs "$PROXY" > "$SCRATCH/stderr-${version}.txt" 2>&1 || true
    asan_dir="$(find "$logs" -maxdepth 1 -type f -name 'asan.*' -print -quit)"

    {
        echo "Squid ${version} (${label}); synthetic usernames"
        echo '[runner] baseline request'
        cat "$SCRATCH/baseline-${version}.txt"
        echo '[runner] long-username request'
        cat "$SCRATCH/client-${version}.txt"
        echo "[runner] container: $status"
        if [[ -n "$asan_dir" ]]; then
            grep -aE 'ERROR: AddressSanitizer|WRITE of size|in encode_raw|in base64_encode_update|in httpFixupAuthentication|loginbuf.*overflows' "$asan_dir" || true
        fi
        grep -a 'peer login credentials too long' "$logs/cache.log" || true
    } | tee "$output"

    if [[ "$label" == vulnerable ]]; then
        [[ -n "$asan_dir" ]] && [[ "$status" == exited* ]]
        grep -q 'ERROR: AddressSanitizer: stack-buffer-overflow' "$asan_dir"
        grep -q 'WRITE of size 1' "$asan_dir"
        grep -q 'in httpFixupAuthentication' "$asan_dir"
    else
        [[ -z "$asan_dir" ]] && [[ "$status" == running* ]]
        grep -q 'peer login credentials too long' "$logs/cache.log"
        grep -q 'HTTP/1.1 500 Internal Server Error' "$SCRATCH/client-${version}.txt"
    fi
    docker rm -f "$PROXY" >/dev/null
    PROXY=""
}

run_version 7.6 vulnerable
run_version 7.7 fixed
echo '[runner] differential checks passed'
