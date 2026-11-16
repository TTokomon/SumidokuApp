#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
mkdir -p "$ROOT/dist/native/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/dist/native/ModuleCache" \
  "$ROOT/macos/App/UpdatePolicy.swift" "$ROOT/macos/App/ReleaseTrust.swift" "$ROOT/macos/App/ArchiveValidation.swift" \
  "$ROOT/macos/App/PairedInstallation.swift" "$ROOT/macos/tests/ReleaseSecurityTests.swift" -o "$ROOT/dist/native/ReleaseSecurityTests"
"$ROOT/dist/native/ReleaseSecurityTests"
