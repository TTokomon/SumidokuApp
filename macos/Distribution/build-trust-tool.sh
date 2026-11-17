#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/dist/native/ModuleCache"
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/dist/native/ModuleCache" \
 "$ROOT/macos/App/UpdatePolicy.swift" "$ROOT/macos/App/ReleaseIdentity.swift" "$ROOT/macos/App/InstallationContext.swift" \
 "$ROOT/macos/App/CommunityBundleTrust.swift" "$ROOT/macos/App/ReleaseTrust.swift" \
 "$ROOT/macos/App/ArchiveValidation.swift" "$ROOT/macos/App/PairedInstallation.swift" \
 "$ROOT/macos/Distribution/TrustTool.swift" -o "$ROOT/dist/native/ReleaseTrustTool"
