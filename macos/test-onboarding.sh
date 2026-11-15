#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$ROOT/dist/native/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/dist/native/ModuleCache" \
  "$ROOT/macos/App/WebSession.swift" "$ROOT/macos/App/LibraryManager.swift" "$ROOT/macos/tests/LibraryManagerTests.swift" -lsqlite3 \
  -o "$ROOT/dist/native/LibraryManagerTests"
"$ROOT/dist/native/LibraryManagerTests" "${SUMIDOKU_SERVER_BINARY:-$HOME/Library/Application Support/Sumidoku/bin/sumidoku-server}" "$ROOT/macos/run-server.sh" "${@}"
