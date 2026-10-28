#!/bin/zsh
# Builds RayNeoPin.app next to this script.
#
# Signing: uses SIGN_ID if set, else your first "Apple Development" identity, else ad-hoc.
# A real identity matters: macOS ties the Screen Recording permission to the signature,
# so ad-hoc builds lose it on every rebuild.
set -euo pipefail
cd "${0:A:h}"

APP=RayNeoPin.app
BUNDLE_ID=io.github.fuut4.rayneopin
REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo dev)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>RayNeoPin</string>
  <key>CFBundleExecutable</key><string>RayNeoPin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleVersion</key><string>$REVISION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>RayNeoPin connects the AirPods you pick so they can be used for head tracking.</string>
  <key>NSMotionUsageDescription</key><string>RayNeoPin uses your AirPods head tracking as a second reference to keep the pinned screen from drifting.</string>
</dict>
</plist>
PLIST
echo "$REVISION" > "$APP/Contents/Resources/revision"

swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -import-objc-header Sources/CGVirtualDisplay.h \
  Sources/*.swift -o "$APP/Contents/MacOS/RayNeoPin"

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
  echo "Signed with: $SIGN_ID"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "Signed ad-hoc (Screen Recording permission must be re-granted after each update)"
fi
echo "Built $PWD/$APP ($REVISION)"
