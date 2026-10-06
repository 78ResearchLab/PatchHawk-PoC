#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"
log="$case_dir/output/memcheck-0.11.1.txt"

set +e
docker run --rm --platform linux/386 --network none --read-only \
  --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
  --ulimit core=0 --user "$(id -u):$(id -g)" \
  -v "$case_dir:/case:ro" patchhawk-libjxl-packed-memcheck:0.11.1 \
  sh -ec '
    /poc/make-poc /tmp/regenerated.jxl 32768 10923 0 0
    cmp /tmp/regenerated.jxl /case/input/poc.jxl
    printf "[runner] generator_match=passed\n"
    exec timeout 30s valgrind --tool=memcheck --error-exitcode=99 \
      --num-callers=24 /build/tools/djxl /case/input/poc.jxl \
      --disable_output --num_threads=0 -v
  ' > "$log" 2>&1
actual=$?
set -e
printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"
if [[ "$actual" -ne 139 ]] || \
   ! rg -q 'JPEG XL decoder v0.11.1' "$log" || \
   ! rg -q 'generator_match=passed' "$log" || \
   ! rg -q 'Invalid write of size 4' "$log" || \
   ! rg -q 'jxl.cc:506' "$log"; then
  printf '[runner] assertion=failed\n' >> "$log"
  printf 'memcheck: unexpected result (exit %s)\n' "$actual" >&2
  exit 1
fi
printf '[runner] assertion=passed\n' >> "$log"
