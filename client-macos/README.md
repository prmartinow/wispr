# client-macos

SwiftUI/AppKit menu-bar dictation client. Records mic audio → `POST /transcribe` on the
home server → pastes the returned text into the focused app. Builds against
[`../contract/transcribe.md`](../contract/transcribe.md).

## Build & run
```sh
cd client-macos
./scripts/package_app.sh        # -> wispr.app (Info.plist for mic TCC + ad-hoc sign)
open ./wispr.app              # configure server/token in Settings (gear), or seed via env:
# WISPR_SERVER_URL=http://wispr.local:8090 \
# WISPR_TOKEN="$(ssh -p 2224 user@wispr.local 'sed -n s/^WHISPER_BEARER_TOKEN=//p ~/dev/whisper/server/.env')" \
#   open ./wispr.app
```
Server URL defaults to `http://wispr.local:8090`. The token is stored in the **Keychain**
(seeded once from `WISPR_TOKEN` if set).

## GUI
- **Floating HUD pill** (bottom-center, always-on-top, non-activating so it never steals focus):
  live **waveform** while recording → **"transcribing…"** during the wait → brief **"inserted"** / error.
- **Menu-bar state machine**: `mic` idle → `mic.fill` (red) recording → `waveform` (yellow)
  transcribing → green check / orange error.
- **Settings** window: server URL, bearer token, **activation mode**, global **shortcut** (click to
  record a new combo), **microphone** picker, and a **Test connection** button (`/healthz`).
- **History** window: recent transcripts (persisted), **Copy** or **Paste** (re-insert into the last app).

## Activation (configurable in Settings)
- **Toggle** — press the shortcut to start, press again to stop.
- **Push-to-talk** — hold the shortcut to record, release to send.
- Default shortcut: **⌘⇧1** (⌘⌥Space collides with Finder's "Search This Mac"). Rebind in Settings.

## Permissions (first run)
- **Microphone** — prompted on first record (`NSMicrophoneUsageDescription` in the bundle).
- **Accessibility** — System Settings ▸ Privacy & Security ▸ Accessibility, enable `wispr`
  (needed for the **global hotkey** monitor and to synthesize ⌘V into other apps).

## Files
| File | Role |
|---|---|
| `AppDelegate.swift` | status item, windows, hotkey wiring, record→transcribe→insert orchestration |
| `AppState.swift` | observable dictation state machine (phase, level, elapsed) |
| `Settings.swift` | persisted settings (UserDefaults) + bearer token (Keychain) |
| `HistoryStore.swift` | recent transcripts, JSON in Application Support |
| `AudioRecorder.swift` | mic → WAV mono/16-bit/48 kHz (contract) + live level metering |
| `AudioDevices.swift` | list input devices + set system default input (mic picker) |
| `HotKeyManager.swift` | global shortcut via NSEvent monitor — toggle + push-to-talk |
| `TranscriptionClient.swift` | multipart `POST /transcribe`, `/healthz`, error decoding |
| `TextInserter.swift` | pasteboard + synthesized ⌘V |
| `HUD.swift` | floating pill panel + waveform view |
| `SettingsView.swift` / `HistoryView.swift` | SwiftUI windows |
