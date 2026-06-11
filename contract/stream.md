# Contract: WS `/v1/stream` — live streaming dictation (v0, IMPLEMENTED)

Lower-latency alternative to batch `POST /transcribe`. Audio is fed into the dictation mic **live as
you record**, so after the user stops only the tail + dictation service's finalize (~7 s) remains — latency
after stop is roughly constant regardless of clip length. Batch `POST /transcribe` stays for
compatibility. Jointly owned; change via commit + a `../COORDINATION.md` entry.

- **URL (LAN):** `wss://wispr.local:8443/v1/stream`
- **URL (remote):** `wss://wispr.p12w.xyz/v1/stream`
- **Auth:** required client cert (mTLS) plus `Authorization: Bearer <token>` header on the upgrade
  request (bad/missing → `401`, upgrade refused). Same token as batch (`server/.env`).
- Only **one** stream or batch request runs at a time (single composer/mic). A second `start` while
  busy → `{"type":"error","code":"busy"}`.

## Protocol
Client → server:
1. Text (JSON) **`{"type":"start"}`** — opens dictation. Extra fields (e.g. `format`, `lang`) are
   accepted and ignored; the server assumes the format below.
2. **Binary frames** = raw PCM, **s16le, 48000 Hz, mono** (no WAV header), ~100 ms/frame at ~capture
   pace. The server buffers a small bounded amount before `ready`; the client also caps its
   pre-ready buffer.
3. Text (JSON) **`{"type":"stop"}`** — finalize.

Server → client:
- `{"type":"ready"}` — dictation started; stream audio now.
- `{"type":"final","text":"…","duration_ms":N}` — the transcript; server then closes.
- `{"type":"error","code":"busy|backend_unavailable|transcription_error|bad_request|idle_timeout|max_duration","message":"…"}`.
  (`idle_timeout`: no audio for ~25 s after `ready` → mic freed; `max_duration`: stream exceeded 10 min.)
  The server also rejects oversized frames, excessive pre-ready audio, and sockets that never send
  `start`, so a bad client cannot hold unbounded memory before dictation is ready. A full stream is
  capped at 10 minutes.

If the client disconnects before `stop`, the server aborts cleanly (cancels dictation, frees the
mic) — no stuck composer. Clients should ignore unknown message types (forward-compat).

## Verified
16 s clip streamed live in 100 ms chunks → **after-stop latency ~8.5 s** (vs ~31 s batch for the same
clip), full accurate transcript. Latency after stop is ~constant regardless of clip length.

## Notes
- Format matches what the client already records (mono/16-bit/48 kHz) — just send the raw PCM, drop
  the WAV header. Keep batch `POST /transcribe` as the fallback path.
- **Partials: not in v0.** `#prompt-textarea` stays empty *during* dictation and only fills on submit,
  so a `{"type":"partial"}` stream isn't feasible yet. If that changes it'll be added as an optional
  server→client message.
