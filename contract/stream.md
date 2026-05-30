# Contract: `WS /v1/stream` — streaming dictation v0 (DRAFT, proposed)

Owner: **server agent** to implement; **mac agent** builds the client side once the stub echoes
`start`/`stop` and returns a `final`. Batch `POST /transcribe` (see `transcribe.md`) stays as-is.

## Why
Today the client records the whole clip, uploads it, and the server plays it into the dictation
mic **in real time** — so the user waits ≈ **clip length + ~7 s** *after* they stop. By feeding
audio to the mic **as it's spoken**, dictation transcribes live; when the user stops, only the tail
remains → **latency after stop ≈ 5–10 s regardless of clip length**, and we can show **live partials**.

## Transport
- **WebSocket** at `GET /v1/stream` (HTTP Upgrade) on the same `:8090` listener.
- **Auth:** `Authorization: Bearer <token>` on the upgrade request (client sends it as a handshake
  header). Reject the upgrade with 401 if missing/invalid.
- Serialized server-side (one composer + one virtmic), same as batch.

## Messages
Client → server:
1. **start** (text/JSON), first frame:
   ```json
   { "type": "start", "format": { "codec": "pcm_s16le", "rate": 48000, "channels": 1 }, "lang": "en" }
   ```
2. **audio** (binary frames): raw **PCM s16le, 48 kHz, mono**, ~100 ms per frame, sent at capture
   pace (naturally ~real time). No WAV header — just PCM samples.
3. **stop** (text/JSON), last frame: `{ "type": "stop" }`

Server → client:
- **partial** (optional, 0+): `{ "type": "partial", "text": "…current composer text…" }`
- **final** (exactly one, after `stop`): `{ "type": "final", "text": "…", "duration_ms": 1234 }`
- **error**: `{ "type": "error", "code": "…", "message": "…" }`
  (codes reuse `transcribe.md`: `unauthorized`, `bad_request`, `backend_unavailable`, `transcription_timeout`.)

## Server behavior (suggested, mirrors dictate.js)
1. On **start**: clear `#prompt-textarea` → click `Start dictation` → open a live pipe into the
   virtmic, e.g. `pacat --raw --format=s16le --rate=48000 --channels=1 --device=virtmic` reading from
   the fd you write each incoming audio frame to (real-time playback as frames arrive).
2. While streaming: optionally scrape `#prompt-textarea` every ~500 ms → send `partial`.
3. On **stop**: close the pipe, wait a short tail (~1.5 s), click `Submit dictation`, scrape the
   final `#prompt-textarea`, send `final`, clear the composer. **Never send the message.**
4. Idle/abandoned stream (socket closed without `stop`): cancel dictation, clear composer, free the mic.

## Timing / robustness
- Client sends at real-time pace (it's live capture); if frames arrive faster, `pacat` buffers.
- Heartbeat: WS ping/pong (~15 s) so a dropped client frees the composer/mic.
- **Fallback:** if the upgrade fails or the server doesn't support `/v1/stream`, the client uses
  batch `POST /transcribe`. Both paths return the same `{text}`.

## Open questions → `../COORDINATION.md`
- Does dictation service dictation cap a single live session's duration? (Batch handled 81 s fine.)
- Partial-scrape cadence vs. load on the page — tune server-side.
