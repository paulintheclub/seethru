#!/usr/bin/env bash
# Builds build/Seethru.app from the SwiftPM executable.
#   SIGN_IDENTITY   codesign identity (default "-" = ad-hoc). With ad-hoc signing macOS forgets the
#                   Accessibility / Screen Recording grants after every rebuild; use a stable
#                   identity (e.g. "Apple Development: Your Name (TEAMID)") during development.
#   CONFIG          release (default) or debug
#   ARCHS           e.g. "arm64 x86_64" for a universal build (default: this machine)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
ARCH_ARGS=()
for a in ${ARCHS:-}; do ARCH_ARGS+=(--arch "$a"); done

swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/Seethru"

APP="build/Seethru.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Seethru"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime, no sandbox (Accessibility + private APIs cannot be sandboxed).
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"
