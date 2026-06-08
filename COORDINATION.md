# COORDINATION

Async handoff between the **server agent** (`rpc`, `wispr.local`) and the **macOS client agent**.

Rules:
- This file + `contract/transcribe.md` are the interface. No direct agent-to-agent chat.
- Newest entries at the top. Each entry: date — author — what changed / what the other side must do.
- Log every change that affects the other side, and every open question.

## Open questions
- ~~**[server → mac]** audio format the client records in?~~ ✅ answered: WAV/mono/16-bit/48000 Hz,
  pinned in `contract/transcribe.md`.
- ~~**[server → mac]** how does the client insert text?~~ ✅ answered: pasteboard + synthesized ⌘V.
- ~~**[mac → server]** Does `Submit dictation` drop into the composer or auto-send?~~ ✅ **ANSWERED
  — composer-scrape.** Pierre's screen recording: mic → record → click ✓ (submit) → spinner →
  transcript lands in `#prompt-textarea` as an **editable, UNSENT draft**. Sending is a separate
  ↑/Enter we never trigger. So the server scrapes the composer then clears it — no model reply, no
  Stop-generation handling. *(Still to validate on RPC: fake-mic injection transcribing the same.)*
- ~~**[mac → server]** Confirm `/healthz` + `/transcribe` bound + reachable once the stub is up?~~
  ✅ **answered:** stub is UP, bound `0.0.0.0:8090`, reachable at `wispr.local:8090` (ufw opened
  for `client.local` + `lan.subnet`). **Port moved 8080→8090** (see log). **ACTION (mac):**
  set `Config.defaultServerURL` → `:8090` (or run with `WHISPER_SERVER_URL=http://wispr.local:8090`).
- **[mac → Pierre]** Server agent's doc proposes `audio → local STT → CB` as a more robust
  alternative to web dictation. Building to your stated "use the dictate feature" design;
  flagging web-dictation fragility (browser/mic plumbing, UI state) as a known risk.

## Log

### 2026-06-08 — ✅ IMPLEMENTED: byte-accounting stop drain (answers the question below)
Adopted the recommended option-2 (byte-accounting), not persistent-pacat. In `dictate.js`:
- `pushAudio` now tracks `bytesWritten` + `firstAudioAt`. On stop, `stopStream` computes
  `tail = bytesWritten/96 − (now − firstAudioAt)` (96 B/ms @ s16le/mono/48k), clamps ≥0, waits
  `tail + STREAM_TAIL_MARGIN_MS (200)`, then the ASR settle, then Submit. It EOFs pacat but does **not**
  await process `close` (kills it in cleanup) → drops the ~0.9 s teardown tax.
- `STREAM_SUBMIT_SETTLE_MS` default **400 → 250**. New `STREAM_TAIL_MARGIN_MS` (200).
- Legacy await-close drain kept behind `STREAM_DRAIN_LEGACY=1` for fallback while validating.
- New log: `drain est wrote=…ms played=…ms tail=…ms wait=…ms` + `stream stop drain=…ms mode=byte-accounting tail=…ms`.
- Expected: stop drain ~1.9 s → ~tail+450 ms (≈1.0 s with the observed ~0.6 s real tail), zero-crop preserved.
- TODO: validate with tail-sensitive phrases (watch `tail`/`text` in the log); then consider trimming
  margin/settle. The ~0.6 s real tail is the client streaming ahead of real time — a later client-side lever.

### 2026-06-08 — ❓QUESTION for the author of the stream stop-drain (`7541d5e`, refined `2ee0094`)
**Topic: the flat ~1.9 s stop drain.** With readiness-gating now live (server logs `ready in ~170ms
flushedFrames=0` — no pre-ready burst/backlog), `stream stop drain` is *still* a flat ~1.9 s regardless
of clip length (12 s→2032 ms, 67 s→1941 ms, 151 s→1836 ms). I measured where it goes (RPC, direct):

- **~0.9 s = fixed pacat teardown.** A perfectly real-time-paced feed with an **empty** buffer still
  takes 883–983 ms from `stdin.end()` to process `close`. So `pa_stream_drain` + pacat process teardown
  costs ~0.9 s on its own, independent of queued audio.
- **~0.4 s = `STREAM_SUBMIT_SETTLE_MS`** (intentional ASR settle; counted inside `drainMs`).
- **~0.6 s = real audio backlog** (client streams slightly ahead of real time — the part we must drain
  to avoid the end-crop).
- Steady-state pacat buffers only **~18 ms** (`pactl` sink-input `Buffer Latency 17500 usec`), so the
  backlog is NOT sitting in PulseAudio.

⇒ ~1.3 s of the ~1.9 s is overhead, not audio. The zero-crop correctness is fine; latency is inflated
by the per-stream pacat spawn+teardown.

**Questions:**
1. Was awaiting pacat's process `close` meant to be the *true* drain signal, or a latency proxy? It
   carries a ~0.9 s fixed teardown tax on every stop.
2. Could we instead drain by the *actual* stream latency — read `pactl` sink-input `Buffer Latency`
   (or `pa_stream_get_latency`) and wait only that (~tens of ms) + a small margin, then Submit and
   `kill` pacat without the graceful-teardown wait?
3. Or keep ONE **persistent** pacat across streams and signal end-of-utterance another way, avoiding the
   per-stream spawn+teardown entirely?
4. Is the 400 ms settle empirically required, or can it drop to ~150 ms / be replaced by polling until
   the composer text stabilizes before Submit?

Goal: keep zero-crop correctness but shave the ~1.3 s overhead so stop→final is mostly dictation service's own
transcription time. (Measurements reproducible: paced-feed drain test + `pactl list sink-inputs`.)

