#!/bin/bash
# Real AppDelegate lifecycle regression with isolated volatile configuration.
# Does not request permissions, read Notes, register hotkeys, or start watchers.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d "${TMPDIR:-/private/tmp}/notescopilot-launch.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/NotesCopilotLaunchTests.app"
MODULE_CACHE="${TMPDIR:-/private/tmp}/notescopilot-swift-module-cache"
mkdir -p "$APP/Contents/MacOS" "$MODULE_CACHE"
# Swift still parses top-level expressions in inactive conditional blocks in a
# non-main source file. Copy the real delegate while omitting its process entry.
awk '/^\/\/ MARK: - 入口/ { exit } { print }' src/main.swift > "$OUT/AppDelegate.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.notescopilot.launch-tests</string>
  <key>CFBundleExecutable</key><string>NotesCopilotLaunchTests</string>
  <key>CFBundleName</key><string>NotesCopilotLaunchTests</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

SOURCES=()
for source in src/*.swift; do
  if [ "$source" != src/main.swift ]; then SOURCES+=("$source"); fi
done
swiftc -O -parse-as-library -D NC_APP -D NC_APP_TEST -sdk "$SDK" \
  -target arm64-apple-macos13 -module-cache-path "$MODULE_CACHE" \
  -o "$APP/Contents/MacOS/NotesCopilotLaunchTests" \
  "$OUT/AppDelegate.swift" "${SOURCES[@]}" tests/launch-tests/main.swift
"$APP/Contents/MacOS/NotesCopilotLaunchTests"
