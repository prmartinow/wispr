# Contract: `POST /transcribe`

Batch transcription endpoint. The streaming contract in `stream.md` is the
preferred path for live dictation; batch remains available for fallback and
bulk file transcription.

- **Base URL:** deployment-configured HTTPS endpoint.
- **Auth:** required client certificate plus `Authorization: Bearer <token>`.
- **Token storage:** private server env file, never committed.

## Request

```http
POST /transcribe
Authorization: Bearer <token>
Content-Type: multipart/form-data

audio = <WAV file, binary>
```

Audio requirements:

- WAV / RIFF container.
- Mono.
- 16-bit PCM.
- 48 kHz sample rate.
- Duration at or below the configured batch limit, default 10 minutes.

The server streams the upload to a private temp file, validates the WAV header
and duration, and feeds it to the backend through the virtual microphone.

## Response

```json
{
  "text": "transcribed text",
  "engine": "dictation-service",
  "duration_ms": 0,
  "audio_duration_ms": 0
}
```

`duration_ms` is wall-clock server time. `audio_duration_ms` is the validated
WAV duration.

## Errors

```json
{ "error": { "code": "unauthorized", "message": "..." } }
```

| Status | code | When |
|---|---|---|
| 401 | `unauthorized` | missing or invalid bearer token |
| 400 | `bad_request` / `invalid_audio` | missing, empty, malformed, or wrong-format audio |
| 409 | `busy` | the needed backend lane is already in flight |
| 413 | `audio_too_large` | upload or duration exceeds the configured cap |
| 415 | `unsupported_media_type` | body is not multipart/form-data |
| 503 | `backend_unavailable` | browser or dictation service is not ready |
| 504 | `transcription_timeout` | dictation did not settle in time |

## Health

```http
GET /healthz
Authorization: Bearer <token>
```

`/healthz` returns a JSON snapshot. `/readyz` returns `200` only when browser,
dictation-service session, virtual mic, and internet probes are ready; otherwise
it returns `503` with the same shape.

Relevant fields:

- `browser`: `up|down`
- `dictationService`: `ready|logged_out|loading|unreachable|blocked|no-tab`
- `mic`: `ok|missing`
- `internet`: `ok|down`
- `busy`: `true|false`
- `lastDictation`: last result since server boot, or `null`

Clients should probe `/readyz` before starting a recording, save locally when
the backend is unavailable, and avoid blind retry when the dictation service is
logged out or blocked.
