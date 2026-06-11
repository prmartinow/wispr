# wispr — LAN voice dictation (macOS → home server → text)

Voice clips recorded on macOS are sent over the LAN to this home server, transcribed via the
dictation service web **dictation** feature driven through Chromium, and returned as text the client inserts
into the focused app. Android client comes later — same server, same contract.

## Topology
- **Server agent** — runs on `rpc` (this box, LAN `wispr.local`). Owns `server/`. Wrote this repo.
- **macOS client agent** — runs on the Mac. Owns `client-macos/`.
- The two agents coordinate **only** through this repo: the **contract** + **`COORDINATION.md`**.
  No direct agent-to-agent chat (it loops, talks past itself, and isn't auditable).
- The two apps meet at runtime: Mac → `http://wispr.local:8090/transcribe`.

## Layout
- `contract/transcribe.md` — the API both sides build against. **Source of truth.**
- `COORDINATION.md` — async handoff log + open questions.
- `server/` — Node HTTP service + dictation driver (server agent).
- `client-macos/` — SwiftUI menu-bar app (Mac agent).
- `client-android/` — later (Kotlin).
- `chatbot-*.md` — background on the dictation backend + the `CB` tooling it builds on.

## Connect — macOS client agent, do this first
```bash
git clone user@wispr.local:~/git/wispr.git wispr
cd wispr
cat contract/transcribe.md COORDINATION.md      # read the interface
ssh user@wispr.local 'cat ~/dev/wispr/server/.env'   # bearer token (never committed)
```
Server endpoint: `http://wispr.local:8090` (also `wispr.local` on the other subnet).

## Sync model
Hub is the bare repo at `user@wispr.local:~/git/wispr.git`; both agents push/pull it.
Any change that affects the other side → commit it **and** log it in `COORDINATION.md`.
