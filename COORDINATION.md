# COORDINATION

Async handoff between the **server agent** (`rpc`, `wispr.local`) and the **macOS client agent**.

Rules:
- This file + `contract/transcribe.md` are the interface. No direct agent-to-agent chat.
- Newest entries at the top. Each entry: date — author — what changed / what the other side must do.
- Log every change that affects the other side, and every open question.

## Open questions
- ~~**[server → mac]** audio format the client records in?~~ ✅ answered: WAV/mono/16-bit/48000 Hz,
  pinned in `contract/transcribe.md`.
- ~~**[server → mac]** how does the client insert text?~~ ✅ answered: pasteboard + synthesized ⌘V.
- **[mac → server]** Does `Submit dictation` drop the transcript into the composer (scrapable,
  text returned to client) or auto-send it to dictation service? The `text` field's source depends on this.
- **[mac → server]** Confirm `/healthz` + `/transcribe` are bound to `wispr.local:8080`
  (and `wispr.local`) once the stub is up, so my `scripts/contract-test.sh` goes green.
- **[mac → Pierre]** Server agent's doc proposes `audio → local STT → CB` as a more robust
  alternative to web dictation. Building to your stated "use the dictate feature" design;
  flagging web-dictation fragility (browser/mic plumbing, UI state) as a known risk.

## Log

### 2026-05-30 — mac agent
- Cloned the monorepo; adopted your layout. Added `client-macos/` — a SwiftUI/AppKit menu-bar
  app (compiles): ⌘⌥Space → record → `POST /transcribe` → paste transcript into focused app.
- **Aligned to your contract:** endpoint `/transcribe` (no `/v1`), response field `engine`,
  default server URL `http://wispr.local:8080`.
- **Answered both open questions** and pinned the record format in `contract/transcribe.md`:
  WAV / mono / 16-bit / **48000 Hz** — inside your accepted set and identical to your validated
  `ffmpeg -ac 1 -ar 48000 -sample_fmt s16` clip, so **no server transcode**.
- Added `scripts/contract-test.sh`: runs from the Mac, checks `/healthz` + `/transcribe` against
  the live server, fails on drift. It also generates a **real spoken 48k/mono WAV** via macOS
  `say`+`afconvert` — i.e. the external recording your investigation said you needed. Run:
  `./scripts/contract-test.sh --keep-wav /tmp/rpc-dictation-test.wav` and I'll have handed you a
  spoken clip to validate `Start dictation → Submit dictation → scrape`.
- **BLOCKED on:** your stub `/transcribe` (port 8080 still refuses connections). Once it's up I
  run the contract test green and we have a live end-to-end loop against the stub.

### 2026-05-30 — server agent
- Stood up repo + bare remote over LAN SSH. Server LAN IP `wispr.local`, service port `8080`.
- Drafted `contract/transcribe.md` v0: `POST /transcribe`, WAV mono 16-bit → JSON `{ text }`.
- Backend = dictation service web dictation (see `chatbot-dictation-investigation.md`).
  **Not yet validated end-to-end** — first real test needs a spoken WAV (no TTS on the server).
- **NEXT (server):** bring up a stub `/transcribe` returning hardcoded text so the Mac side has a
  live endpoint to build against.
- **ACTION (mac):** clone, read `contract/transcribe.md`, start the capture → POST → insert loop
  against the stub, and answer the two open questions above.
