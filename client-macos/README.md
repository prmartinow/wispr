# client-macos

SwiftUI/AppKit menu-bar dictation client. Records mic audio → `POST /transcribe` on the
home server → pastes the returned text into the focused app. Builds against
[`../contract/transcribe.md`](../contract/transcribe.md).

## Build & run
```sh
cd client-macos
./scripts/package_app.sh                       # -> Whisper.app (with Info.plist for mic TCC)
WHISPER_TOKEN="$(ssh -p 2224 user@wispr.local 'cat ~/dev/whisper/server/.env' \
  | sed -n 's/^WHISPER_BEARER_TOKEN=//p')" \
  open ./Whisper.app
```
`WHISPER_SERVER_URL` defaults to `http://wispr.local:8080`; override to point elsewhere.

## Use
- **⌘⌥Space** (or the 🎙️ menu-bar item) toggles dictation: first press records, second press
  stops, uploads, and pastes the transcript where your cursor is.

## Permissions (first run)
- **Microphone** — prompted on first record (needs the bundle's `NSMicrophoneUsageDescription`).
- **Accessibility** — System Settings ▸ Privacy & Security ▸ Accessibility, enable `Whisper`,
  so it can synthesize ⌘V into other apps.

## Files
| File | Role |
|---|---|
| `Sources/Whisper/AppDelegate.swift` | menu bar, hotkey wiring, record→transcribe→insert flow |
| `Sources/Whisper/AudioRecorder.swift` | mic → WAV mono/16-bit/48 kHz (matches contract) |
| `Sources/Whisper/TranscriptionClient.swift` | multipart `POST /transcribe` + error decoding |
| `Sources/Whisper/TextInserter.swift` | pasteboard + synthesized ⌘V |
| `Sources/Whisper/GlobalHotKey.swift` | Carbon system-wide hotkey (⌘⌥Space) |
| `Sources/Whisper/Config.swift` | env config (`WHISPER_SERVER_URL`, `WHISPER_TOKEN`) |
