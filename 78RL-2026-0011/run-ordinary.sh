#!/usr/bin/env bash
# Ordinary, unsanitized gcc builds - what a distribution package is. The
# 1.6.4 build writes past the image buffer and glibc's heap checker aborts
# the process at the subsequent free() during pdfioFileClose(); the 1.6.5
# build imports cleanly.
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

run_plain() {  # run_plain <binary> <log> <expect: abort|clean>
  local bin=$1 log=$2 expect=$3
  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-pdfio-png16-alpha:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated >/dev/null
      cmp /tmp/generated/poc.png /case/input/poc.png
      printf "[runner] generator_match=passed\n"
      exec timeout 20s /usr/local/bin/'"$bin"' /case/input/poc.png /tmp/out.pdf
    ' > "$log" 2>&1
  local actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"

  if [[ "$expect" == abort ]]; then
    # 134 = 128 + SIGABRT from glibc's malloc consistency check
    if [[ "$actual" -ne 134 ]] || \
       ! rg -q 'generator_match=passed' "$log" || \
       ! rg -q 'double free or corruption' "$log"; then
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'ordinary %s: unexpected result (exit %s)\n' "$bin" "$actual" >&2
      exit 1
    fi
  else
    if [[ "$actual" -ne 0 ]] || \
       ! rg -q 'generator_match=passed' "$log" || \
       ! rg -q 'image obj = 0x' "$log"; then
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'ordinary %s: unexpected result (exit %s)\n' "$bin" "$actual" >&2
      exit 1
    fi
  fi
  printf '[runner] assertion=passed\n' >> "$log"
}

run_plain import-164-plain "$case_dir/output/ordinary-1.6.4.txt" abort
run_plain import-165-plain "$case_dir/output/ordinary-1.6.5.txt" clean
