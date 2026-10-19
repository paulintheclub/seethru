#!/usr/bin/env bash
# Builds build/Seethru.app from the SwiftPM executable.
#   SIGN_IDENTITY   codesign identity (default "-" = ad-hoc). A plain ad-hoc signature is identified by the hash of
#                   the code, which changes on every build, so macOS forgets the Accessibility / Screen Recording
#                   grants. For ad-hoc builds this script therefore pins the designated requirement to the bundle id,
#                   which keeps grants valid across rebuilds and updates. Use a real identity
#                   (e.g. "Developer ID Application: Your Name (TEAMID)") for releases when you have one.
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
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --timestamp=none --sign - \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"
