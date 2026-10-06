#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

for version in 0.11.1 0.11.2; do
  log="$case_dir/output/original-$version.txt"
  expected=139
  # Exit 139 is the pre-fix signal assertion; timeout's wording can vary.
  marker='JPEG XL decoder v0.11.1'
  if [[ "$version" == 0.11.2 ]]; then
    expected=1
    marker='Failed to create image frame'
  fi

  set +e
  docker run --rm --platform linux/386 --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 512m --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" "patchhawk-libjxl-packed:$version" \
    sh -ec '
      /poc/make-poc /tmp/regenerated.jxl 32768 10923 0 0
      cmp /tmp/regenerated.jxl /case/input/poc.jxl
      printf "[runner] generator_match=passed\n"
      exec timeout 20s /build/tools/djxl /case/input/poc.jxl \
        --disable_output --num_threads=0 -v
    ' > "$log" 2>&1
  actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"
  if [[ "$actual" -ne "$expected" ]] || \
     ! rg -q "JPEG XL decoder v$version" "$log" || \
     ! rg -q 'generator_match=passed' "$log" || \
     ! rg -q "$marker" "$log"; then
    printf '[runner] assertion=failed\n' >> "$log"
    printf 'original %s: unexpected result (exit %s)\n' "$version" "$actual" >&2
    exit 1
  fi
  printf '[runner] assertion=passed\n' >> "$log"
done
