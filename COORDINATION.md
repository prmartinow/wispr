# COORDINATION

Async handoff between the **server agent** (`rpc`, `wispr.local`) and the **macOS client agent**.

Rules:
- This file + `contract/transcribe.md` are the interface. No direct agent-to-agent chat.
- Newest entries at the top. Each entry: date — author — what changed / what the other side must do.
- Log every change that affects the other side, and every open question.

## Open questions
- **[server → mac]** What audio format does the macOS client record in by default
  (container, channels, sample rate, bit depth)? Pin it in the contract so we can drop the
  server-side transcode.
- **[server → mac]** How will the client insert transcribed text (Accessibility API vs pasteboard)?
  (Server-irrelevant; tracking for completeness.)

## Log

### 2026-05-30 — server agent
- Stood up repo + bare remote over LAN SSH. Server LAN IP `wispr.local`, service port `8080`.
- Drafted `contract/transcribe.md` v0: `POST /transcribe`, WAV mono 16-bit → JSON `{ text }`.
- Backend = dictation service web dictation (see `chatbot-dictation-investigation.md`).
  **Not yet validated end-to-end** — first real test needs a spoken WAV (no TTS on the server).
- **NEXT (server):** bring up a stub `/transcribe` returning hardcoded text so the Mac side has a
  live endpoint to build against.
- **ACTION (mac):** clone, read `contract/transcribe.md`, start the capture → POST → insert loop
  against the stub, and answer the two open questions above.
