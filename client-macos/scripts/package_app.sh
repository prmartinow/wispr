#!/usr/bin/env bash
# Build the SPM executable and wrap it in a proper wispr.app bundle (Info.plist for TCC + icon).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/wispr"
APP="wispr.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/wispr"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>wispr</string>
  <key>CFBundleDisplayName</key><string>wispr</string>
  <key>CFBundleIdentifier</key><string>xyz.p12w.wispr</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>wispr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>wispr records your voice so it can be transcribed by your dictation server.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>wispr connects to your local dictation server on your private network.</string>
</dict>
</plist>
PLIST

# Stable local code-signing identity so Accessibility/Mic grants survive rebuilds. The signing
# keychain is intentionally still named "wispr-signing" (internal, invisible) — renaming it
# would force re-creating the cert and an extra re-grant for no user benefit.
SIGN_CN="wispr Local Signing"
SIGN_KC="$HOME/Library/Keychains/wispr-signing.keychain-db"
"$(dirname "$0")/setup-signing.sh" >/dev/null 2>&1 || true
if security find-certificate -c "$SIGN_CN" "$SIGN_KC" >/dev/null 2>&1; then
  security unlock-keychain -p wispr-local "$SIGN_KC" 2>/dev/null || true
  if codesign --force --sign "$SIGN_CN" --keychain "$SIGN_KC" "$APP" >/dev/null 2>&1; then
    echo "signed with stable identity '$SIGN_CN' — TCC grants persist across rebuilds"
  else
    codesign --force --sign - "$APP" >/dev/null 2>&1; echo "warn: stable sign failed → ad-hoc (TCC resets)"
  fi
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warn: codesign skipped"
fi

echo "Built $APP"
echo "Run:   open ./$APP   (configure the server in Settings, or seed once via"
echo "       WISPR_SERVER_URL / WISPR_TOKEN env on first launch - token goes to private app support)"
echo "Logs:  ~/Library/Logs/wispr/wispr.log  (or menu → Reveal Log in Finder)"
echo "Grant Microphone + Accessibility when prompted (Accessibility = global hotkey + paste)."
