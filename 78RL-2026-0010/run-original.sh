#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

for version in 26.04 26.05; do
  log="$case_dir/output/original-$version.txt"
  if [[ "$version" == 26.04 ]]; then bin=7zz-vulnerable-asan; else bin=7zz-fixed-asan; fi

  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-7zip-ntfs-volume-info:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated
      cmp /tmp/generated/poc.ntfs /case/input/poc.ntfs
      printf "[runner] generator_match=passed\n"
      # The listing aborts under ASan before stdout is flushed, so capture
      # the release banner first; it identifies the exact release in the log.
      /usr/local/bin/'"$bin"' 2>&1 | grep -m1 "7-Zip (z)"
      export ASAN_OPTIONS=detect_leaks=0
      exec timeout 20s /usr/local/bin/'"$bin"' l /case/input/poc.ntfs
    ' > "$log" 2>&1
  actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"
  if [[ "$version" == 26.04 ]]; then
    if [[ "$actual" -ne 1 ]] || \
       ! rg -q '7-Zip \(z\) 26\.04' "$log" || \
       ! rg -q 'generator_match=passed' "$log" || \
       ! rg -q 'ERROR: AddressSanitizer: heap-buffer-overflow' "$log" || \
       ! rg -q 'READ of size 1' "$log" || \
       ! rg -q 'CMftRec::ParseRec' "$log" || \
       ! rg -q 'NtfsHandler\.cpp:1463' "$log" || \
       ! rg -q 'is located 0 bytes after 8-byte region' "$log"; then
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'original %s: unexpected result (exit %s)\n' "$version" "$actual" >&2
      exit 1
    fi
  else
    if [[ "$actual" -ne 0 ]] || \
       ! rg -q '7-Zip \(z\) 26\.05' "$log" || \
       ! rg -q 'generator_match=passed' "$log" || \
       rg -q 'AddressSanitizer' "$log" || \
       ! rg -q 'Label = PoC' "$log" || \
       ! rg -q 'File System = NTFS$' "$log"; then
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'original %s: unexpected result (exit %s)\n' "$version" "$actual" >&2
      exit 1
    fi
  fi
  printf '[runner] assertion=passed\n' >> "$log"
done