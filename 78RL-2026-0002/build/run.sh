#!/bin/bash
# Extracts the crafted volume pair with 7-Zip 26.02 and then with 26.03.
# The command is the ordinary one a user would run on an untrusted archive.
# Both volumes must sit in the same directory: 7-Zip derives the second
# volume's name from the first.
set -u
export ASAN_OPTIONS=detect_leaks=0
mkdir -p /poc/output

WORK=/tmp/work
mkdir -p "$WORK"
if [ -f /poc/poc.swm ] && [ -f /poc/poc2.swm ]; then
  cp /poc/poc.swm /poc/poc2.swm "$WORK/"
else
  echo "regenerating the crafted volumes ..."
  /poc/make-poc-image.sh "$WORK"
fi

for BUILD in vulnerable fixed; do
  case "$BUILD" in vulnerable) VER=26.02 ;; *) VER=26.03 ;; esac
  echo "=============== 7-Zip $VER ($BUILD) ==============="
  rm -rf "$WORK/out"
  ( cd "$WORK" && "/usr/local/bin/7zz-$BUILD" x poc.swm -oout -y ) \
      > "/poc/output/$BUILD-$VER.txt" 2>&1
  rc=$?
  if grep -q 'ERROR: AddressSanitizer' "/poc/output/$BUILD-$VER.txt"; then
    echo "  AddressSanitizer reports a heap over-read (exit $rc)"
    grep -m1 -A3 'ERROR: AddressSanitizer' "/poc/output/$BUILD-$VER.txt" | sed 's/^/    /'
  else
    echo "  no memory error (exit $rc)"
    grep -m1 -iE 'headers error|unavailable|error' "/poc/output/$BUILD-$VER.txt" | sed 's/^/    /' || true
  fi
  echo
done
