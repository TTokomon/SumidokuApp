#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$ROOT/dist/native/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/dist/native/ModuleCache" \
  "$ROOT/macos/App/InstallationContext.swift" "$ROOT/macos/App/LibraryManager.swift" "$ROOT/macos/tests/CommunitySourceTests.swift" \
  -o "$ROOT/dist/native/CommunitySourceTests"
"$ROOT/dist/native/CommunitySourceTests"
