#!/bin/bash
# Build the desktop client only. The existing server and data are not replaced.
set -euo pipefail
case "${1:-}" in
  ""|--install) ;;
  *) echo 'Usage: build-app.sh [--install]' >&2; exit 1 ;;
esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
if [[ "$DEVELOPER_DIR" == /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
OUT="$ROOT/dist/native"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/sumidoku-client-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Sumidoku.app"
mkdir -p "$OUT/ModuleCache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$OUT/ModuleCache" -framework SwiftUI -framework WebKit -framework AppKit \
  "$ROOT/macos/App/WebSession.swift" "$ROOT/macos/App/LibraryManager.swift" "$ROOT/macos/App/NavigationPolicy.swift" "$ROOT/macos/App/SumidokuApp.swift" \
  -o "$APP/Contents/MacOS/Sumidoku"
cp "$ROOT/macos/service.sh" "$APP/Contents/Resources/service.sh"
cp "$ROOT/macos/run-server.sh" "$APP/Contents/Resources/run-server.sh"
SERVER_BINARY=${SUMIDOKU_SERVER_BINARY:-"$HOME/Library/Application Support/Sumidoku/bin/sumidoku-server"}
EXPECTED_SERVER_SHA=f00cb5a8de57fa828e23858d12cd10a988a7abc42695185864571d57fe1c5f1b
if [[ $(shasum -a 256 "$SERVER_BINARY" | awk '{print $1}') != "$EXPECTED_SERVER_SHA" ]]; then
  echo 'Pinned official server binary missing or checksum differs. Run the binary-only installer.' >&2
  exit 1
fi
cp "$SERVER_BINARY" "$APP/Contents/Resources/sumidoku-server"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = {
    'CFBundleName': 'Sumidoku', 'CFBundleDisplayName': 'Sumidoku',
    'CFBundleIdentifier': 'app.sumidoku.desktop', 'CFBundleExecutable': 'Sumidoku',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.1.0', 'CFBundleVersion': '2',
    'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'CFBundleIconFile': 'AppIcon', 'NSPrincipalClass': 'NSApplication',
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
}
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
PY
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/webui/public/icons/icon-512.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/webui/public/icons/icon-512.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Remove only Finder/resource-fork metadata from our generated build product.
# This neither changes system Gatekeeper policy nor strips quarantine globally.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier app.sumidoku.desktop "$APP"
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
ditto --norsrc --noextattr "$APP" "$OUT/Sumidoku.app"
xattr -dr com.apple.FinderInfo "$OUT/Sumidoku.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$OUT/Sumidoku.app" 2>/dev/null || true
codesign --verify --strict "$OUT/Sumidoku.app"
echo "Built: $OUT/Sumidoku.app"
if [[ ${1:-} == --install ]]; then
  if [[ -e /Applications/Sumidoku.app ]]; then
    echo 'Existing /Applications/Sumidoku.app preserved. Quit it and use the documented app update procedure.' >&2
    exit 1
  fi
  ditto --norsrc --noextattr "$APP" /Applications/Sumidoku.app
  xattr -dr com.apple.FinderInfo /Applications/Sumidoku.app 2>/dev/null || true
  xattr -dr com.apple.ResourceFork /Applications/Sumidoku.app 2>/dev/null || true
  codesign --verify --strict /Applications/Sumidoku.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Sumidoku.app
  echo 'Installed: /Applications/Sumidoku.app'
fi
