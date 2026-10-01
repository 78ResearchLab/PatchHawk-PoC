#!/usr/bin/env bash
# Compare the original firequalizer delay overflow with the 9.0.2 guard.
# Prerequisite: docker build -t ffmpeg-firequalizer-poc:0007 build/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-ffmpeg-firequalizer-poc:0007}"
mkdir -p "$HERE/output"
docker image inspect "$IMAGE" >/dev/null

run_version() {
    local version="$1" label="$2" output
    output="$HERE/output/original-${label}-${version}.txt"
    echo "=============== FFmpeg ${version} (${label}; delay=30000) ==============="
    docker run --rm \
        --network=none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --pids-limit=128 \
        --memory=1g \
        -e ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:print_stacktrace=1 \
        -e UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$IMAGE" bash -c '
            set +e
            timeout 30s "/opt/ffmpeg-$1" -hide_banner -nostdin -loglevel error -y \
                -f lavfi -i sine=frequency=440:sample_rate=44100:duration=0.1 \
                -af firequalizer=delay=30000 -f null -
            status=$?
            echo "[runner] exit status: $status"
            exit 0
        ' bash "$version" 2>&1 \
        | sed 's/[[:blank:]]*$//' | tee "$output"
    echo
}

run_version 9.0.1 vulnerable
run_version 9.0.2 guarded

pre="$HERE/output/original-vulnerable-9.0.1.txt"
post="$HERE/output/original-guarded-9.0.2.txt"
grep -q 'runtime error: signed integer overflow: 1323000000 \* 2' "$pre"
grep -q 'in config_input' "$pre"
grep -q '\[runner\] exit status: 1$' "$pre"
grep -q 'too large or non-finite delay' "$post"
grep -q '\[runner\] exit status: 234$' "$post"
if grep -q 'AddressSanitizer' "$pre"; then
    echo '[runner] unexpected AddressSanitizer finding in 9.0.1' >&2
    exit 1
fi
if grep -q 'AddressSanitizer\|runtime error:' "$post"; then
    echo '[runner] sanitizer finding in guarded 9.0.2 run' >&2
    exit 1
fi
echo '[runner] original-overflow differential checks passed'
