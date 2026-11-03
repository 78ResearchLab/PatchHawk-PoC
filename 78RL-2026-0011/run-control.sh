#!/usr/bin/env bash
# Negative control: the same 64x8 RGBA image at bit depth 8, where the two
# line-size expressions are equal, must import cleanly on BOTH releases.
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

for pair in 164-vuln 165-fix; do
  log="$case_dir/output/control-1.6.$([[ $pair == 164* ]] && echo 4 || echo 5)-asan.txt"
  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-pdfio-png16-alpha:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated >/dev/null
      cmp /tmp/generated/control.png /case/input/control.png
      printf "[runner] generator_match=passed\n"
      export ASAN_OPTIONS=abort_on_error=1:detect_leaks=0
      exec timeout 20s /usr/local/bin/import-'"$pair"'-asan /case/input/control.png /tmp/out.pdf
    ' > "$log" 2>&1
  actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"
  if [[ "$actual" -ne 0 ]] || \
     ! rg -q 'generator_match=passed' "$log" || \
     rg -q 'AddressSanitizer' "$log" || \
     ! rg -q 'image obj = 0x' "$log"; then
    printf '[runner] assertion=failed\n' >> "$log"
    printf 'control %s: unexpected result (exit %s)\n' "$pair" "$actual" >&2
    exit 1
  fi
  printf '[runner] assertion=passed\n' >> "$log"
done
