#!/usr/bin/env bash
# Runs the 16-bit RGBA trigger against the ASan builds of 1.6.4 and 1.6.5.
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

run_one() {  # run_one <binary> <image> <log> <expect_crash: yes|no>
  local bin=$1 image=$2 log=$3 expect=$4
  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-pdfio-png16-alpha:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated >/dev/null
      cmp /tmp/generated/poc.png     /case/input/poc.png
      cmp /tmp/generated/control.png /case/input/control.png
      cmp /tmp/generated/wide.png    /case/input/wide.png
      printf "[runner] generator_match=passed\n"
      export ASAN_OPTIONS=abort_on_error=1:detect_leaks=0
      exec timeout 20s /usr/local/bin/'"$bin"' /case/input/'"$image"' /tmp/out.pdf
    ' > "$log" 2>&1
  local actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"

  if [[ "$expect" == yes ]]; then
    if [[ "$actual" -eq 0 ]] || \
       ! rg -q 'generator_match=passed' "$log" || \
       ! rg -q 'ERROR: AddressSanitizer: heap-buffer-overflow' "$log" || \
       ! rg -q 'WRITE of size 512' "$log" || \
       ! rg -q 'is located 0 bytes after 3584-byte region' "$log" || \
       ! rg -q 'copy_png' "$log" || \
       ! rg -q 'pdfioFileCreateImageObjFromFile' "$log"; then
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'original %s: unexpected result (exit %s)\n' "$bin" "$actual" >&2
      exit 1
    fi
  else
    if [[ "$actual" -ne 0 ]] || \
       ! rg -q 'generator_match=passed' "$log" || \
       rg -q 'AddressSanitizer' "$log" || \
       ! rg -q 'image obj = 0x' "$log"; then
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'original %s: unexpected result (exit %s)\n' "$bin" "$actual" >&2
      exit 1
    fi
  fi
  printf '[runner] assertion=passed\n' >> "$log"
}

run_one import-164-vuln-asan poc.png "$case_dir/output/original-1.6.4-asan.txt" yes
run_one import-165-fix-asan  poc.png "$case_dir/output/original-1.6.5-asan.txt" no
