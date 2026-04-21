#!/bin/bash
# Build the .app bundle from mapwatch.swift.
# Output: ./dist/OpenFront Map Watch.app
#
# Requires: Xcode Command Line Tools (swiftc). Install with `xcode-select --install`.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="OpenFront Map Watch"
DIST="$HERE/dist"
APP="$DIST/$APP_NAME.app"

# Clean.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Compile.
echo "==> Building Swift binary"
xcrun swiftc -O -o "$APP/Contents/MacOS/OpenFrontMapWatch" "$HERE/mapwatch.swift"

# Info.plist.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>OpenFrontMapWatch</string>
    <key>CFBundleIdentifier</key>
    <string>com.openfrontmod.mapwatch</string>
    <key>CFBundleName</key>
    <string>OpenFront Map Watch</string>
    <key>CFBundleDisplayName</key>
    <string>OpenFront Map Watch</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

echo "==> Built: $APP"
ls -l "$APP/Contents/MacOS/OpenFrontMapWatch"
