#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/sumidoku-welcome.XXXXXX")
APP="$OUTPUT/WelcomeTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist/native/ModuleCache"
cp "$ROOT/macos/service.sh" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>WelcomeTests</string><key>CFBundleIdentifier</key><string>app.sumidoku.welcome-tests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -D NATIVE_UI_TESTS -module-cache-path "$ROOT/dist/native/ModuleCache" \
  "$ROOT/macos/App/LibraryManager.swift" "$ROOT/macos/App/WebSession.swift" "$ROOT/macos/App/NavigationPolicy.swift" \
  "$ROOT/macos/App/SumidokuApp.swift" "$ROOT/macos/tests/WelcomeRenderTests.swift" -o "$APP/Contents/MacOS/WelcomeTests"
"$APP/Contents/MacOS/WelcomeTests" "$OUTPUT"
echo "Native view renders: $OUTPUT"
