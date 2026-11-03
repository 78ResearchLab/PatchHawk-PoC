#!/usr/bin/env bash
# Attacker-chosen magnitude: the same defect at width 1024. The per-row
# shortfall is `width` bytes, so the sanitizer reports an 8192-byte write
# past a 57344-byte region (8 rows x the 1.6.4 line size 7168). pdfio caps
# width at png_set_user_limits(pp, 16384, 16384), i.e. up to 16384 bytes per
# row past the allocation.
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

expect() {  # expect <log> <crash|clean>
  local log=$1 want=$2 actual ok=ok
  actual=$(sed -n 's/^\[runner\] target_exit_status=//p' "$log")
  if [[ "$want" == crash ]]; then
    [[ "$actual" -ne 0 ]] \
      && rg -q 'generator_match=passed' "$log" \
      && rg -q 'ERROR: AddressSanitizer: heap-buffer-overflow' "$log" \
      && rg -q 'WRITE of size 8192' "$log" \
      && rg -q 'is located 0 bytes after 57344-byte region' "$log" || ok=fail
  else
    [[ "$actual" -eq 0 ]] \
      && rg -q 'generator_match=passed' "$log" \
      && ! rg -q 'AddressSanitizer' "$log" \
      && rg -q 'image obj = 0x' "$log" || ok=fail
  fi
  if [[ "$ok" == fail ]]; then
    printf '[runner] assertion=failed\n' >> "$log"
    printf 'magnitude %s: unexpected result\n' "$log" >&2
    exit 1
  fi
  printf '[runner] assertion=passed\n' >> "$log"
}

for pair in 164-vuln 165-fix; do
  log="$case_dir/output/magnitude-1.6.$([[ $pair == 164* ]] && echo 4 || echo 5).txt"
  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-pdfio-png16-alpha:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated >/dev/null
      cmp /tmp/generated/wide.png /case/input/wide.png
      printf "[runner] generator_match=passed\n"
      export ASAN_OPTIONS=abort_on_error=1:detect_leaks=0
      exec timeout 20s /usr/local/bin/import-'"$pair"'-asan /case/input/wide.png /tmp/out.pdf
    ' > "$log" 2>&1
  printf '[runner] target_exit_status=%s\n' "$?" >> "$log"
  set -e
  expect "$log" "$([[ $pair == 164* ]] && echo crash || echo clean)"
done
