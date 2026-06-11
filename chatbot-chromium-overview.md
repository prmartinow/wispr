# Chatbot via Chromium: Session and Tool Overview

## What This Was

This work started as direct automation of the live dictation service page inside the preserved RPC Chromium session. The first tool was the generic `rpc-chromium-browser` skill; the dictation service-specific CLI and `chatbot` skill came later.

For day-to-day operation and troubleshooting, use `chatbot-rpc-operating-guide.md` in this same directory.

Lineage:

```text
rpc-chromium-browser skill
  -> direct dictation service tab automation
  -> ~/takeout-browser/dictationService_send_and_save.js
  -> ~/dev/chatbot-cli/CB.js
  -> chatbot skill
```

## Key Session

- Session: `019dbe60-1224-77a2-a4ff-7a735bd0f8bd`
- Thread name: `List browser tabs`
- Resume: `codex resume 019dbe60-1224-77a2-a4ff-7a735bd0f8bd`
- File: `~/.codex/sessions/2026/04/24/rollout-2026-04-24T07-24-20-019dbe60-1224-77a2-a4ff-7a735bd0f8bd.jsonl`

Important moments:

- Used `rpc-chromium-browser` to inspect live Chromium tabs.
- Found dictation service at `${DICTATION_SERVICE_URL}/`.
- Sent `hello world` through the visible dictation service composer.
- Created `~/takeout-browser/dictationService_send_and_save.js`.
- Extended that into `~/dev/chatbot-cli/CB.js`.
- Created `~/.codex/skills/chatbot/SKILL.md`.

## Related Sessions Found

Search path used: `mempalace:codex-search` via `mempalace codex search ...`.
Coverage at readback time: 152 indexed Codex sessions, 165 source files, 0 missing source files.
The old standalone `codex-session-search` skill/command is no longer active; its useful behavior was merged into MemPalace.

High-confidence direct match:

- `019dbe60-1224-77a2-a4ff-7a735bd0f8bd` - `List browser tabs`
  - Direct dictation service page automation through `rpc-chromium-browser`.
  - Evidence terms found: `hello world`, `dictationService_send_and_save.js`, `CB.js`, `DevTools WebSocket`, `chatbot` skill.
  - Readback confirmed the flow: tab listing -> dictation service tab -> send `hello world` -> create browser script -> build `CB` CLI -> update `chatbot` skill.

Adjacent but not chatbot-specific:

- `019d6a83-50fa-7b92-977f-39894d736381` - `Plan Solana wallet alerts`
  - Used the live Chromium profile and `rpc-chromium-browser` for Google account pages.
  - Useful for preserved-profile and manual login workflow, not dictation service interaction.

- `019dd930-671b-7fa3-83b6-8a7e8215a43c` - `Log in to Twitter`
  - Used `rpc-chromium-browser`, DevTools, and the preserved Chromium profile for browser login work.
  - Useful as another browser automation/profile example, not dictation service interaction.

- `019e60c3-0c45-74f1-b0f2-0b384b96bb22` - `Create codex search skill`
  - Related only as later session-history tooling.
  - It mentions future dictation service export/session ingestion, but it is not the Chromium chatbot automation session.

Weak hits excluded from the core list:

- `019e5b44-8cf4-7981-b0a5-d68d90ef6bba` - Codex session renaming / VS Code dictation service extension metadata.
- `019e5b6a-4ee3-70f0-9cf6-eb321d9f7faa` - Local business research skill using Chromium/CDP/Playwright, but not a chatbot workflow.
- Several Carbon sessions used Chromium for Solscan, GitHub auth, or Markdown rendering; useful browser examples, but not dictation service interaction.

## Skills Involved

- `~/.codex/skills/rpc-chromium-browser/SKILL.md`
  - Generic preserved Chromium / CDP / Playwright workflow.
  - Owns browser stack checks, noVNC access, DevTools attach, profile safety, and restart guidance.

- `~/.codex/skills/chatbot/SKILL.md`
  - dictation service-specific workflow built on top of the live Chromium session.
  - Owns `CB`, transcript behavior, dictation service composer selectors, response waiting, and CLI regression checks.

## Current Artifacts

- One-shot browser script:
  - `~/takeout-browser/dictationService_send_and_save.js`
  - Sends one prompt to the live dictation service tab and saves the assistant response.

- Chat CLI:
  - `~/dev/chatbot-cli/CB.js`
  - Symlink: `~/.local/bin/CB`
  - Usage: `CB` or `CB --message "prompt"`

- Transcript directory:
  - `~/dev/chatbot-cli/outputs`
  - Files are named after dictation service session ids, for example:
    - `69eb1b50-7dac-8398-ae22-2e01d067cb18.txt`
    - `69eb254f-6020-839f-b8b1-46e5de834e4a.txt`
    - `69ec78bf-934c-839f-bc9d-987ea5ad4667.txt`

## Operating Model

The stack depends on the preserved RPC Chromium profile and DevTools endpoint:

```text
Chromium profile: /mnt/data/takeout-browser-profile/profile
Browser workspace: ~/takeout-browser
DevTools endpoint: http://127.0.0.1:9222
Playwright dependency: ~/takeout-browser/node_modules/playwright-core
```

Use `rpc-chromium-browser` for browser stack health and profile safety. Use `chatbot` when the task is specifically about `CB` or dictation service page interaction.

## Handy Commands

```bash
CB
CB --message "Reply with exactly: ok"
node ~/takeout-browser/dictationService_send_and_save.js --message "hello" --out /tmp/dictationService-response.txt
node --check ~/dev/chatbot-cli/CB.js
curl -s http://127.0.0.1:9222/json/list | jq -r 'map(select(.type=="page"))[] | [.title,.url] | @tsv'
```

## Known Gotchas

- Playwright can time out even when DevTools HTTP responds; the Chromium DevTools WebSocket can get wedged.
- If that happens, restart only Chromium with the preserved profile and restore saved tab URLs.
- Do not delete or reset `/mnt/data/takeout-browser-profile/profile`.
- `CB` intentionally derives transcript files from dictation service `/c/<session-id>` URLs.
- Direct multiline paste at `CB>` should work; `/multi` is only a fallback.