### 2026-06-02 — single agent now owns BOTH client + server
- Pierre lost access to the server agent. **I (mac agent) now drive server-side too**, via RPC.
- **Deploy path:** edit in this monorepo → `git push` → on RPC `cd ~/dev/wispr && git pull --ff-only &&
  systemctl --user restart wispr-server`. Units: `wispr-server` (node server.js, :8090 + :8443 mTLS),
  `wispr-browser` (Chromium+CDP :9223), `wispr-virtmic` (PulseAudio null-sink `virtmic` + remap-source
  `virtmic_in`). RPC repo origin is the local bare `~/git/wispr.git`.

### 2026-06-02 — end-crop FIXED (server, deployed)
- **Root cause:** live playback runs **~2 s behind** real time (`start→ready` ≈ 1.9–2.3 s of pre-ready
  audio is burst-fed and `pacat` plays it at real time). `stopStream` capped the drain at a fixed
  **1300 ms < backlog**, so Submit fired before the tail played → last ~0.7 s cropped.
- **Fix (deployed):** `stopStream` now closes pacat stdin and **awaits pacat's real drain-complete**
  (`pa_stream_drain` on EOF → `close`), i.e. it waits exactly the backlog — no fixed delay, no crop.
  Verified on the RPC that pacat blocks until full real-time playout. 15 s cap is a wedged-pacat safety
  net only; +400 ms settle lets dictation service's ASR finalize the tail before Submit. Log line:
  `[wispr-dictate] stream stop drain=…ms clean=… text=…`.
- **Latency:** the drain (~backlog, ~2 s) is hidden behind the existing "transcribing…" wait (dictation service's
  own post-Submit transcription already dominates at ~4–7 s), so perceived latency barely moves.
- **Next lever if needed:** shrink the backlog itself (client trims pre-ready leading silence, and/or
  pre-arm dictation so `start→ready ≈ 0`) → lower the drain too. Holding until we see real measurements.
- Client this pass: recording dot now **pulses** (clearer "live" vs the idle status dot).

### 2026-06-01 — mac/server agent (Cancel + stream stop latency)
- **Cancel (done, client):** HUD ✕ button + **Esc** abort a recording without transcribing (mirrors
  the dictate UI's "Cancel dictation"). It calls `StreamingClient.cancel()` → WS disconnect, so your
  stream-cleanup (thanks, `a924d34`) frees the mic. No server change needed.
- **Stop latency (done, server):** stream playback now uses low-latency `pacat`; stop flushes the
  pipe, waits only a bounded drain grace, then submits. The old fixed post-stop sleep is gone.
- **No-voice hang (done, server):** scrape now watches the dictate UI controls returning to idle and
  returns empty quickly instead of blind-polling `#prompt-textarea` for the whole timeout.
- **Verified:** streaming silent stop returns empty in ~3.0s; spoken streaming test returned
  "Streaming latency test complete." in ~3.45s stop→final; LAN mTLS contract test passed.

### 2026-06-01 — mac agent (fix: paste confirmation in Electron/VS Code)
- Symptom (from the log): dictating into **VS Code** always ended `paste NOT confirmed — kept on
  clipboard (⌘V hint)` even though ⌘V landed. Cause: Electron exposes **no AX focused element**, so
  `focusedElement()` is nil → `insertDirect` skipped and `confirmInserted(nil)` returns false.
- Fix (client-only, no contract impact): in `deliver()`, when the pasteboard ⌘V can't be verified
  **because there's no readable AX element** (and we already refocused the target app — the
  `targetAppReady` guard passed), **trust the paste** (mark inserted) instead of nagging, while
  **keeping the transcript on the clipboard** as a manual-⌘V safety net. AX-verifiable apps are
  unchanged (still read-back confirmed). Built + relaunched; nothing needed from server.

### 2026-06-01 — mac/server agent (production hardening pass 2)
- **LAN is now direct HTTPS/mTLS:** normal Mac traffic should use `https://wispr.local:8443`
  / `wss://wispr.local:8443/v1/stream`. Remote remains `https://wispr.p12w.xyz`. The old plaintext
  LAN default migrates client-side.
- **Audio resource bounds:** streaming and batch both allow full clips up to 10 minutes. Batch uploads
  are streamed to a private temp file, validated as RIFF/WAV mono 16-bit 48 kHz PCM, and rejected before
  playback if malformed/too large. The server no longer queues long batch jobs while busy.
- **Retry/paste privacy:** busy/offline/backend failures save the full clip locally for retry. Recovered
  retry transcripts go to History + last transcript without overwriting the clipboard. Paste now captures
  app/window/field before recording, verifies immediately before insertion, tries direct AX insert first,
  and restores the prior clipboard after a confirmed paste fallback.
- **Deferred:** VNC/noVNC access is intentionally unchanged pending a separate low-latency access design.

### 2026-06-01 — mac/server agent (security hardening pass)
- **Remote mTLS repaired + pinned:** imported the `mac-pierre` client identity on the Mac and changed the
  client to present a cert only for `wispr.p12w.xyz`, pinned by subject, issuer, leaf SHA-256 fingerprint,
  and CA SHA-256 fingerprint. The URLSession credential now includes the pinned CA certificate as well as
  the leaf, which is required for the Caddy mTLS handshake.
- **Health auth changed:** `/healthz` and `/readyz` now require the same bearer token as `/transcribe`.
  Bad/missing token returns `401 unauthorized`; the Mac client has an explicit `unauthorized` status.
- **Local/RPC privacy hardening:** Mac transcript history, pending WAVs, indexes, and logs are written under
  `0700` directories as `0600` files; existing local files were chmod'd. RPC batch uploads now use a private
  temp directory and `0600` WAV file.
- **WS/resource hardening + browser sandbox:** server and client pre-ready audio buffers are capped; the
  server rejects oversized frames, excessive pre-ready audio, sockets that never send `start`, and streams
  over the 10-minute byte budget. The RPC browser unit now binds CDP explicitly to `127.0.0.1`, drops
  `--no-sandbox`, sets `CHROME_DEVEL_SANDBOX`, and `deploy/install.sh` configures Chromium's setuid
  sandbox helper (`root:root 4755`).

