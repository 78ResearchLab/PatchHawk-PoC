#!/usr/bin/env bash
# Run both independent FFmpeg firequalizer reproductions.
# Prerequisite: docker build -t ffmpeg-firequalizer-poc:0007 build/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/run-original.sh"
"$HERE/run-bypass.sh"
