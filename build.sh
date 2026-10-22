#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
APP="build/NotesCopilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -D NC_APP -sdk "$SDK" -target arm64-apple-macos13 \
  -o "$APP/Contents/MacOS/NotesCopilot" \
  src/main.swift src/Chat.swift src/Slash.swift src/SlashSuggest.swift src/NotesBridge.swift src/FrontmostTracker.swift src/LiberatorLite.swift src/Topotext.swift src/FormatBridge.swift src/LibraryView.swift src/Views.swift src/TemplateEngine.swift src/SelectionAI.swift src/UrlTitle.swift
cp Info.plist "$APP/Contents/Info.plist"
# 稳定签名：自签证书「NotesCopilot Dev」若可用则用它（TCC 授权跨重建稳定）。
# 首次用它签名会弹钥匙串授权窗（需点「始终允许」）；非交互环境下限时自动回退 adhoc。
signed=1
if security find-identity -p codesigning 2>/dev/null | grep -q "NotesCopilot Dev"; then
  perl -e 'alarm 12; exec @ARGV' codesign --force --sign "NotesCopilot Dev" "$APP" >/dev/null 2>&1 || signed=0
else
  signed=0
fi
if [ "$signed" != 1 ]; then
  codesign --force --sign - "$APP" >/dev/null 2>&1
  rm -f "$APP/Contents/MacOS/"*.cstemp 2>/dev/null
fi
echo "BUILD OK: $APP"
