#!/bin/bash
# Produces local signed distribution files only; never creates a GitHub release.
set -euo pipefail
if [[ $# != 2 ]]; then echo 'Usage: prepare-release.sh /path/Sumidoku.app /path/output-directory' >&2; exit 2; fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=$1
OUTPUT=$2
SPARKLE=$(python3 "$ROOT/macos/fetch-sparkle.py")
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,subprocess,sys
app=Path(sys.argv[1])
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if not info.get('SUPublicEDKey') or not info.get('SUFeedURL','').startswith('https://'):
    raise SystemExit('Configure the public update key and HTTPS feed before distribution.')
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
result=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True,check=True)
if 'Authority=Developer ID Application:' not in result.stderr:
    raise SystemExit('Public distribution requires Developer ID signing.')
subprocess.run(['/usr/sbin/spctl','--assess','--type','execute',str(app)],check=True)
PY
mkdir -p "$OUTPUT"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHIVE="$OUTPUT/Sumidoku-Desktop-$VERSION-macOS-arm64.zip"
[[ ! -e "$ARCHIVE" ]] || { echo 'Archive already exists; preserved.' >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
# Sparkle reads the signing key from the owner's Keychain, never from Git or arguments.
"$SPARKLE/bin/sign_update" --account app.sumidoku.desktop.release "$ARCHIVE"
"$SPARKLE/bin/generate_appcast" --account app.sumidoku.desktop.release "$OUTPUT"
echo 'Local release files prepared. Review and explicitly publish the versioned GitHub release and HTTPS appcast separately.'
