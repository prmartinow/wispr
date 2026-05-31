# Contract: `POST /transcribe` — v0 (DRAFT)

Jointly owned. Change only via commit + an entry in `../COORDINATION.md`.

- **Base URL (LAN):** `http://wispr.local:8090`  ·  *(moved off 8080 — reserved for Nextcloud on this box)*
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

**What the macOS client actually sends** (resolved 2026-05-30 — was an open question):
RIFF WAV, **mono, 16-bit PCM, 48000 Hz**, written by `AVAudioRecorder`. This is inside the
accepted set above **and** matches the server's validated fake-mic clip
(`ffmpeg -ac 1 -ar 48000 -sample_fmt s16`), so the server can feed the upload straight to
Chromium's `--use-file-for-fake-audio-capture` with **no transcode**.

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
GET /healthz → 200  (always; read the fields to decide what to do)
  { "ok": true, "engine": "dictation-service",
    "browser":  "up|down",                          // service Chromium (CDP) reachable
    "dictationService":  "ready|logged_out|loading|unreachable|no-tab",  // backend session state
    "mic":      "ok|missing",                       // PulseAudio virtual mic present
    "internet": "ok|down",                          // server's own egress
    "busy":     true|false,                         // a transcription is in flight (LIVE, not cached)
    "lastDictation": {"ok":true,"ms":1234,"at":"<iso>"} | null,  // last transcription result since boot
    "checkedAt":"<iso>" }                            // snapshot age (monitor runs ~every 20s)

GET /readyz  → 200 if browser=up & dictationService=ready & mic=ok & internet=ok, else 503 (same body)
```
**Client guidance:** probe `/healthz` to pick a reachable endpoint (LAN vs remote) and to decide
send-vs-buffer. `dictationService:"logged_out"` → backend needs re-login (don't retry blindly).
`internet:"down"` or unreachable → buffer locally and retry when `/readyz` is 200.

## Backend notes (server-internal — client must not depend on these)
- Transcription = dictation service web **dictation** driven through Chromium. See
  `../chatbot-dictation-investigation.md`. Consequences the client should expect:
  **latency ≈ clip length**, and requests are **serialized** (one composer).
- Swappable to local Whisper later **without changing this contract**.

## Resolved
- Native macOS record format → pinned above: WAV / mono / 16-bit PCM / 48000 Hz. No transcode needed.
- Text insertion (client-internal, server-irrelevant): pasteboard + synthesized ⌘V via
  CGEvent; requires the app to hold macOS Accessibility permission.

New questions go to `../COORDINATION.md`.
