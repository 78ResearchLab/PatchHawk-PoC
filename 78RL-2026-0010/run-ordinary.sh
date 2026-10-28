#!/usr/bin/env bash
set -euo pipefail

# Ordinary (unsanitized) builds of both releases: shows what the over-read
# bytes do on a stock binary. 26.04 parses them as the NTFS volume version
# and prints them in the listing; 26.05 prints no version for the short
# payload. The version digits come from heap memory adjacent to the
# attribute buffer, so only their presence is deterministic.
case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

for version in 26.04 26.05; do
  log="$case_dir/output/ordinary-$version.txt"
  if [[ "$version" == 26.04 ]]; then bin=7zz-vulnerable; else bin=7zz-fixed; fi

  set +e
  docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,size=64m --memory 1g --cpus 1 --pids-limit 64 \
    --ulimit core=0 --user "$(id -u):$(id -g)" \
    -v "$case_dir:/case:ro" patchhawk-7zip-ntfs-volume-info:1 \
    sh -ec '
      python3 /poc/make-poc.py /tmp/generated
      cmp /tmp/generated/poc.ntfs /case/input/poc.ntfs
      printf "[runner] generator_match=passed\n"
      exec timeout 20s /usr/local/bin/'"$bin"' l /case/input/poc.ntfs
    ' > "$log" 2>&1
  actual=$?
  set -e
  printf '[runner] target_exit_status=%s\n' "$actual" >> "$log"
  if [[ "$actual" -ne 0 ]] || \
     ! rg -q "7-Zip \\(z\\) $version" "$log" || \
     ! rg -q 'generator_match=passed' "$log" || \
     ! rg -q 'Label = PoC' "$log"; then
    printf '[runner] assertion=failed\n' >> "$log"
    printf 'ordinary %s: unexpected result (exit %s)\n' "$version" "$actual" >&2
    exit 1
  fi
  if [[ "$version" == 26.04 ]]; then
    # The two over-read bytes are printed as the volume version.
    rg -q 'File System = NTFS [0-9]+\.[0-9]+$' "$log" || {
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'ordinary %s: no version-shaped File System line\n' "$version" >&2
      exit 1
    }
  else
    # The fixed release prints no version for the short payload.
    rg -q 'File System = NTFS$' "$log" || {
      printf '[runner] assertion=failed\n' >> "$log"
      printf 'ordinary %s: unexpected File System version line\n' "$version" >&2
      exit 1
    }
  fi
  printf '[runner] assertion=passed\n' >> "$log"
done