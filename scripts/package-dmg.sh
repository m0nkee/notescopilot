#!/bin/bash
# Package an already built and signed Apple Silicon app without copying user data.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 2 ]; then
  echo "用法：$0 [NotesCopilot.app 路径] [输出 DMG 路径]" >&2
  exit 2
fi
APP="${1:-build/release/NotesCopilot.app}"
PLIST="$APP/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
  echo "应用包不存在：$APP" >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "无效的发布版本：$VERSION" >&2
  exit 1
fi
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
if [ "$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")" != arm64 ]; then
  echo "当前打包脚本仅支持 arm64 应用包" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
OUTPUT="${2:-build/release/NotesCopilot-$VERSION-arm64.dmg}"
if [ -e "$OUTPUT" ]; then
  echo "输出已存在，请使用其他路径：$OUTPUT" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/notescopilot-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/NotesCopilot.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "NotesCopilot $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO "$OUTPUT"
hdiutil verify "$OUTPUT"
echo "DMG OK: $OUTPUT"
