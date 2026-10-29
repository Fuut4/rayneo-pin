#!/bin/zsh
# Builds RayNeoPin.app next to this script.
#
# Signing: SIGN_ID if set, else your first "Apple Development" or "Developer ID Application"
# identity, else a local self-signed "RayNeoPin Local Signing" identity, created once in the
# login keychain. A stable identity matters: macOS ties the Screen Recording permission to it,
# so ad-hoc builds (the last resort) lose it on every rebuild.
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
  <key>NSCameraUsageDescription</key><string>Optional: RayNeoPin can watch which way your face points to keep the pinned screen from drifting. Nothing is recorded or sent anywhere.</string>
  <key>NSMotionUsageDescription</key><string>RayNeoPin uses your AirPods head tracking as a second reference to keep the pinned screen from drifting.</string>
</dict>
</plist>
PLIST
echo "$REVISION" > "$APP/Contents/Resources/revision"

swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -import-objc-header Sources/CGVirtualDisplay.h \
  Sources/*.swift -o "$APP/Contents/MacOS/RayNeoPin"

LOCAL_ID="RayNeoPin Local Signing"

# A self-signed code-signing certificate, created once; no Apple account needed. macOS keeps the
# Screen Recording permission for as long as builds are signed with it.
local_identity() {
  security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1 && return 0
  echo "Creating a local signing certificate (once), so macOS keeps RayNeoPin's permissions across updates."
  echo "macOS may ask to allow codesign to use it: choose Always Allow."
  local tmp=$(mktemp -d)
  cat > "$tmp/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $LOCAL_ID
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
  local pass=$(uuidgen)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cfg" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 &&
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$LOCAL_ID" \
      -out "$tmp/identity.p12" -passout "pass:$pass" >/dev/null 2>&1 &&
    security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" \
      -T /usr/bin/codesign >/dev/null 2>&1
  local ok=$?
  rm -rf "$tmp"
  return $ok
}

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
if [[ -z "$SIGN_ID" ]] && local_identity; then SIGN_ID=$LOCAL_ID; fi
if [[ -n "$SIGN_ID" ]] && codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
  echo "Signed with: $SIGN_ID"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "Signed ad-hoc: macOS will ask for Screen Recording permission again after each update."
fi
echo "Built $PWD/$APP ($REVISION)"
