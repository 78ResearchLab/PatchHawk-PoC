#!/bin/bash
# Reads poc.pam with cv2.imread(..., IMREAD_GRAYSCALE) on OpenCV 4.13.0 and
# 4.14.0, then again under AddressSanitizer to name the defect.
#
# Everything goes through the public cv2 module. Nothing calls an internal
# OpenCV function and no private header is used.
# Prerequisite: docker build -t opencv-poc:0004 build/
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/output"

READ_PY='
import cv2, sys
print("OpenCV", cv2.__version__)
m = cv2.imread("/poc/poc.pam", cv2.IMREAD_GRAYSCALE)
print("imread returned:", None if m is None else m.shape)
print("returned normally")
'

for V in 4.13.0 4.14.0; do
  case "$V" in 4.13.0) LABEL=vulnerable ;; *) LABEL=fixed ;; esac
  echo "=============== OpenCV $V ($LABEL), default build ==============="
  docker run --rm -v "$HERE:/poc" opencv-poc:0004 bash -lc "
      D=\$(dirname \$(find /opt/ocv-$V -name 'cv2*.so' | head -1))
      PYTHONPATH=\$D LD_LIBRARY_PATH=/opt/ocv-$V/lib python3 -u -c '$READ_PY'
      echo \"exit status: \$?\"" 2>&1 | tee "$HERE/output/$LABEL-$V.txt"
  echo
done

echo "=============== OpenCV 4.13.0, AddressSanitizer build ==============="
docker run --rm -v "$HERE:/poc" \
  -e ASAN_OPTIONS=detect_leaks=0:abort_on_error=0:symbolize=1 opencv-poc:0004 bash -lc "
    D=\$(dirname \$(find /opt/san-4.13.0 -name 'cv2*.so' | head -1))
    LD_PRELOAD=\$(gcc -print-file-name=libasan.so) PYTHONPATH=\$D \
      LD_LIBRARY_PATH=/opt/san-4.13.0/lib python3 -u -c '$READ_PY'" \
  2>&1 | tee "$HERE/output/sanitizer-4.13.0.txt"
