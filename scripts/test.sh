#!/usr/bin/env bash
# Runs unit tests. With only the Command Line Tools installed (no Xcode) SwiftPM cannot find the
# Testing framework by itself, so point it at the CLT copy.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
if [[ "$DEV" == "/Library/Developer/CommandLineTools" ]]; then
  F="$DEV/Library/Developer"
  exec swift test -Xswiftc -F"$F/Frameworks" -Xlinker -F"$F/Frameworks" \
    -Xlinker -rpath -Xlinker "$F/Frameworks" -Xlinker -rpath -Xlinker "$F/usr/lib" "$@"
fi
exec swift test "$@"
