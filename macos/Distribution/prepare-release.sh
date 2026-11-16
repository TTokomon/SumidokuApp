#!/bin/bash
# Prepare only: never creates a tag, release or feed deployment.
set -euo pipefail
if [[ $# -lt 2 ]]; then echo 'Usage: prepare-release.sh app output [--previous-catalog catalog.json]' >&2; exit 2; fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SPARKLE=$(python3 "$ROOT/macos/fetch-sparkle.py")
mkdir -p "$ROOT/dist/native/ModuleCache"
DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)} xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$ROOT/dist/native/ModuleCache" "$ROOT/macos/App/UpdatePolicy.swift" \
  "$ROOT/macos/App/ReleaseTrust.swift" "$ROOT/macos/Distribution/TrustTool.swift" \
  -o "$ROOT/dist/native/ReleaseTrustTool"
python3 "$ROOT/macos/Distribution/prepare_release.py" "$@" --sparkle "$SPARKLE" --trust-tool "$ROOT/dist/native/ReleaseTrustTool"
