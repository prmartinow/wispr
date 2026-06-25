# Contract: WebSocket `/v1/stream`

Live streaming dictation endpoint. Audio is fed into the backend while the user
records, so stop-to-final latency is mostly backend finalization time instead
of full clip length.

- **URL:** deployment-configured `wss://.../v1/stream`.
- **Auth:** required client certificate plus `Authorization: Bearer <token>` on
  the upgrade request.
- **Concurrency:** one live stream on lane 0; batch requests use internal lanes
  when configured.

## Protocol

Client to server:

1. Text JSON: `{"type":"start"}`.
2. Binary frames: raw PCM, s16le, 48 kHz, mono, roughly capture-paced.
3. Text JSON: `{"type":"stop"}`.

Server to client:

- `{"type":"ready"}` - dictation started; send audio now.
- `{"type":"final","text":"...","duration_ms":N}` - transcript is complete.
- `{"type":"error","code":"...","message":"..."}` - terminal error.

Known error codes include `busy`, `backend_unavailable`,
`transcription_error`, `bad_request`, `idle_timeout`, and `max_duration`.

The server rejects oversized frames, excessive pre-ready audio, sockets that
never send `start`, and streams over the configured maximum duration. If the
client disconnects before `stop`, the server aborts cleanly and frees the mic.

Clients should ignore unknown message types for forward compatibility.
