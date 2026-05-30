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
  <key>CFBundleIdentifier</key><string>co.quandefi.whisper</string>
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

# Ad-hoc sign so TCC tracks a stable identity across launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warn: codesign skipped"

echo "Built $APP"
echo "Run:   open ./$APP   (server defaults to :8090; set URL/token in Settings, or seed once"
echo "       with WHISPER_SERVER_URL / WHISPER_TOKEN env on first launch — token goes to Keychain)"
echo "Logs:  ./$APP/Contents/MacOS/Whisper   (foreground, prints NSLog output)"
echo "Grant Microphone + Accessibility when prompted (Accessibility = global hotkey + paste)."
