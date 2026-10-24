#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
MODULE_CACHE="${TMPDIR:-/private/tmp}/notescopilot-swift-module-cache"
mkdir -p "$MODULE_CACHE"
SOURCES=()
for source in src/*.swift; do
  if [ "$source" != src/main.swift ]; then SOURCES+=("$source"); fi
done
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos13 -module-cache-path "$MODULE_CACHE" \
  -o "$OUT/render-ui" tools/render_ui.swift tools/AppDelegateStub.swift "${SOURCES[@]}"
"$OUT/render-ui" "${1:-build/ui-smoke}"
