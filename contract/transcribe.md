# Contract: `POST /transcribe` — v0 (DRAFT)

Jointly owned. Change only via commit + an entry in `../COORDINATION.md`.

- **Base URL (LAN):** `https://wispr.local:8443`
- **Base URL (remote):** `https://wispr.p12w.xyz`
- **Auth:** required client cert (mTLS) plus `Authorization: Bearer <token>`.
  The token lives in `server/.env` on the server (gitignored). Fetch over SSH; never commit it.

## Request
```
POST /transcribe
Authorization: Bearer <token>
Content-Type: multipart/form-data
  audio = <WAV file, binary>      # form field name: "audio"
```
Audio:
- Container: WAV (RIFF)
- Channels: mono
- Sample format: 16-bit PCM
- Sample rate: 48000 Hz
- Length: ≤ 10 minutes

The macOS client sends RIFF WAV, **mono, 16-bit PCM, 48000 Hz**. The server streams the upload to a
private temp file, validates the WAV header/duration before playback, and then feeds it to the
PulseAudio virtual mic.

## Response — 200 `application/json`
```json
{ "text": "transcribed text", "engine": "dictation-service", "duration_ms": 0, "audio_duration_ms": 0 }
```
`duration_ms` is wall-clock server time; `audio_duration_ms` is the validated WAV duration.

## Errors — `application/json`
```json
{ "error": { "code": "unauthorized", "message": "..." } }
```
| Status | code | When |
|---|---|---|
| 401 | `unauthorized` | missing/invalid bearer token |
| 400 | `bad_request` / `invalid_audio` | missing/empty/malformed or wrong-format audio |
| 409 | `busy` | one dictation is already in flight |
| 413 | `audio_too_large` | upload/duration exceeds the 10-minute cap |
| 415 | `unsupported_media_type` | body is not multipart/form-data |
| 503 | `backend_unavailable` | Chromium/dictation not ready |
| 504 | `transcription_timeout` | dictation didn't settle in time |

## Health
```
GET /healthz → 200  (when authorized; read the fields to decide what to do)
Authorization: Bearer <token>
  { "ok": true, "engine": "dictation-service",
    "browser":  "up|down",                          // service Chromium (CDP) reachable
    "dictationService":  "ready|logged_out|loading|unreachable|no-tab",  // backend session state
    "mic":      "ok|missing",                       // PulseAudio virtual mic present
    "internet": "ok|down",                          // server's own egress
    "busy":     true|false,                         // a transcription is in flight (LIVE, not cached)
    "lastDictation": {"ok":true,"ms":1234,"at":"<iso>"} | null,  // last transcription result since boot
    "checkedAt":"<iso>" }                            // snapshot age (monitor runs ~every 20s)

GET /readyz  → 200 if browser=up & dictationService=ready & mic=ok & internet=ok, else 503 (same body)
Authorization: Bearer <token>
```
Bad or missing token returns `401 unauthorized`, same as `/transcribe`.
**Client guidance:** probe `/healthz` to pick a reachable endpoint (LAN vs remote) and to decide
send-vs-buffer. `busy:true` means save locally and retry later; do not queue long work server-side.
`dictationService:"logged_out"` → backend needs re-login (don't retry blindly).
`internet:"down"` or unreachable → buffer locally and retry when `/readyz` is 200.

## Backend notes (server-internal — client must not depend on these)
- Transcription = dictation service web **dictation** driven through Chromium. See
  `../chatbot-dictation-investigation.md`. Consequences the client should expect:
  **latency ≈ clip length**, and requests are **serialized** (one composer, no long queue).
- Swappable to a local STT engine later **without changing this contract**.

## Resolved
- Native macOS record format → pinned above: WAV / mono / 16-bit PCM / 48000 Hz. No transcode needed.
- LAN transport → direct HTTPS/mTLS on `wispr.local:8443`.
- Text insertion (client-internal, server-irrelevant): pasteboard + synthesized ⌘V via
  CGEvent; requires the app to hold macOS Accessibility permission.

New questions go to `../COORDINATION.md`.
