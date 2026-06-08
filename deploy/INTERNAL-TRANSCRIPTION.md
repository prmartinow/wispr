# Internal transcription service (concurrent lanes)

The wispr backend is a **transcription service**: it turns audio into text by driving dictation service's web
"dictate" feature through Chromium + a PulseAudio virtual mic. It serves two clients concurrently:

- **The macOS frontend** — live streaming dictation over `WS /v1/stream`, always on **lane 0**
  (reserved; never blocked by internal load).
- **Other RPC services** — batch `POST /transcribe`, fanned out across an **internal lane pool**.

## How a lane works

Each lane is a fully isolated dictation worker:

| Lane | CDP port | Virtual mic | Profile | Role |
|---|---|---|---|---|
| 0 | 9223 | `virtmic` (`PULSE_SOURCE=virtmic_in`) | `wispr-service-profile` | live streaming frontend |
| 1..N | 9223+k | `virtmic{k}` (`PULSE_SOURCE=virtmic{k}_in`) | `wispr-lane-{k}-profile` | batch pool |

Mic isolation is via **`PULSE_SOURCE` per Chromium instance** (with `--use-fake-ui-for-media-stream`
the browser always captures its *default* source, and `PULSE_SOURCE` makes that default the lane's own
`virtmic{k}` — so concurrent lanes never cross-talk). Lanes are tiled non-overlapping (470×530) on the
`:95` display. Lane count = `WISPR_LANES` in [`lanes.env`](lanes.env) (currently 7 internal + lane 0).

`server/dictate.js` dispatches each `/transcribe` to a free lane (`acquireLane`); when all are busy it
returns **409 `busy`**. Streaming stays on lane 0. `WISPR_LANES=0` ⇒ legacy single-backend behavior.

## Calling it (internal services on the RPC)

Auth is **mutual TLS + bearer token**. Use host **`wispr.local`** or `rpc` (the server cert SAN — NOT
`127.0.0.1`). Any audio format ffmpeg can decode is accepted (transcoded to 48 kHz/mono server-side).

```sh
curl --cacert ~/.wispr/mtls/ca.crt \
     --cert  ~/.wispr/mtls/wispr-internal-client.crt \
     --key   ~/.wispr/mtls/wispr-internal-client.key \
     -X POST https://wispr.local:8443/transcribe \
     -H "Authorization: Bearer $WISPR_BEARER_TOKEN" \
     -F audio=@clip.wav
# -> {"text":"...","engine":"dictation-service","duration_ms":...,"audio_duration_ms":...}
```

The internal client cert is a **dedicated identity** (`wispr-internal-ca` → `wispr-internal-client`),
separate from the mac client and independently revocable. Provisioned by
[`setup-internal-mtls.sh`](setup-internal-mtls.sh); pinned in `MTLS_CLIENT_CERT_SHA256`.

## Operating

- Provision / refresh everything: `deploy/install.sh` (idempotent).
- Re-provision lean lane profiles: `systemctl --user stop wispr-lane@{1..7}` → `deploy/setup-lanes.sh`
  → `systemctl --user start wispr-lane@{1..7}` (clones exclude caches/extensions → ~52 MB each).
- ⚠️ **Never `restart wispr-virtmic` alone** — running Chromium caches its device list and loses the
  mic. The browser/lane units are `PartOf=wispr-virtmic.service` so they restart with it; if you
  reload mics manually, also `systemctl --user restart wispr-browser wispr-lane@{1..7}`.
- Lane count: edit `WISPR_LANES` in `lanes.env`, then re-run `install.sh` (or enable/disable
  `wispr-lane@k` units + `systemctl --user restart wispr-server`).
