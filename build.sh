#!/bin/zsh
# Builds RayNeoPin.app next to this script.
set -euo pipefail
cd "${0:A:h}"

APP=RayNeoPin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.rayneopin</string>
  <key>CFBundleName</key><string>RayNeoPin</string>
  <key>CFBundleExecutable</key><string>RayNeoPin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 main.swift -o "$APP/Contents/MacOS/RayNeoPin"
codesign --force --sign - --identifier local.rayneopin "$APP"
echo "Built $PWD/$APP"
