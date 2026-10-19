#!/usr/bin/env bash
# Builds the app and packs dist/Seethru-<version>.dmg (drag to Applications) and dist/Seethru-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
"$(dirname "$0")/build.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
rm -rf dist && mkdir -p dist/dmg
cp -R build/Seethru.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "Seethru" -srcfolder dist/dmg -ov -format UDZO "dist/Seethru-$VERSION.dmg"
ditto -c -k --keepParent build/Seethru.app "dist/Seethru-$VERSION.zip"
rm -rf dist/dmg
ls -lh dist
