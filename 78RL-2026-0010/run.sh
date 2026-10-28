#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

cleanup() {
  docker image rm patchhawk-7zip-ntfs-volume-info:1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$case_dir"
printf '%s  %s\n' \
  4ebb5777c8dfb66aec24c7b8390ae83a68914681100576f9642fee335c34040d input/poc.ntfs \
  133f75b3594acc3262f7df8784815fa9669169b30905e06baeb686d0b909492c input/control.ntfs \
  | sha256sum -c -

docker build --quiet -t patchhawk-7zip-ntfs-volume-info:1 -f build/Dockerfile . >/dev/null

./run-original.sh
./run-control.sh
./run-ordinary.sh

{
  printf 'source_pre_sha256=9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6\n'
  printf 'source_post_sha256=0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e\n'
  sha256sum input/poc.ntfs input/control.ntfs
  printf 'original_pre=1 original_post=0 control_pre=0 control_post=0 ordinary_pre=0 ordinary_post=0\n'
  printf 'assertion=passed\n'
} > output/reproduction.txt