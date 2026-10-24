#!/bin/bash
# Generate the macOS icon bundle from the source PNG.
set -euo pipefail
cd "$(dirname "$0")/.."

INPUT="assets/AppIcon.png"
OUTPUT="assets/AppIcon.icns"
if [ ! -f "$INPUT" ]; then
  echo "图标源文件不存在：$INPUT" >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/notescopilot-icon.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"

for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$INPUT" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$INPUT" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$OUTPUT"
echo "ICON OK: $OUTPUT"
