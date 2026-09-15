#!/bin/bash
# Extracts the crafted cabinet pair with 7-Zip 26.02 and then with 26.03.
# Extraction is required: the defect sits in the folder-decompression loop, so
# listing the archive does not reach it. Both cabinets must sit in the same
# directory; 7-Zip follows the next-cabinet name stored inside the first.
set -u
export ASAN_OPTIONS=detect_leaks=0
mkdir -p /poc/output

WORK=/tmp/work
mkdir -p "$WORK"
if [ -f /poc/poc.cab ] && [ -f /poc/poc2.cab ]; then
  cp /poc/poc.cab /poc/poc2.cab "$WORK/"
else
  echo "regenerating the crafted cabinets ..."
  /poc/make-poc-image.sh "$WORK"
fi

for BUILD in vulnerable fixed; do
  case "$BUILD" in vulnerable) VER=26.02 ;; *) VER=26.03 ;; esac
  echo "=============== 7-Zip $VER ($BUILD) ==============="
  rm -rf "$WORK/out"
  ( cd "$WORK" && "/usr/local/bin/7zz-$BUILD" x poc.cab -oout -y ) \
      > "/poc/output/$BUILD-$VER.txt" 2>&1
  rc=$?
  if grep -q 'ERROR: AddressSanitizer' "/poc/output/$BUILD-$VER.txt"; then
    echo "  AddressSanitizer reports a null-page dereference (exit $rc)"
    grep -m1 -A3 'ERROR: AddressSanitizer' "/poc/output/$BUILD-$VER.txt" | sed 's/^/    /'
  else
    echo "  no memory error (exit $rc)"
    grep -m1 -iE 'data error|error' "/poc/output/$BUILD-$VER.txt" | sed 's/^/    /' || true
  fi
  echo
done
