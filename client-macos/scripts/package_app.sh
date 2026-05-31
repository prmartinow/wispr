#!/usr/bin/env bash
# Build the SPM executable and wrap it in a proper .app bundle.
# The bundle + Info.plist are required so macOS TCC will grant Microphone access
# (a bare CLI binary has no usage string and would crash on requestAccess).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/Whisper"
APP="Whisper.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Whisper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Whisper</string>
  <key>CFBundleDisplayName</key><string>Whisper</string>
  <key>CFBundleIdentifier</key><string>xyz.p12w.whisper</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>Whisper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Whisper records your voice so it can be transcribed by your dictation server.</string>
</dict>
</plist>
PLIST

# Sign with a stable local identity if available (so Accessibility/Mic grants survive
# rebuilds); otherwise fall back to ad-hoc (TCC will reset each build).
SIGN_CN="Whisper Local Signing"
SIGN_KC="$HOME/Library/Keychains/whisper-signing.keychain-db"
"$(dirname "$0")/setup-signing.sh" >/dev/null 2>&1 || true
if security find-certificate -c "$SIGN_CN" "$SIGN_KC" >/dev/null 2>&1; then
  security unlock-keychain -p whisper-local "$SIGN_KC" 2>/dev/null || true
  if codesign --force --sign "$SIGN_CN" --keychain "$SIGN_KC" "$APP" >/dev/null 2>&1; then
    echo "signed with stable identity '$SIGN_CN' — TCC grants persist across rebuilds"
  else
    codesign --force --sign - "$APP" >/dev/null 2>&1; echo "warn: stable sign failed → ad-hoc (TCC resets)"
  fi
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warn: codesign skipped"
fi

echo "Built $APP"
echo "Run:   open ./$APP   (server defaults to :8090; set URL/token in Settings, or seed once"
echo "       with WHISPER_SERVER_URL / WHISPER_TOKEN env on first launch — token goes to Keychain)"
echo "Logs:  ./$APP/Contents/MacOS/Whisper   (foreground, prints NSLog output)"
echo "Grant Microphone + Accessibility when prompted (Accessibility = global hotkey + paste)."
