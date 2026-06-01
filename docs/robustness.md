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
| 6 | Server busy (one composer) | `{error:busy}` / 409 | classify **busy**; save full recording and retry later | no server-side long queue; immediate busy signal |
| 7 | Slow backend / long clip | request exceeds timeout | 10-minute capture cap; long request timeout; classify **timeout** and buffer for retry | 10-minute WAV/stream cap; duration-based playback timeout |
| 8 | **Paste target changed** | paste could land in the wrong app/field | capture app/window/field before recording; re-focus and verify immediately before insertion; if changed, copy only | n/a |
| 9 | Mic revoked / no input | capture start throws | "microphone unavailable — check permissions" | n/a |
| 10 | Silent / empty take | empty transcript | min-duration guard; treat empty as "no speech" (no server hit needed) | return empty cleanly |
| 11 | Malformed response | bad JSON / missing text | tolerant parsing; treat as transcription error → buffer | stable schema |

## Client robustness model (this app)
- **Never lose audio.** Every take is captured to bounded PCM in memory; on a *retryable* failure the WAV is
  written to `~/Library/Application Support/wispr/pending/` and retried later (manually or when
  `/healthz` recovers). Retried transcripts go to **History + last transcript** without overwriting
  the clipboard.
- **Classified errors** (`WisprError`): every failure maps to a category with a user message and a
  `retryable` flag, so the HUD/menu say something actionable instead of a stack trace.
- **Health awareness.** `HealthMonitor` polls `/healthz` (~25 s + on demand); the HUD status dot and
  menu reflect up / unreachable / backend-down, and recovery kicks off pending retries.
- **Paste verification** (#8): capture the focused app/window/element before recording, verify it
  immediately before insertion, try direct Accessibility insertion first, and restore the clipboard
  after a confirmed pasteboard fallback.
- **Stream→batch fallback** exists for transport failures. Both modes allow full clips up to 10 minutes.

## Open asks → server (see COORDINATION)
- #3/#4: richer `/healthz` (browser reachable, dictation service logged-in, last-dictation-ok) so the client can
  warn *before* the user records into a broken backend.
- #4: selector resilience + a server self-check that fails loudly when the dictation UI changes.
- Confirm the upstream dictation service dictation maximum so the 10-minute cap can be adjusted with evidence.
