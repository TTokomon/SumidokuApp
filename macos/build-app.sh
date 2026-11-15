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
SPARKLE=$(python3 "$ROOT/macos/fetch-sparkle.py")
APP_OUTPUT=${SUMIDOKU_APP_OUTPUT:-"$OUT/Sumidoku.app"}
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/sumidoku-client-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Sumidoku.app"
mkdir -p "$OUT/ModuleCache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$OUT/ModuleCache" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework SwiftUI -framework WebKit -framework AppKit -framework ScreenCaptureKit \
  "$ROOT"/macos/App/*.swift \
  -o "$APP/Contents/MacOS/Sumidoku"
mkdir -p "$APP/Contents/Frameworks"
ditto --norsrc --noextattr "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$ROOT/macos/service.sh" "$APP/Contents/Resources/service.sh"
cp "$ROOT/macos/run-server.sh" "$APP/Contents/Resources/run-server.sh"
SERVER_BINARY=${SUMIDOKU_SERVER_BINARY:-"$HOME/Library/Application Support/Sumidoku/bin/sumidoku-server"}
if [[ ${SUMIDOKU_SERVER_VARIANT:-official} == fork ]]; then
  python3 - "$SERVER_BINARY" "$ROOT/dist/fork/server-build.json" <<'PYBUILD'
import hashlib,json,sys
from pathlib import Path
binary=Path(sys.argv[1]); info=json.loads(Path(sys.argv[2]).read_text())
if info['variant']!='fork' or hashlib.sha256(binary.read_bytes()).hexdigest()!=info['sha256']:
    raise SystemExit('Fork manifest does not match binary')
PYBUILD
  cp "$ROOT/dist/fork/server-build.json" "$APP/Contents/Resources/server-build.json"
else
  EXPECTED_SERVER_SHA=f00cb5a8de57fa828e23858d12cd10a988a7abc42695185864571d57fe1c5f1b
  if [[ $(shasum -a 256 "$SERVER_BINARY" | awk '{print $1}') != "$EXPECTED_SERVER_SHA" ]]; then
    echo 'Pinned official server binary missing or checksum differs. Run the binary-only installer.' >&2
    exit 1
  fi
fi
cp "$SERVER_BINARY" "$APP/Contents/Resources/sumidoku-server"
python3 - "$APP" <<'PY'
from pathlib import Path
import os, plistlib, sys
app = Path(sys.argv[1])
info = {
    'CFBundleName': 'Sumidoku', 'CFBundleDisplayName': 'Sumidoku',
    'CFBundleIdentifier': 'app.sumidoku.desktop', 'CFBundleExecutable': 'Sumidoku',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.3.1', 'CFBundleVersion': '7',
    'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
    'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True,
    'SUSignedFeedFailureExpirationInterval': 0, 'SumidokuCoordinatedUpdatesValidated': False,
    'SumidokuDevelopmentBuild': os.environ.get('SUMIDOKU_RELEASE_BUILD') != '1',
    'CFBundleIconFile': 'AppIcon', 'NSPrincipalClass': 'NSApplication',
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
}
for name, key in [('SUMIDOKU_RELEASE_VERSION','SumidokuReleaseVersion'),('SUMIDOKU_UPDATE_FEED','SUFeedURL'),('SUMIDOKU_UPDATE_PUBLIC_KEY','SUPublicEDKey'),('SUMIDOKU_RELEASE_TEAM','SumidokuReleaseTeam')]:
    if os.environ.get(name): info[key] = os.environ[name]
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
if [[ ${SIGNING_IDENTITY:--} != - ]]; then
  python3 - "$APP/Contents/Frameworks/Sparkle.framework" "$SIGNING_IDENTITY" <<'PYSIGN'
from pathlib import Path
import subprocess,sys
framework=Path(sys.argv[1]); identity=sys.argv[2]
# Sign executable leaves, then nested bundles, then the enclosing framework.
leaves=[]
for path in (framework/'Versions').rglob('*'):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as file: magic=file.read(4)
        if magic in [bytes.fromhex(h) for h in ['cffaedfe','feedfacf','cafebabe','bebafeca','cafebabf']]: leaves.append(path)
bundles=[p for p in (framework/'Versions').rglob('*') if p.suffix in ['.app','.xpc'] and p.is_dir()]
for path in leaves+sorted(bundles,key=lambda p:len(p.parts),reverse=True)+[framework]:
    subprocess.run(['codesign','--force','--options','runtime','--timestamp','--sign',identity,str(path)],check=True)
PYSIGN
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --identifier app.sumidoku.desktop "$APP"
else
  codesign --force --sign - --identifier app.sumidoku.desktop "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
mkdir -p "$(dirname "$APP_OUTPUT")"
rm -rf "$APP_OUTPUT"
ditto --norsrc --noextattr "$APP" "$APP_OUTPUT"
xattr -dr com.apple.FinderInfo "$APP_OUTPUT" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_OUTPUT" 2>/dev/null || true
codesign --verify --strict "$APP_OUTPUT"
echo "Built: $APP_OUTPUT"
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
