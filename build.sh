#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
# Set a separate output while the current app is being used for configuration.
APP="${NC_BUILD_OUTPUT:-build/NotesCopilot.app}"
ICON="assets/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  echo "应用图标不存在：$ICON，请先运行 scripts/generate-app-icon.sh" >&2
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
MODULE_CACHE="${TMPDIR:-/private/tmp}/notescopilot-swift-module-cache"
mkdir -p "$MODULE_CACHE"
swiftc -O -D NC_APP -sdk "$SDK" -target arm64-apple-macos13 -module-cache-path "$MODULE_CACHE" \
  -o "$APP/Contents/MacOS/NotesCopilot" \
  src/*.swift
cp Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# 使用稳定开发身份，避免每次重建的 adhoc 哈希改变系统权限身份。
# NC_CODESIGN_IDENTITY 可指定证书名称/哈希；设为 - 可离线构建且不触发私钥授权。
SIGN_IDENTITY="${NC_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/"NotesCopilot Dev"/ { print $2; exit }')"
  if [ -z "$SIGN_IDENTITY" ]; then
    DEV_IDENTITIES="$(printf '%s\n' "$IDENTITIES" | awk '/"Apple Development:/ { print $2 }')"
    if [ "$(printf '%s\n' "$DEV_IDENTITIES" | awk 'NF { n++ } END { print n+0 }')" = 1 ]; then
      SIGN_IDENTITY="$DEV_IDENTITIES"
    fi
  fi
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
# 签名失败必须可见；不能在开发签名失败后悄悄换成另一种权限身份。
codesign --force --sign "$SIGN_IDENTITY" "$APP"
if [ "$SIGN_IDENTITY" = - ]; then
  echo "SIGNING: adhoc (系统授权可能需要在重建后重新确认)"
else
  echo "SIGNING: stable development identity"
fi
echo "BUILD OK: $APP"
