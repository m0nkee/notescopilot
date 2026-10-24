#!/bin/bash
# 逻辑与异步回归；可传入套件名称仅执行指定测试。
# 用法：scripts/run-tests.sh [writeback-tests chat-tests template-runner-tests]
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13"
OUT="$(mktemp -d)"
MODULE_CACHE="${TMPDIR:-/private/tmp}/notescopilot-swift-module-cache"
mkdir -p "$MODULE_CACHE"
trap 'rm -rf "$OUT"' EXIT

COMMON_SOURCES=(src/NotesBridge.swift src/Slash.swift src/SlashSuggest.swift src/UrlTitle.swift
  src/TemplateEngine.swift src/FormatBridge.swift src/Topotext.swift src/FrontmostTracker.swift
  src/LiberatorLite.swift src/Chat.swift src/Markdown.swift src/NotesTemplateImporter.swift)

# Test a single source snapshot, even when an editor is saving files during a run.
cp -R src tests "$OUT/"
cd "$OUT"

run_suite() {
  local name="$1"; shift
  echo "==> $name"
  swiftc -O -sdk "$SDK" -target "$TARGET" -module-cache-path "$MODULE_CACHE" -o "$OUT/$name" "$@" 2>&1 | tee "$OUT/$name-compile.log"
  "$OUT/$name" | tee "$OUT/$name-test.log"
}

SUITES=(selai-tests slashgroup-tests template-tests urltitle-tests writeback-tests template-runner-tests chat-tests library-tests product-tests update-tests)
if [ "$#" -gt 0 ]; then SUITES=("$@"); fi
for suite in "${SUITES[@]}"; do
  case "$suite" in
    update-tests)
      run_suite "$suite" tests/update-tests/main.swift src/AppUpdater.swift ;;
    selai-tests|writeback-tests)
      run_suite "$suite" "tests/$suite/main.swift" src/SelectionAI.swift "${COMMON_SOURCES[@]}" ;;
    slashgroup-tests|template-tests|urltitle-tests|template-runner-tests|chat-tests)
      run_suite "$suite" "tests/$suite/main.swift" "${COMMON_SOURCES[@]}" ;;
    library-tests)
      run_suite "$suite" tests/src/main.swift src/LiberatorLite.swift src/Topotext.swift ;;
    product-tests)
      run_suite "$suite" tests/product-tests/main.swift "${COMMON_SOURCES[@]}" ;;
    *) printf '未知测试套件：%s\n' "$suite" >&2; exit 1 ;;
  esac
done

echo "✅ 全部测试套件通过"
