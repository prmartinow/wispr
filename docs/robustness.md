# Robustness & failure handling

How the pipeline fails and what each side does about it. The pipeline is:

```
mic → client capture → (WS /v1/stream | POST /transcribe) → server → Chromium+Playwright → dictation service dictation → text → paste
```

Owned jointly; **client** mitigations are implemented in `client-macos/`, **server** items are
for the server agent. Update via commit + a `../COORDINATION.md` note.

## Failure modes & mitigations

| # | Failure | Symptom seen by client | Client mitigation | Server mitigation |
|---|---|---|---|---|
| 1 | Server process down | WS/POST connection refused; `/healthz` unreachable | classify **unreachable**; **save recording to retry queue**; HUD shows server-down dot; auto-retry on recovery | systemd `Restart=always` (done) |
| 2 | Network/Wi-Fi/VLAN drop | transport error / timeout | same as #1 (transport class) | — |
| 3 | Backend down (Chromium wedged / dictation service down) | `503 backend_unavailable` or `{error:backend_unavailable}`; `/healthz` `browser:"down"` | surface "backend down"; **buffer for retry**; status dot orange | auto-relaunch Chromium; richer `/healthz` (browser/login state) |
| 4 | **Chatbot HTML/selectors change** | `transcription_error`, timeout, or empty text | can't fix selectors client-side → classify, **buffer for retry**, clear message; flag to server | resilient selectors (multiple fallbacks), self-test, alert |
| 5 | Auth (token rotated/wrong) | `401` / `{error:unauthorized}` | classify **unauthorized** (NOT retryable); "check token in Settings"; don't loop | — |
| 6 | Server busy (one composer) | `{error:busy}` / 409 | "busy — try again"; short auto-retry | queue or busy signal (done) |
| 7 | Slow backend / long clip | request exceeds timeout | client timeout 300 s; classify **timeout**; buffer for retry | keep latency ≈ clip + tail |
| 8 | **No editable field focused** | paste lands nowhere | **pre-check focused element (AX); if not editable, don't paste — copy + "⌘V to paste" + Paste-last action** | n/a |
| 9 | Mic revoked / no input | capture start throws | "microphone unavailable — check permissions" | n/a |
| 10 | Silent / empty take | empty transcript | min-duration guard; treat empty as "no speech" (no server hit needed) | return empty cleanly |
| 11 | Malformed response | bad JSON / missing text | tolerant parsing; treat as transcription error → buffer | stable schema |

## Client robustness model (this app)
- **Never lose audio.** Every take is captured to PCM in memory; on a *retryable* failure the WAV is
  written to `~/Library/Application Support/wispr/pending/` and retried later (manually or when
  `/healthz` recovers). Retried transcripts go to **History + clipboard + a HUD note** (focus has moved).
- **Classified errors** (`WisprError`): every failure maps to a category with a user message and a
  `retryable` flag, so the HUD/menu say something actionable instead of a stack trace.
- **Health awareness.** `HealthMonitor` polls `/healthz` (~25 s + on demand); the HUD status dot and
  menu reflect up / unreachable / backend-down, and recovery kicks off pending retries.
- **Paste verification** (#8): check the focused element via the Accessibility API before pasting.
- **Stream→batch fallback** already exists for transport failures; batch is the retry transport.

## Open asks → server (see COORDINATION)
- #3/#4: richer `/healthz` (browser reachable, dictation service logged-in, last-dictation-ok) so the client can
  warn *before* the user records into a broken backend.
- #4: selector resilience + a server self-check that fails loudly when the dictation UI changes.
- #6: confirm the busy signal's shape (code/HTTP) so the client can auto-retry vs. surface.
