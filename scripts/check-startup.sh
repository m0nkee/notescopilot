#!/bin/bash
# Real AppDelegate lifecycle regression with isolated settings. Optional input-field
# checks run the selection watcher against a separate synthetic host using existing AX permission.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d "${TMPDIR:-/private/tmp}/notescopilot-launch.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/NotesCopilotLaunchTests.app"
MODULE_CACHE="${TMPDIR:-/private/tmp}/notescopilot-swift-module-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
cp -R resources/. "$APP/Contents/Resources/"
# Swift still parses top-level expressions in inactive conditional blocks in a
# non-main source file. Copy the real delegate while omitting its process entry.
awk '/^\/\/ MARK: - 入口/ { exit } { print }' src/main.swift > "$OUT/AppDelegate.swift"
PLIST="$APP/Contents/Info.plist"
cp Info.plist "$PLIST"
plutil -replace CFBundleIdentifier -string local.notescopilot.launch-tests "$PLIST"
plutil -replace CFBundleExecutable -string NotesCopilotLaunchTests "$PLIST"
plutil -replace CFBundleName -string NotesCopilotLaunchTests "$PLIST"
plutil -replace CFBundleDisplayName -string NotesCopilotLaunchTests "$PLIST"
plutil -replace NSServices.0.NSPortName -string NotesCopilotLaunchTests "$PLIST"
plutil -replace NSServices.0.NSMenuItem.default -string 'NotesCopilot Selection Fixture' "$PLIST"

SOURCES=()
for source in src/*.swift; do
  if [ "$source" != src/main.swift ]; then SOURCES+=("$source"); fi
done
swiftc -O -parse-as-library -D NC_APP -D NC_APP_TEST -sdk "$SDK" \
  -target arm64-apple-macos13 -module-cache-path "$MODULE_CACHE" \
  -o "$APP/Contents/MacOS/NotesCopilotLaunchTests" \
  "$OUT/AppDelegate.swift" "${SOURCES[@]}" tests/launch-tests/main.swift tests/launch-tests/InputFieldChecks.swift
if [ "${NC_TEST_INPUT_FIELDS:-0}" = 1 ]; then
  HOST="$OUT/SelectionInputHost.app"
  mkdir -p "$HOST/Contents/MacOS"
  cp "$PLIST" "$HOST/Contents/Info.plist"
  plutil -remove NSServices "$HOST/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string local.notescopilot.input-field-fixture "$HOST/Contents/Info.plist"
  plutil -replace CFBundleName -string SelectionInputHost "$HOST/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string SelectionInputHost "$HOST/Contents/Info.plist"
  swiftc -parse-as-library -sdk "$SDK" -module-cache-path "$MODULE_CACHE" -o "$HOST/Contents/MacOS/SelectionInputHost" tests/launch-tests/InputFieldHost.swift
  codesign --force --sign - "$HOST"
  export NC_INPUT_FIELD_FIXTURE="$HOST/Contents/MacOS/SelectionInputHost"
fi
if [ "${NC_TEST_SYSTEM_SERVICE:-0}" = 1 ]; then
  # Services discovery scans Applications directories. Give the client a separate
  # executable outside the provider bundle so it cannot claim the provider's port.
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  mkdir -p "$HOME/Applications"
  FIXTURE_DIR="$(mktemp -d "$HOME/Applications/NotesCopilotFixture.XXXXXX")"
  trap 'rm -rf "$FIXTURE_DIR" "$OUT"' EXIT
  CLIENT="$OUT/SelectionClient.app"
  cp -R "$APP" "$CLIENT"
  plutil -remove NSServices "$CLIENT/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string local.notescopilot.service-client "$CLIENT/Contents/Info.plist"
  plutil -replace CFBundleName -string SelectionClient "$CLIENT/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string SelectionClient "$CLIENT/Contents/Info.plist"
  codesign --force --sign - "$CLIENT"
  export NC_SERVICE_TEST_CLIENT="$CLIENT/Contents/MacOS/NotesCopilotLaunchTests"
  cp -R "$APP" "$FIXTURE_DIR/"
  APP="$FIXTURE_DIR/NotesCopilotLaunchTests.app"
  codesign --force --sign - "$APP"
  "$LSREGISTER" -f "$APP"
  trap '"$LSREGISTER" -u "$APP"; rm -rf "$FIXTURE_DIR" "$OUT"' EXIT
  /System/Library/CoreServices/pbs -update
  /System/Library/CoreServices/pbs -dump 2>&1 | awk '/NotesCopilot Selection Fixture/ { found=1 } END { print "Service discovered in cache:", found ? "yes" : "no" }'
fi
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/NotesCopilotLaunchTests" --run-tests
