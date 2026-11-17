#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SPARKLE=$(python3 "$ROOT/macos/fetch-sparkle.py")
mkdir -p "$ROOT/dist/native/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/dist/native/ModuleCache" \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE" \
  "$ROOT/macos/App/ReleaseTrust.swift" "$ROOT/macos/App/ArchiveValidation.swift" "$ROOT/macos/App/PairedInstallation.swift" "$ROOT/macos/App/UpdateHandoff.swift" "$ROOT/macos/App/NativeUpdateInstaller.swift" "$ROOT/macos/App/UpdatePolicy.swift" "$ROOT/macos/App/ReleaseIdentity.swift" "$ROOT/macos/App/InstallationContext.swift" "$ROOT/macos/App/CommunityBundleTrust.swift" "$ROOT/macos/App/AppUpdates.swift" "$ROOT/macos/App/DesktopDesign.swift" "$ROOT/macos/tests/UpdatePolicyTests.swift" \
  -o "$ROOT/dist/native/UpdatePolicyTests"
"$ROOT/dist/native/UpdatePolicyTests"
