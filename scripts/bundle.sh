#!/bin/bash
# Builds ClaudeLights.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal binary so Intel Macs work too.
swift build -c release --arch arm64 --arch x86_64
BIN=.build/apple/Products/Release/ClaudeLights

APP=build/ClaudeLights.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeLights"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>me.honghao.ClaudeLights</string>
    <key>CFBundleName</key><string>Claude Lights</string>
    <key>CFBundleExecutable</key><string>ClaudeLights</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claude Lights focuses the iTerm2 tab that hosts the Claude session you clicked.</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
