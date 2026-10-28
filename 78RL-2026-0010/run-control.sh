#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

for version in 26.04 26.05; do
  log="$case_dir/output/control-$version.txt"
  if [[ "$version" == 26.04 ]]; then bin=7zz-vulnerable-asan; else bin=7zz-fixed-asan; fi

  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-7zip-ntfs-volume-info:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated
      cmp /tmp/generated/control.ntfs /case/input/control.ntfs
      printf "[runner] generator_match=passed\n"
      export ASAN_OPTIONS=detect_leaks=0
      exec timeout 20s /usr/local/bin/'"$bin"' l /case/input/control.ntfs
    ' > "$log" 2>&1
  actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"
  if [[ "$actual" -ne 0 ]] || \
     ! rg -q "7-Zip \\(z\\) $version" "$log" || \
     ! rg -q 'generator_match=passed' "$log" || \
     rg -q 'AddressSanitizer' "$log" || \
     ! rg -q 'File System = NTFS 3\.1$' "$log" || \
     ! rg -q 'Label = PoC' "$log"; then
    printf '[runner] assertion=failed\n' >> "$log"
    printf 'control %s: unexpected result (exit %s)\n' "$version" "$actual" >&2
    exit 1
  fi
  printf '[runner] assertion=passed\n' >> "$log"
done