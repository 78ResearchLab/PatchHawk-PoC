#!/bin/bash
# Loads poc.onnx two ways on OpenCV 4.13.0 and 4.14.0:
#   1. opencv_model_diagnostics -m poc.onnx  -- a CLI OpenCV ships by default
#   2. cv2.dnn.readNetFromONNX(...)          -- the public Python API
# then again under AddressSanitizer to name the defect.
# Prerequisite: docker build -t opencv-poc:0005 build/
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/output"

LOAD_PY='
import cv2
print("OpenCV", cv2.__version__)
try:
    net = cv2.dnn.readNetFromONNX("/poc/poc.onnx")
    print("model LOADED, layers:", len(net.getLayerNames()))
except cv2.error as e:
    print("rejected with cv2.error:")
    for line in str(e).strip().splitlines():
        print("  " + line)
'

for V in 4.13.0 4.14.0; do
  case "$V" in 4.13.0) LABEL=vulnerable ;; *) LABEL=fixed ;; esac
  echo "=============== OpenCV $V ($LABEL), default build ==============="
  docker run --rm -v "$HERE:/poc" opencv-poc:0005 bash -lc "
      echo '--- shipped CLI: opencv_model_diagnostics -m poc.onnx ---'
      LD_LIBRARY_PATH=/opt/ocv-$V/lib /opt/ocv-$V/bin/opencv_model_diagnostics -m=/poc/poc.onnx
      echo \"exit status: \$?\"
      echo
      echo '--- public Python API: cv2.dnn.readNetFromONNX ---'
      D=\$(dirname \$(find /opt/ocv-$V -name 'cv2*.so' | head -1))
      PYTHONPATH=\$D LD_LIBRARY_PATH=/opt/ocv-$V/lib python3 -u -c '$LOAD_PY'
      echo \"exit status: \$?\"" 2>&1 | tee "$HERE/output/$LABEL-$V.txt"
  echo
done

echo "=============== OpenCV 4.13.0, AddressSanitizer build ==============="
docker run --rm -v "$HERE:/poc" \
  -e ASAN_OPTIONS=detect_leaks=0:abort_on_error=0:symbolize=1 opencv-poc:0005 bash -lc "
    D=\$(dirname \$(find /opt/san-4.13.0 -name 'cv2*.so' | head -1))
    LD_PRELOAD=\$(gcc -print-file-name=libasan.so) PYTHONPATH=\$D \
      LD_LIBRARY_PATH=/opt/san-4.13.0/lib python3 -u -c '$LOAD_PY'" \
  2>&1 | tee "$HERE/output/sanitizer-4.13.0.txt"