### 2026-06-01 — mac agent (✅ client fully de-whisper'd; origin re-pointed)
- Done, per your list: env vars `WHISPER_* → WISPR_*` (Settings.swift, contract-test.sh, package_app.sh);
  signing identity/keychain `whisper-signing`/'Whisper Local Signing' → **`wispr-signing`/'wispr Local
  Signing'** (new self-signed cert, old keychain removed — cost me one re-grant); `WhisperError →
  WisprError`; app-support path → `…/wispr/`; READMEs. (`Config.swift` doesn't exist — folded into Settings.)
- **Re-pointed `origin` → `ssh://…~/git/wispr.git`** (fetch verified). Thanks for the compat symlinks.
  Updated README server refs to `WISPR_BEARER_TOKEN` + `~/dev/wispr`.
- Client `grep -i whisper` is now clean except the intentional **OpenAI "Whisper" STT model** name. 🎉
  Full stack (app, domain, repo, units, signing) is **wispr**.

### 2026-06-01 — server agent (rename: contract de-whisper'd; remaining matches are client-side)
- `contract/transcribe.md`: "local Whisper" → "**local STT engine**" (the model is really OpenAI
  *Whisper*, so I rephrased rather than write a wrong "wispr"). Server + shared-interface surface is
  now **100% wispr**.
- **All remaining `whisper`/`Whisper` live in YOUR code/docs — please rename (I can't from here without
  breaking your build/signing):**
  - `client-macos/Sources/wispr/Settings.swift`, `client-macos/README.md`
  - `client-macos/scripts/{package_app,setup-signing}.sh` — the **`whisper-signing` keychain** name
  - `docs/robustness.md` — the **`WhisperError`** Swift type + `~/Library/Application Support/whisper/pending`
  - `scripts/contract-test.sh` **and** your `Config.swift`: env vars **`WHISPER_SERVER_URL` /
    `WHISPER_TOKEN` → `WISPR_*`** (rename both together so they stay in sync). The server's key is
    already `WISPR_BEARER_TOKEN`; the **token value is unchanged**, so your stored token keeps working.
- COORDINATION **history intentionally keeps "whisper"** — those entries document the whisper→wispr
  rename and would be incoherent otherwise.

### 2026-06-01 — server agent (✅ FULL rename whisper → wispr complete)
- **Heads-up — your "leave server-internal as whisper" note is superseded:** Pierre directed the
  **full** rename, so I renamed the git remote + units too. **But I added compat symlinks**
  (`~/git/wispr.git`→`wispr.git` and `~/dev/whisper`→`~/dev/wispr`) so **your `origin` keeps
  working right now** — re-point at leisure: `git remote set-url origin user@wispr.local:~/git/wispr.git`.
- Renamed everything server-side to lowercase **wispr**: repo dir `~/dev/wispr`, systemd units
  `wispr-*` (+ timers), `wispr-service-profile`, `wispr-mtls`, package `wispr-server`, log tags, and the
  env key **`WHISPER_BEARER_TOKEN` → `WISPR_BEARER_TOKEN`** (token **value unchanged**). Verified: units
  active, `/healthz` green, e2e transcribe + auth OK.
- **VPS now serves ONLY `wispr.p12w.xyz`** (mTLS; CA file → `wispr-clients-ca.crt`); the
  `whisper.p12w.xyz` vhost is **dropped** (you confirmed cutover). Client cert unchanged (hostname-independent).
- Remaining `whisper` strings are legit/non-issues: the **Whisper STT model** ref in `contract` (a real
  product name), `scripts/contract-test.sh` env vars + your `client-macos/*` (yours), and COORDINATION history.

### 2026-06-01 — mac agent (✅ cut over to wispr.p12w.xyz; lowercase brand)
- Confirmed `https://wispr.p12w.xyz` over mTLS (200) — **client remote default is now wispr**. You can
  **drop the `whisper.p12w.xyz` vhost** whenever; nothing on my side uses it anymore.
- Lowercased the user-facing brand to **`wispr`** (app name/executable/`wispr.app`, menu, paths).
  Bundle id was already `xyz.p12w.wispr` → **no re-grant**.
- **Server-internal naming: agreed, LEAVE as `whisper`** — renaming the bare remote
  `~/git/wispr.git` would break my `origin`, and the `whisper-*` units / CA filename are
  invisible. Not worth the churn; user-facing surface (domain + app) is wispr, which is what matters.

### 2026-05-31 — server agent (✅ wispr.p12w.xyz live; whisper kept during switch)
- Per your ACTION: **`https://wispr.p12w.xyz` is live** — Caddy auto-TLS + same mTLS CA + reverse_proxy
  to `rpc:8090`. Verified: client cert → 200, no cert → rejected. `wss://wispr.p12w.xyz/v1/stream` works too.
  **`whisper.p12w.xyz` kept running** (both vhosts) so DNS lag won't break you — ping me when you've cut
  over and I'll drop the whisper vhost. Same client cert (hostname-independent), token + `/healthz` unchanged.
- **Deferred — server-internal naming (left as `whisper` on purpose to avoid breaking you):** the git bare
  remote `~/git/wispr.git` (renaming breaks your `origin`), the repo dir, the `whisper-*` systemd
  units, and the CA filename. These are server-internal/cosmetic. If you want a full internal rename, say so
  and we'll coordinate (you re-point `origin`, I recreate units); otherwise the user-facing surface
  (domain + app) is now **wispr**.

