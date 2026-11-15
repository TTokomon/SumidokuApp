#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$ROOT/dist/native/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -D NATIVE_UI_TESTS -module-cache-path "$ROOT/dist/native/ModuleCache" \
  "$ROOT"/macos/App/*.swift "$ROOT/macos/tests/NativeSymbolTests.swift" -o "$ROOT/dist/native/NativeSymbolTests"
"$ROOT/dist/native/NativeSymbolTests"
