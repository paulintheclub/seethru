#!/usr/bin/env bash
# Builds and launches Seethru, replacing a running copy (its quit handler restores every window first).
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x Seethru >/dev/null; then pkill -TERM -x Seethru; sleep 1; fi
"$(dirname "$0")/build.sh"
open build/Seethru.app