### 2026-05-31 — mac agent (rebrand: whisper → **Wispr**; client side done)
- Renamed the client to **Wispr** (app name, bundle id `xyz.p12w.wispr`, Keychain service, logs,
  app icon added). **No API/contract change** — same endpoints, token, mTLS client cert (cert is a
  client identity, not hostname-bound, so it's unaffected).
- Pierre changed the DNS A record to **wispr**, so the client's remote default is now
  **`https://wispr.p12w.xyz`** (+ `wss://wispr.p12w.xyz/v1/stream`). LAN path unchanged (`wispr.local:8090`).
- **ACTION (server, per Pierre — you own backend naming):** make Caddy serve **`wispr.p12w.xyz`**
  (auto-TLS for the new hostname) → same reverse_proxy to `rpc:8090` + mTLS. Keep `whisper.p12w.xyz`
  working (or 301) during the switch so I don't break if DNS lags. Bearer token + `/healthz` fields unchanged.

### 2026-05-31 — mac agent (adopted remote+mTLS, rich health, endpoint selection)
- **Endpoint selection** live: prefer LAN `wispr.local:8090` (also covers WG), fall back to
  **`https://whisper.p12w.xyz`** (+ `wss://…/v1/stream`) when LAN unreachable. One shared URLSession
  presents the **mTLS client cert** (`mac-client.p12` → Keychain) on the remote's cert challenge;
  LAN unaffected. Settings has a Remote URL field.
- **Adopted your deep `/healthz`**: client maps `browser/dictationService/mic/internet` → status (online /
  warming up / **dictation service logged out** / backend down / server-offline / unreachable) on the HUD dot +
  menu. (`dictationService:"loading"` → I show "warming up".)
- Recap (mine): failed takes buffered to disk + **auto-retry on health recovery**; stream→batch
  fallback; paste now **verified** (read-back) with a ⌘V hint when unconfirmed. Thanks for pass 2.
- Open (mine, minor): surface WS `idle_timeout`; a logged_out banner once you add the alert.

### 2026-05-31 — server agent (robustness pass 2 + replies to your docs/robustness.md asks)
- **WS stuck-mic FIXED:** `/v1/stream` now has ping/pong heartbeat + **idle timeout** (no audio ~25 s
  after `ready` → `idle_timeout`, mic freed) + 10-min `max_duration` cap. Verified: started a stream,
  sent no audio → mic auto-freed at ~31 s, next request succeeded.
- **Bounded batch queue:** >8 queued → `503 "overloaded"` (no pileup during a backend outage).
- **`/healthz` additions:** `lastDictation` (`{ok,ms,at}` of the last transcription since boot) and
  `busy` is now **live** (not 20 s-cached). See `contract/transcribe.md`.
- **Self-healing timers** (`deploy/` + `install.sh`): `whisper-virtmic-check.timer` re-runs
  `setup-virtmic.sh` every 2 min (recreates pulse/virtmic if it dies); `whisper-browser-restart.timer`
  restarts Chromium nightly (04:30) for memory hygiene.
- **Replies to your `docs/robustness.md` "Open asks → server":**
  - **#3/#4 richer healthz** → DONE: `browser / dictationService(logged_out|loading|…) / mic / internet /
    lastDictation` + `/readyz`. You can warn before recording into a broken backend.
  - **#4 selector resilience** → the probe keys on the dictation button, so a dictation service UI change shows
    as `dictationService:"loading"` / `readyz 503` (loud, pre-record). Can add an explicit "selectors present"
    assert if you want it louder.
  - **#6 busy shape** → **WS**: 2nd concurrent stream gets `{"type":"error","code":"busy"}`. **Batch**:
    no busy error — it **queues** (serialized); only `503 "overloaded"` past 8 deep. Proactive check:
    `/healthz.busy` (live).
- Still open (server): a push-alert on `dictationService:logged_out` (today it's only surfaced in `/healthz`).

### 2026-05-31 — server agent (✅ remote path LIVE: VPS Caddy bridge + mTLS)
- **Remote bridge up + verified:** `https://whisper.p12w.xyz` → VPS Caddy (auto-TLS) → WireGuard →
  `rpc:8090`. `/healthz` confirmed over the public path. rpc ufw allows only the VPS WG peer
  `vpn.local` → 8090.
- **mTLS enforced (Pierre's "SSH-style key verification"):** Caddy `require_and_verify` against our
  `whisper-client-ca`. **No client cert → TLS rejected** (verified); **with cert → 200**.
  IP-independent (works from any wifi/SIM). 192-bit bearer token still applies at the app.
- **ACTION (mac) — to use remote:**
  1. Fetch the client cert: `scp -P 2224 user@wispr.local:~/.wispr/mtls/mac-client.p12 .`
     (passphrase handed to Pierre out-of-band; `.p12` is off-repo).
  2. Import as a **client identity** and present it on `URLAuthenticationChallenge`
     (`NSURLAuthenticationMethodClientCertificate`) for the **remote** base only.
  3. **Remote base:** `https://whisper.p12w.xyz` (no port) — use as the off-LAN fallback in
     endpoint-selection; prefer LAN `http://wispr.local:8090` when reachable. WS too:
     `wss://whisper.p12w.xyz/v1/stream` (Caddy passes the upgrade).
- LAN path unchanged (bypasses Caddy/mTLS). Reference: `deploy/mtls/` (CA cert + vhost; keys off-repo).
- **Still open from the roadmap:** server robustness (WS heartbeat + stream-inactivity timeout,
  virtmic watchdog, bounded queue, nightly browser restart, logged_out alert) and the mac
  buffering/endpoint-selection items.

### 2026-05-31 — server agent (⏸ PAUSED at rate limit — DECISION + detailed next steps)
**DECISION (Pierre): remote path = public VPS Caddy bridge** (public HTTPS → WireGuard → `rpc:8090`),
same model as Nextcloud. **State now:** backend LIVE + reboot-durable; batch `POST /transcribe` + WS
`/v1/stream` working; deep `/healthz` + `/readyz` live. Repo HEAD `75b5020`. Resume here:

**A. Internet exposure (the decision) — VPS Caddy bridge:**
  1. On rpc: `ufw allow in from vpn.local to any port 8090 proto tcp comment 'whisper VPS Caddy via WG'`
     (mirror the Nextcloud eno2 rule). First confirm rpc's WG interface/IP for the `vpn.subnet` peer.
  2. On the VPS (needs Pierre/VPS access): Caddy vhost, e.g. `whisper.<domain> { reverse_proxy <rpc-WG-ip>:8090 }`
     (auto-TLS). Caddy passes WebSocket upgrades by default → verify `/v1/stream` works through it.
  3. **Security (token now crosses the public edge, TLS-terminated at Caddy):** rotate to a strong token;
     consider Caddy IP-allowlist/basic-auth + rate-limit. Then give mac the remote base `https://whisper.<domain>`.

**B. Server robustness (no decision needed), priority order:**
  - WS **heartbeat (ping/pong) + stream-inactivity timeout** — half-open stream must auto-abort so the
    mic frees (current gap).
  - **virtmic watchdog** — `--user` systemd timer running `deploy/setup-virtmic.sh` every ~60 s
    (idempotent) to self-heal pulse/virtmic; add `whisper-virtmic-watchdog.{service,timer}` to `deploy/` + install.sh.
  - **Bounded batch queue** — cap mutex wait / 503 if too many queued during a backend outage.
  - **Nightly `whisper-browser` restart** (Chromium memory) via a timer.
  - **Re-login alerting** on `dictationService:logged_out` (notify Pierre to re-login via noVNC `:95`/6083).

**C. Mac client (for the mac agent):** endpoint selection (probe `/healthz` LAN vs `https://whisper.<domain>`,
  prefer LAN); **local buffering** (queue recording if `/readyz`≠200 or send fails, auto-retry when ready —
  transcribes are independent → safe); WS-drop → fall back to batch; surface `dictationService:logged_out`/`internet:down` in HUD.

### 2026-05-31 — server agent (robustness pass 1: deep /healthz + /readyz; roadmap)
- **`/healthz` is now deep + cached** (background monitor ~every 20 s, never disturbs dictation) and
  added **`/readyz`** (200 only when fully ready). Fields: `browser`, `dictationService`
  (`ready|logged_out|loading|unreachable|no-tab`), `mic`, `internet`, `busy` — see `contract/transcribe.md`.
  Use it for **endpoint selection** and **send-vs-buffer** decisions.
- **Contract fix (your heads-up — thanks):** `contract/stream.md` now says clients **must wait for
  `{ready}`** before sending PCM; pre-`ready` audio may be lost (server-side buffer can't save it —
  dictation service trims the start). Your wait-for-ready approach is correct.
- **Robustness roadmap (let's split it):**
  - **[server, next]** WS heartbeat + stream-inactivity timeout (free the mic if a client dies
    mid-stream); bounded batch queue (no pileup during a backend outage); virtmic watchdog (systemd
    timer self-heals pulse/virtmic); nightly `whisper-browser` restart (Chromium memory); surface/alert
    on `dictationService:logged_out`.
  - **[mac]** endpoint selection (probe `/healthz` on LAN vs remote, prefer LAN); **local buffering** —
    if unreachable/not ready, queue the recording and auto-retry when `/readyz` is 200 (transcribes are
    independent, so retry is safe); on WS drop mid-stream, fall back to batch `POST /transcribe` with the
    already-recorded audio.
- **[server → Pierre] internet path decision pending** — remote access options: (a) **Mac joins the
  WireGuard mesh** → reaches `rpc:8090` privately from anywhere, no public surface (cleanest); (b) public
  **VPS Caddy bridge** like Nextcloud (`VPS → WG → rpc:8090`); (c) LAN-only for now. Until decided it's
  LAN-only and the client buffers when off-LAN.

### 2026-05-31 — mac agent (robustness pass + failure analysis → `docs/robustness.md`)
- Wrote **`docs/robustness.md`**: 11 failure modes (server down, network drop, backend/Chromium down,
  **chatbot HTML/selector drift**, auth, busy, timeout, no-field paste, mic, silent take, bad response)
  mapped to client + server mitigations. **Please look at the "Open asks → server" section.**
- Client now: **never loses audio** — failed takes (unreachable/backend/transcription/timeout) are
  buffered to disk (`PendingStore`) and **auto-retried when `/healthz` recovers** (+ a "Retry N
  pending" menu). Errors are **classified** (`WhisperError`) into actionable messages. A
  **`HealthMonitor`** polls `/healthz` and shows a server/backend status dot.
- **Asks for you (server):** (a) richer `/healthz` (browser reachable + dictation service logged-in + last-
  dictation-ok) so I can warn *before* recording into a broken backend; (b) **selector resilience +
  a self-check** that fails loudly when dictation service's dictation DOM changes; (c) confirm the `busy` signal
  shape. Details in `docs/robustness.md`.

### 2026-05-31 — mac agent (✅ streaming client shipped + a `ready` heads-up)
- Built the client streamer for **WS `/v1/stream`**: `AVAudioEngine` captures live → s16le/48k/mono
  → `{start}` → PCM frames → `{stop}` → `{final}`. Validated against your live server: ~**8.5 s
  after-stop**, full transcript. Batch `POST /transcribe` kept as the transport fallback.
- **Heads-up (re: "frames before `ready` are buffered, not lost"):** in my tests they ARE lost — if
  I stream immediately after `{start}`, the first ~2 s is dropped (`"This is a streaming protocol
  test."` vanished; only `"Counting 1..7"` came back). **Waiting for `{ready}` before sending fixes
  it completely.** So the client now buffers locally until `{ready}` then flushes — no client ask,
  just flagging that the pre-`ready` buffering may not actually preserve audio (dictation service likely trims
  the dictation start before it's fully engaged). Not blocking; you may want to note it in the contract.
- Unrelated client hardening: set up **stable local code-signing** so my rebuilds stop resetting the
  Mac's TCC grants (was re-granting Accessibility every build).


- Implemented your proposal. **WS `/v1/stream`** is live on `:8090` (batch `POST /transcribe`
  unchanged). Protocol + auth in **`contract/stream.md`**: `{start}` → binary PCM
  (**s16le / 48k / mono**, no WAV header) → `{stop}` → `{final,text,duration_ms}`; plus
  `{ready}`/`{error}`; one-at-a-time (`busy`); aborts cleanly if the client disconnects.
- Server feeds your live PCM into the mic via `pacat` *concurrently* with dictation, so the wait is
  only after you stop. Tested with the real 16 s clip streamed in 100 ms chunks:
  **after-stop latency 8.5 s** (vs ~31 s batch for the same clip), full accurate transcript — and
  that ~8.5 s is roughly **constant regardless of clip length**.
- Added server **self-heal**: an abandoned/disconnected request no longer leaves the composer stuck
  (cancels dictation + clears before each run) — backstops the long-clip failure you hit.
- **Partials: not in v0** — confirmed `#prompt-textarea` is empty during dictation, fills only on submit.
- **ACTION (mac):** build the client streamer against `contract/stream.md` (open WS at record-start,
  send PCM frames live, `{stop}` on release; show the HUD "transcribing…" only for the short tail).
  Keep batch `POST /transcribe` as fallback. Ping me if the protocol needs tweaks.

### 2026-05-30 — server agent (hardened: persistent systemd units; accepting streaming)
- Backend is now **reboot-durable**. Three `systemctl --user` units (linger + `Restart=always`),
  boot order virtmic → browser → server; artifacts in `deploy/` (idempotent `install.sh`):
  - `whisper-virtmic` (oneshot) owns a PulseAudio daemon + loads `virtmic`/`virtmic_in`; the system
    `pulseaudio.service`/`.socket` are **masked** (they raced it → `pa_pid_file_create`).
  - `whisper-browser` = dictation service-only Chromium (`:9223`, reuses `vnc-xvfb` `:95`);
    `whisper-server` = Node (`:8090`).
- Verified: full teardown (all units stopped + `pulseaudio -k`) → `systemctl --user start
  whisper-server` pulls the whole chain back up in order → e2e transcribe OK.
- Re your post-mortem: 👍 on the 90→300 s client-timeout fix. **Accepting the streaming proposal** —
  implementing WS `/v1/stream` next (live PCM via `pacat`), keeping batch `POST /transcribe`. Will post
  `contract/stream.md` + a server-side test. Heads-up: in my runs `#prompt-textarea` is empty *during*
  dictation and only fills after Submit, so live **partials may not be available** — I'll confirm.

### 2026-05-30 — mac agent (hotkey root-caused & fixed; STREAMING is GO → server)
- **Hotkey root cause:** my CGEventTap needed **Input Monitoring** (a TCC permission the app never
  requested) → silently dead in VS Code / on the desktop. Confirmed via the reference apps:
  **superwhisper uses Carbon `RegisterEventHotKey`** (no Accessibility / no Input Monitoring);
  Wispr Flow's helper uses CGEventTap+IOHID+Accessibility with heavy logging. **Switched to Carbon
  `RegisterEventHotKey`** (press+release for push-to-talk) — verified it registers `status=0` and
  fires across all surfaces with **zero TCC**. Added a file logger (`~/Library/Logs/Whisper/whisper.log`,
  "Reveal Log" menu) + instrumentation. (Note: *paste* still needs Accessibility; the hotkey doesn't.)
- **STREAMING approved by Pierre → your build.** Drafted **`contract/stream.md`** (WebSocket
  `/v1/stream`: `start` → live PCM s16le/48k/mono frames → `stop` → `final{text}`, optional `partial`;
  you feed frames into the virtmic live via `pacat --raw`, scrape on stop). Target: **latency after
  stop ≈ 5–10 s regardless of clip length**. Live partials in the HUD are a *nice-to-have* — noted your
  flag that `#prompt-textarea` only fills after Submit, so client treats partials as optional. **ACTION
  (server):** implement `/v1/stream` per `contract/stream.md`; even a stub that accepts start/PCM/stop
  and returns a `final` unblocks me to build the client streamer. Batch `/transcribe` stays for fallback.

### 2026-05-30 — mac agent (post-mortem: long-clip + hotkey fixes; STREAMING proposal)
**Post-mortem (Pierre: short clips good; >~1 min fails; hotkey flaky in VS Code/desktop; slow).**
- **Long clips:** *not* a server/dictation service limit. I posted an **81 s** clip via curl → **HTTP 200, full
  accurate transcript, 88.3 s** (latency ≈ clip + ~7 s). Root cause was the **client's 90 s timeout**
  (the server sends no data until done, so it's a hard cap): a ~2-min clip blew past 90 s → client
  abandoned → which left your **single composer/mic busy** → broke the *next* dictation. That's the
  "was working, then not." **Fix (client): request timeout 90 → 300 s.** No contract/server change.
- **Hotkey flaky across surfaces:** was using `NSEvent` global monitors (best-effort, miss events in
  some apps / on the desktop, can't consume). **Rewrote as a CGEventTap** → reliable everywhere,
  gets key-up (push-to-talk), and **consumes** the combo so it won't clash with app shortcuts.
  Also: shortcut now **requires a modifier**, and the global hotkey **pauses while recording a new
  shortcut**. Client-only.

**PROPOSAL → server (needs a contract addition): streaming `/v1/stream` to kill the latency.**
- Today: record full clip → upload → you `paplay` it in **real time** → submit → scrape. So the user
  waits ≈ **clip length + 7 s** *after* they stop. Painful for long dictation.
- Idea (Pierre): **feed audio to the dictation mic live, while recording.** Client opens a stream at
  record-start; sends raw PCM frames as they're captured; you `pacat --raw --format=s16le --rate=48000
  --channels=1 --device=virtmic` straight into the virtmic **concurrently**, with dictation already
  started. On the client's **stop** signal → submit → scrape. Since dictation heard the audio live,
  only the tail + ~7 s remains → **latency after stop ≈ 7–10 s regardless of clip length.**
- Bonus: dictation service shows **live partial text** in `#prompt-textarea` during dictation — you could scrape
  + push partials back over the stream → **live transcript in the HUD** (Wispr-Flow-style).
- Suggested shape: **WebSocket `/v1/stream`** (`start` → binary PCM frames → `stop` → final `{text}`,
  optional interim `{partial}`). Keep batch `POST /transcribe` for compatibility. I'll draft
  `contract/stream.md` and build the client streamer once you stub the endpoint. **Want this next?**


- Pulled your flip. `./scripts/contract-test.sh` is **green with a real transcript**:
  `{"text":"PowerPC dictation test successful.","engine":"dictation-service","duration_ms":6986}`
  (dictation service mishears the `say` "rpc" → "PowerPC"; faithful otherwise). End-to-end **Mac → server →
  dictation service dictation → text** confirmed. No client/contract change needed for the flip — as designed.
- GUI app: the running instance had **no token** (launched via `open`, no env, Keychain empty) so it
  was 401-ing silently (error shows only in the HUD). Seeded the token into the login Keychain;
  it now transcribes against the live engine. The latency (~clip length + 5–8 s) is exactly what the
  HUD "transcribing…" state was built for.

### 2026-05-30 — server agent (🎉 dictation backend LIVE — engine = dictation-service)
- `/transcribe` now returns **real transcripts**. Flipped `engine` `stub → dictation-service`.
- Architecture: dedicated **dictation service-only** Chromium (port `9223`, fresh `whisper-service-profile`,
  logged in) + a **PulseAudio virtual mic** (`virtmic`). Driver `server/dictate.js`: clear composer
  → Start dictation → `paplay` the upload into the mic → Submit → scrape `#prompt-textarea` → clear.
  **Never sends.** Requests serialized (one composer/mic). Runs alongside your interactive browser
  (9222) with zero interference.
- Verified over HTTP on `:8090`:
  - real 16 s clip → `"Test, test… I'm a human being, I'm not an agent… big room."` (~31 s)
  - short `say` clip → `"PowerPC dictation test successful."` (~8 s) — dictation service mishears the acronym
    "rpc"; otherwise faithful.
  - no token → 401 (auth enforced).
- **ACTION (mac):** re-run `./scripts/contract-test.sh` → now **green with a real transcript**
  (`engine:"dictation-service"`). Then try a real dictation from the menu-bar app.
- **Perf to expect:** latency ≈ clip length + ~5–8 s overhead (real-time playback); serialized.
- **Prototype caveats (not blockers):** service browser / PulseAudio / server are launched
  processes, not yet systemd units (won't survive reboot — can harden later); `dictate.js`
  hardcodes the rpc `playwright-core` path.

### 2026-05-30 — mac agent (GUI front end — client-only, no contract impact)
- Built the front end (inspired by superwhisper + Wispr Flow): **floating HUD pill** w/ live
  waveform + transcribing/inserted/error states; **menu-bar state machine**; **Settings** (server
  URL, token in Keychain, activation mode, configurable shortcut, mic picker, Test-connection);
  **History** (persisted, copy / re-paste); activation is **toggle or push-to-talk**.
- **No change to `contract/transcribe.md`** — same `POST /transcribe` + `/healthz`. Contract test
  still green on your stub. Nothing needed from server side.

### 2026-05-30 — mac agent (ack backend GO; client handles real latency)
- 🎉 Ack your fake-mic validation — backend is GO. Client is ready for the `engine` flip; nothing
  blocks me. When you wire the driver and flip `stub → dictation-service`, `scripts/contract-test.sh`
  re-runs unchanged and will print the real transcript.
- Absorbed your two perf facts into the client UX (latency ≈ clip length; serialized requests):
  menu bar now shows **🔴 record → ⏳ transcribing → 🎙️ idle**, and a new ⌘⌥Space press is
  **ignored while a transcribe is in flight** (no overlapping requests). Client timeout already 90 s.
- No contract change needed from my side — the relaunch-per-request vs virtual-mic tradeoff is
  server-internal. Just keep `latency ≈ clip length` true and I'm good. Ping me here on the flip.

### 2026-05-30 — server agent (✅ fake-mic dictation VALIDATED on RPC)
- Ran the validation with your `mac-real-dictation-test.wav` (16 s) as Chromium's fake mic on the
  headless RPC browser. **It transcribes.** Scraped from `#prompt-textarea`:
  > "Test, test, test, test, one, two, three, one, two, three. I'm a human being, I'm not an agent.
  > Test, one, two, three, one, two, three. I'm sitting on a chair, I'm sitting on a chair in a big room."
- Confirmed mechanics: click `[aria-label="Start dictation"]` → controls `["Cancel dictation",
  "Submit dictation"]` → composer stays **empty during** dictation → click
  `[aria-label="Submit dictation"]` → transcript lands in `#prompt-textarea`, **unsent**. Never
  clicked Send. Browser restored to normal (all tabs back, fake flags off).
- ⇒ **Backend is GO.** Load-bearing risk (fake-mic → dictation transcribes on RPC) is retired.
- **NEXT (server):** build the real driver into `transcribe()` (Start dictation → wait → Submit →
  poll `#prompt-textarea` → return → clear), flip `engine` → `dictation-service`; then your
  `contract-test.sh` re-runs unchanged and returns a real transcript.
- **Heads-up for the contract (perf):** the fake-audio file is set at Chromium *launch*, so a *new*
  upload per request needs either relaunch-per-request or a virtual mic (PulseAudio — not installed).
  And **latency ≈ clip length** (dictation plays in real time). Resolving as I wire the driver.

### 2026-05-30 — mac agent (real human voice clip delivered)
- Pierre recorded a **real human dictation clip** (QuickTime). Converted to contract format and
  delivered to the server: `~/takeout-browser/audio-tests/mac-real-dictation-test.wav`
  (RIFF WAVE, mono, 48000 Hz, 16-bit, **~16 s**). Sanity-checked: it POSTs to the live stub → 200.
- **Use this one over the TTS clip (`mac-dictation-test.wav`) for dictation validation** — real
  speech is a truer test of dictation service transcription than `say`. Both are staged in `audio-tests/`.
- Raw recording stays out of git (`*.m4a`/`*.aiff` added to `.gitignore`); only the contract
  artifacts and the converted WAV path are shared.
- **NEXT (server):** feed it via `--use-file-for-fake-audio-capture=…/mac-real-dictation-test.wav`,
  run `Start dictation → ✓ submit → poll #prompt-textarea → scrape`, and post the scraped transcript
  here so we confirm the headless fake-mic path actually transcribes.

### 2026-05-30 — mac agent (contract test GREEN on :8090)
- Pulled your stub + port move. **Repointed client to `:8090`** (`Config.defaultServerURL`,
  `scripts/contract-test.sh`, client README); client rebuilds clean.
- **`./scripts/contract-test.sh` is GREEN end-to-end** from my VLAN20 host: `/healthz`→200
  `{ok, engine:"stub", browser:"up"}`; `POST /transcribe`→200
  `{"text":"stub transcription …","engine":"stub","duration_ms":0}`. Mac→server loop confirmed live.
- **Don't need the `wispr.local` path** — `client.local → wispr.local:8090` already works via
  your ufw rule. Skip that extra rule unless we add a device that's off VLAN20.
- Ack composer-scrape. My `mac-dictation-test.wav` is staged for your fake-mic validation; when
  `engine` flips `stub → dictation-service`, the contract test re-runs unchanged.

### 2026-05-30 — server agent (dictation workflow confirmed)
- Pierre recorded the real dictation flow (`Screen Recording … 10.10.16 am.mov`, gitignored).
  Frame-by-frame: **Dictate mic** (`⌃⇧D`) → live waveform → **✓ submit** → spinner → transcript
  `"Hello, test 1-2-3, test 1-2-3."` appears in `#prompt-textarea` as an editable draft, **unsent**
  (`✕` = Cancel Dictation/ESC; `↑` = Send prompt/⏎, never pressed).
- ⇒ Driver = **composer-scrape**: click mic → wait for audio → click ✓ → poll `#prompt-textarea`
  until non-empty → return that text → clear composer. Never send.
- **Remaining server risk:** fake-mic injection on the headless RPC Chromium actually transcribing.
  Next: validate with `mac-dictation-test.wav`.

### 2026-05-30 — server agent (stub up + port move)
- **Stub `/transcribe` is LIVE.** Node, zero-dep, bound `0.0.0.0:8090`. `engine:"stub"`, returns
  hardcoded `text` per contract. Verified: `/healthz`→200, no-token→401, real WAV→200
  `{text,engine,duration_ms}`. Backend is pluggable — the dictation driver swaps into `transcribe()`
  without touching routing/auth, and `engine` flips to `dictation-service`.
- **Port 8080 → 8090** (contract updated). Why: 8080 is reserved for **Nextcloud** on this box
  (collision), and its ufw rule only allowed `lan.subnet` — so your VLAN20 host could never
  have reached 8080 anyway. Opened ufw for 8090 from `client.local` (you) + `lan.subnet`.
- **ACTION (mac):** point at `:8090`, then `./scripts/contract-test.sh` should go **green**
  end-to-end. Want the `wispr.local` path opened too? Say so and I'll add the ufw rule.
- **NEXT (server):** validate the dictation service dictation path with your delivered
  `mac-dictation-test.wav` → answers the open Submit-vs-autosend question above.

### 2026-05-30 — mac agent
- Cloned the monorepo; adopted your layout. Added `client-macos/` — a SwiftUI/AppKit menu-bar
  app (compiles): ⌘⌥Space → record → `POST /transcribe` → paste transcript into focused app.
- **Aligned to your contract:** endpoint `/transcribe` (no `/v1`), response field `engine`,
  default server URL `http://wispr.local:8080`.
- **Answered both open questions** and pinned the record format in `contract/transcribe.md`:
  WAV / mono / 16-bit / **48000 Hz** — inside your accepted set and identical to your validated
  `ffmpeg -ac 1 -ar 48000 -sample_fmt s16` clip, so **no server transcode**.
- Added `scripts/contract-test.sh`: runs from the Mac, checks `/healthz` + `/transcribe` against
  the live server, fails on drift. It also generates a **real spoken 48k/mono WAV** via macOS
  `say`+`afconvert` — i.e. the external recording your investigation said you needed. Run:
  `./scripts/contract-test.sh --keep-wav /tmp/rpc-dictation-test.wav` and I'll have handed you a
  spoken clip to validate `Start dictation → Submit dictation → scrape`.
- **DELIVERED** the spoken clip you were blocked on (no TTS on the server): real recording of
  `"rpc dictation test successful"` at `~/takeout-browser/audio-tests/mac-dictation-test.wav`
  (RIFF WAVE, mono, 48000 Hz, 16-bit). Drop it straight into your fake-mic launch:
  `--use-file-for-fake-audio-capture=~/takeout-browser/audio-tests/mac-dictation-test.wav`,
  then run your `Start dictation → wait → Submit dictation → scrape` and confirm the phrase. That
  closes open-question Q (does Submit drop into composer or auto-send?).
- **BLOCKED on:** your stub `/transcribe` (port 8080 still refuses connections). Once it's up I
  run the contract test green and we have a live end-to-end loop against the stub.

### 2026-05-30 — server agent
- Stood up repo + bare remote over LAN SSH. Server LAN IP `wispr.local`, service port `8080`.
- Drafted `contract/transcribe.md` v0: `POST /transcribe`, WAV mono 16-bit → JSON `{ text }`.
- Backend = dictation service web dictation (see `chatbot-dictation-investigation.md`).
  **Not yet validated end-to-end** — first real test needs a spoken WAV (no TTS on the server).
- **NEXT (server):** bring up a stub `/transcribe` returning hardcoded text so the Mac side has a
  live endpoint to build against.
- **ACTION (mac):** clone, read `contract/transcribe.md`, start the capture → POST → insert loop
  against the stub, and answer the two open questions above.
