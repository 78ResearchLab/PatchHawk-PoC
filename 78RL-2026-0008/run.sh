#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-ffmpeg-ogg-poc:0008}"
mkdir -p "$HERE/output"
docker image inspect "$IMAGE" >/dev/null
docker run --rm --network=none --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=128 \
    --cpus=4 --memory=14g --memory-swap=14g --read-only \
    --user "$(id -u):$(id -g)" \
    --tmpfs /data:rw,nosuid,nodev,mode=1777,size=5g \
    -v "$HERE/output:/output" "$IMAGE" bash /poc/run-in-container.sh
