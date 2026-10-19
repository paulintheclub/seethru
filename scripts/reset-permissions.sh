#!/usr/bin/env bash
# Removes Seethru's Accessibility and Screen Recording entries so macOS asks again from scratch.
# Use it when System Settings shows Seethru as allowed but the app still reports the permission as missing
# (a stale entry left by an older build). Only Seethru's own entries are touched.
set -euo pipefail
ID="io.github.seethru.Seethru"
pkill -x Seethru 2>/dev/null || true
tccutil reset Accessibility "$ID"
tccutil reset ScreenCapture "$ID"
echo "Done. Open Seethru and grant both permissions again."
