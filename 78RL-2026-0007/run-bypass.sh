#!/usr/bin/env bash
# Exercise the real FFmpeg CLI on both releases, then test the 9.0.2 guard.
# Prerequisite: docker build -t ffmpeg-firequalizer-poc:0007 build/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-ffmpeg-firequalizer-poc:0007}"
mkdir -p "$HERE/output"
docker image inspect "$IMAGE" >/dev/null

run_case() {
    local version="$1" label="$2" delay="$3" output
    output="$HERE/output/${label}-${version}.txt"
    echo "=============== FFmpeg ${version} (${label}; delay=${delay}) ==============="
    docker run --rm \
        --network=none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --pids-limit=128 \
        --memory=1g \
        -e ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:print_stacktrace=1 \
        -e UBSAN_OPTIONS=halt_on_error=0:print_stacktrace=1 \
        "$IMAGE" bash -c '
            set +e
            timeout 30s "/opt/ffmpeg-$1" -hide_banner -nostdin -loglevel error -y \
                -f lavfi -i sine=frequency=440:sample_rate=44100:duration=0.1 \
                -af "firequalizer=delay=$2" -f null -
            status=$?
            echo "[runner] exit status: $status"
            exit 0
        ' bash "$version" "$delay" 2>&1 \
        | sed 's/[[:blank:]]*$//' | tee "$output"
    echo
}

run_case 9.0.1 vulnerable 12180
run_case 9.0.2 post-fix 12180
run_case 9.0.2 guard-control 1e10

for label in vulnerable-9.0.1 post-fix-9.0.2; do
    log="$HERE/output/${label}.txt"
    grep -q 'runtime error: signed integer overflow:' "$log"
    grep -q 'ERROR: AddressSanitizer: heap-buffer-overflow' "$log"
    grep -q 'WRITE of size 4' "$log"
    grep -q 'in generate_kernel' "$log"
    grep -q '4 bytes before 65544-byte region' "$log"
    if grep -q '\[runner\] exit status: 124$' "$log"; then
        echo "[runner] ${label} timed out" >&2
        exit 1
    fi
    if grep -q '\[runner\] exit status: 0$' "$log"; then
        echo "[runner] ${label} unexpectedly exited successfully" >&2
        exit 1
    fi
done

control="$HERE/output/guard-control-9.0.2.txt"
grep -q 'too large or non-finite delay' "$control"
if grep -q '\[runner\] exit status: 0$\|\[runner\] exit status: 124$' "$control"; then
    echo '[runner] guard control did not reject the input promptly' >&2
    exit 1
fi
if grep -q 'AddressSanitizer\|runtime error:' "$control"; then
    echo '[runner] guard control unexpectedly produced a sanitizer finding' >&2
    exit 1
fi

echo '[runner] incomplete-fix and guard-control checks passed'
