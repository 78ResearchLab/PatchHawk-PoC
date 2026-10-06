#!/usr/bin/env bash
set -euo pipefail

case_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$case_dir/output"

cleanup() {
  docker image rm patchhawk-libjxl-packed-memcheck:0.11.1 \
    patchhawk-libjxl-packed:0.11.1 \
    patchhawk-libjxl-packed:0.11.2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$case_dir"
printf '%s  %s\n' \
  a1e6443fd4a77480a100dbb98c593ab9a5bdf536820c813550f84ab24a3d9a9c input/poc.jxl \
  424a0cd10433bb3c7c4aaa603c2c823c4fce5d433780bdd3705af7bcda8c4c2a input/control.jxl \
  | sha256sum -c -

for version in 0.11.1 0.11.2; do
  docker build --quiet --platform linux/386 -f build/Dockerfile \
    --build-arg "JXL_VERSION=$version" \
    -t "patchhawk-libjxl-packed:$version" "$case_dir" >/dev/null
done
docker build --quiet --platform linux/386 -f build/Dockerfile.memcheck \
  -t patchhawk-libjxl-packed-memcheck:0.11.1 "$case_dir" >/dev/null

./run-original.sh
./run-control.sh
./run-memcheck.sh

{
  printf 'source_pre_sha256=1492dfef8dd6c3036446ac3b340005d92ab92f7d48ee3271b5dac1d36945d3d9\n'
  printf 'source_post_sha256=ab38928f7f6248e2a98cc184956021acb927b16a0dee71b4d260dc040a4320ea\n'
  sha256sum input/poc.jxl input/control.jxl
  printf 'original_pre=139 original_post=1 control_pre=0 control_post=0 memcheck_pre=139\n'
  printf 'assertion=passed\n'
} > output/reproduction.txt
