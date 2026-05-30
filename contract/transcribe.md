# Contract: `POST /transcribe` — v0 (DRAFT)

Jointly owned. Change only via commit + an entry in `../COORDINATION.md`.

- **Base URL (LAN):** `http://wispr.local:8080`
- **Auth:** `Authorization: Bearer <token>` — token lives in `server/.env` on the server
  (gitignored). Fetch over SSH; never commit it.

## Request
```
POST /transcribe
Authorization: Bearer <token>
Content-Type: multipart/form-data
  audio = <WAV file, binary>      # form field name: "audio"
```
Audio (v0 target — server normalizes via ffmpeg, so some slack is fine):
- Container: WAV (RIFF)
- Channels: mono
- Sample format: 16-bit PCM
- Sample rate: 16000 or 48000 Hz
- Length: ≤ 30 s for the prototype

## Response — 200 `application/json`
```json
{ "text": "transcribed text", "engine": "stub", "duration_ms": 0 }
```
`engine` is `"stub"` until the dictation driver lands, then `"dictation-service"`.

## Errors — `application/json`
```json
{ "error": { "code": "unauthorized", "message": "..." } }
```
| Status | code | When |
|---|---|---|
| 401 | `unauthorized` | missing/invalid bearer token |
| 400 | `bad_request` | missing/empty/undecodable audio |
| 415 | `unsupported_media_type` | body is not WAV |
| 503 | `backend_unavailable` | Chromium/dictation not ready |
| 504 | `transcription_timeout` | dictation didn't settle in time |

## Health
```
GET /healthz → 200 { "ok": true, "engine": "stub|dictation-service", "browser": "up|down" }
```

## Backend notes (server-internal — client must not depend on these)
- Transcription = dictation service web **dictation** driven through Chromium. See
  `../chatbot-dictation-investigation.md`. Consequences the client should expect:
  **latency ≈ clip length**, and requests are **serialized** (one composer).
- Swappable to local Whisper later **without changing this contract**.

## Open questions → `../COORDINATION.md`
- Native record format on macOS (container/channels/rate/bit-depth)? Pin it to avoid a transcode.
- Default sample rate from `AVAudioRecorder`?
