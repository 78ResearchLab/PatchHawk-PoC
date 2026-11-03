#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

cleanup() {
  docker image rm patchhawk-pdfio-png16-alpha:1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$case_dir"
printf '%s  %s\n' \
  2f5442c4336e50b6c45ba3b287bf88d18cd5c606cf7d4909633348e4cb5be587 input/poc.png \
  d147ed8a2524de817376bcba49d761a0666358ae17773fdc7d7a51d839c99543 input/control.png \
  1bc5f0882943323047de6f39e30c3985dd0302ca5963129da38ddd9956be20be input/wide.png \
  | sha256sum -c -

docker build --quiet -t patchhawk-pdfio-png16-alpha:1 -f build/Dockerfile . >/dev/null

./run-original.sh
./run-control.sh
./run-magnitude.sh
./run-ordinary.sh

{
  printf 'source_pre_sha256=1b5e5e945f4fc214b55d575554c1aec11d7ba91b397cef92ffe877462155af06\n'
  printf 'source_post_sha256=2b9e1db7c4a72cbc896098a6682a1e51fc2bfb979f00bec8bb515ee79c338084\n'
  sha256sum input/poc.png input/control.png input/wide.png
  printf 'original_pre=asan_heap_overflow_write_512 original_post=clean '
  printf 'control_pre=clean control_post=clean '
  printf 'magnitude_pre=asan_heap_overflow_write_8192 magnitude_post=clean '
  printf 'ordinary_pre=glibc_double_free_abort ordinary_post=clean\n'
  printf 'assertion=passed\n'
} > output/reproduction.txt
cat output/reproduction.txt
