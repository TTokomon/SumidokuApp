#!/bin/bash
# Prepare only: never creates a tag, release or feed deployment.
set -euo pipefail
if [[ $# -lt 2 ]]; then echo 'Usage: prepare-release.sh app output [--previous-catalog catalog.json]' >&2; exit 2; fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SPARKLE=$(python3 "$ROOT/macos/fetch-sparkle.py")
"$ROOT/macos/Distribution/build-trust-tool.sh"
python3 "$ROOT/macos/Distribution/prepare_release.py" "$@" --sparkle "$SPARKLE" --trust-tool "$ROOT/dist/native/ReleaseTrustTool"
