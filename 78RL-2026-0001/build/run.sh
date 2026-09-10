#!/bin/bash
# Lists the crafted disk image with 7-Zip 26.01 and then with 26.02.
# The command is the ordinary one a user would run on an untrusted archive.
set -u
export ASAN_OPTIONS=detect_leaks=0
mkdir -p /poc/output

IMAGE=/poc/poc.ext
if [ ! -f "$IMAGE" ]; then
  echo "regenerating the crafted image ..."
  ( cd /tmp && /poc/make-poc-image.sh /tmp/poc.ext ) && IMAGE=/tmp/poc.ext
fi

for BUILD in vulnerable fixed; do
  case "$BUILD" in vulnerable) VER=26.01 ;; *) VER=26.02 ;; esac
  echo "=============== 7-Zip $VER ($BUILD) ==============="
  "/usr/local/bin/7zz-$BUILD" l "$IMAGE" > "/poc/output/$BUILD-$VER.txt" 2>&1
  rc=$?
  if grep -q 'ERROR: AddressSanitizer' "/poc/output/$BUILD-$VER.txt"; then
    echo "  AddressSanitizer reports a heap over-read (exit $rc)"
    grep -m1 -A3 'ERROR: AddressSanitizer' "/poc/output/$BUILD-$VER.txt" | sed 's/^/    /'
  else
    echo "  no memory error (exit $rc)"
    grep -m1 -iE 'headers error|error' "/poc/output/$BUILD-$VER.txt" | sed 's/^/    /' || true
  fi
  echo
done
