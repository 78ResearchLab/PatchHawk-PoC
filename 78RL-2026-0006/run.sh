#!/usr/bin/env bash
# Rebuilds the checked-in DDS and compares OpenImageIO 3.1.15.0 with 3.1.16.0.
# Prerequisite: docker build -t openimageio-poc:0006 build/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-openimageio-poc:0006}"
mkdir -p "$HERE/output"

rebuilt="$(mktemp)"
trap 'rm -f "$rebuilt"' EXIT
python3 "$HERE/make-poc.py" "$rebuilt"
cmp "$HERE/poc.dds" "$rebuilt"
echo "[runner] checked-in poc.dds matches make-poc.py"

run_version() {
    local version="$1"
    local label="$2"
    local output="$HERE/output/${label}-${version}.txt"

    echo "=============== OpenImageIO ${version} (${label}) ==============="
    docker run --rm \
        --network=none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --pids-limit=128 \
        --memory=1g \
        -v "$HERE:/poc:ro" \
        -e ASAN_OPTIONS=detect_leaks=0:print_stacktrace=1:symbolize=1:abort_on_error=0:halt_on_error=1:exitcode=99 \
        "$IMAGE" \
        bash -lc "
            set +e
            export LD_LIBRARY_PATH=/opt/ocio/lib:/opt/oiio-${version}/lib
            /usr/local/bin/oiio-read-${version} /poc/poc.dds
            status=\$?
            echo \"[runner] exit status: \$status\"
            exit 0
        " 2>&1 | tee "$output"
    echo
}

run_version 3.1.15.0 vulnerable
run_version 3.1.16.0 fixed

grep -q "ERROR: AddressSanitizer: stack-buffer-overflow" \
    "$HERE/output/vulnerable-3.1.15.0.txt"
grep -q "WRITE of size 8" "$HERE/output/vulnerable-3.1.15.0.txt"
grep -q "'pixel'.*partially overflows this variable" \
    "$HERE/output/vulnerable-3.1.15.0.txt"
grep -q "\[runner\] exit status: 99" \
    "$HERE/output/vulnerable-3.1.15.0.txt"

grep -q "\[harness\] read_image ok (4 bytes)" \
    "$HERE/output/fixed-3.1.16.0.txt"
grep -q "\[runner\] exit status: 0" "$HERE/output/fixed-3.1.16.0.txt"
if grep -q "AddressSanitizer" "$HERE/output/fixed-3.1.16.0.txt"; then
    echo "fixed build unexpectedly produced an AddressSanitizer diagnostic" >&2
    exit 1
fi

echo "[runner] differential checks passed"
