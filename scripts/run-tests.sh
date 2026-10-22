#!/bin/bash
# 四套单测回归：selai(33) / slashgroup(26) / template(41) / urltitle(28)，共 128 项
# 用法：scripts/run-tests.sh   （在仓库任意位置执行）
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

COMMON_SOURCES="src/NotesBridge.swift src/Slash.swift src/SlashSuggest.swift src/UrlTitle.swift src/TemplateEngine.swift src/FormatBridge.swift src/Topotext.swift src/FrontmostTracker.swift src/LiberatorLite.swift src/Chat.swift"

run_suite() {
  local name="$1"; shift
  echo "==> $name"
  swiftc -O -sdk "$SDK" -target "$TARGET" -o "$OUT/$name" "$@" 2>&1 | grep -E "error:" && {
    echo "❌ $name 编译失败"; exit 1
  } || true
  "$OUT/$name" | tail -1
}

run_suite selai-tests    tests/selai-tests/main.swift    src/SelectionAI.swift $COMMON_SOURCES
run_suite slashgroup-tests tests/slashgroup-tests/main.swift $COMMON_SOURCES
run_suite template-tests tests/template-tests/main.swift $COMMON_SOURCES
run_suite urltitle-tests tests/urltitle-tests/main.swift $COMMON_SOURCES

echo "✅ 四套测试全部通过"
