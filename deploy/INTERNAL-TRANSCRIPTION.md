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

## Validation findings (carbon-upstream snippets, 2026-06-09)

Tested with `carbon-upstream-v1/demo-artifacts/review-human/audio-snippets` (6 scenes, WAV/16k/mono,
4–13 s clips), `aligned_text` as reference.

- **Concurrency**: 6 clips fired in parallel over mTLS completed in **16 s** total (serial ≈ 70 s);
  earlier a full **7-lane** run did 7 in 20 s. Each lane returns ONLY its own clip — zero cross-talk.
- **Latency**: server-side ≈ `audio_duration + ~6–7 s` (dictation service's transcription dominates). A lane's
  first request after a restart is slower (cold, no cache).
- **Accuracy**: essentially **verbatim at the word level** — every content word correct across the set.
  Deviations are limited to:
  - **Technical proper-noun casing/spacing** (the main class): `Jupiter Swap`→`JupiterSwap`,
    `ClickHouse Play`→`ClickHousePlay`, `cargo run`→`Cargo Run`, `Carbon-side`→`carbon side`,
    `Token Program`→`token program`. It's dictation service *general* dictation, not domain-tuned, so it guesses
    casing/word-splits for project identifiers. **Callers needing exact identifiers should post-normalize.**
  - Minor punctuation/casing differences (added commas), and occasionally a small inserted word
    (e.g. "configuration lives" → "configuration files live").
  - Some clips contain more speech than their reference utterance → transcript legitimately longer.
- **Format**: originally 48 kHz-only; now any ffmpeg-decodable input is accepted (transcoded server-side).
