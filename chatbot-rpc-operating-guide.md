# RPC Chatbot Operating Guide

## Purpose

`CB` is a local terminal wrapper around the live dictation service page running in the preserved RPC Chromium profile. It does not call the OpenAI API directly. It attaches to Chromium through DevTools/CDP, types into the dictation service composer, waits for the browser response, prints the answer, and appends both sides to a transcript file.

Use this guide when operating, testing, or debugging chatbot interaction on `rpc`.

## Which Path To Use

- Use `CB` for normal chatbot interaction.
- Use `~/dev/chatbot-cli/CB.js` when editing or testing the CLI implementation.
- Use `~/takeout-browser/dictationService_send_and_save.js` only for the older one-shot script.
- Use the `chatbot` skill for CLI behavior, transcript handling, or dictation service page automation.
- Use the `rpc-chromium-browser` skill when the Chromium, VNC, profile, or DevTools stack itself needs repair.
- Use MemPalace / `mempalace:codex-search` only when searching old Codex session history.

## File Layout

```text
~/dev/chatbot-cli/
  CB.js                         # Main CLI
  outputs/
    <dictationService-session-id>.txt    # Per-dictation service-session transcripts
    new-chat.txt                # Temporary fallback before dictation service assigns /c/<id>

~/.local/bin/CB         # Symlink to ~/dev/chatbot-cli/CB.js

~/takeout-browser/
  dictationService_send_and_save.js      # Older one-shot prototype
  node_modules/playwright-core  # Dependency used by CB and scripts
  profile -> /mnt/data/takeout-browser-profile/profile
  logs/chrome.log

/mnt/data/takeout-browser-profile/profile
  # Preserved Chromium profile with browser state and login
```

Do not delete or reset `/mnt/data/takeout-browser-profile/profile`; it is the browser identity and login state.

## Runtime Dependencies

The CLI expects:

```text
Host: rpc
DevTools endpoint: http://127.0.0.1:9222
Browser profile: ~/takeout-browser/profile
Real profile storage: /mnt/data/takeout-browser-profile/profile
Playwright import: ~/takeout-browser/node_modules/playwright-core
```

The browser can be visible through noVNC, but `CB` only requires the CDP endpoint at `127.0.0.1:9222`.

For browser-side dictation/microphone behavior, see `chatbot-dictation-investigation.md`.

## Common Usage

Interactive mode:

```bash
CB
```

One-shot prompt:

```bash
CB --message "Reply with exactly: ok"
```

Read prompt from stdin:

```bash
cat prompt.txt | CB --message -
```

Use a longer wait for slow answers:

```bash
CB --message "your prompt" --timeout 300000
```

Use a temporary transcript only when explicitly needed:

```bash
CB --message "test" --transcript /tmp/cb-test.txt
```

Interactive commands:

```text
/exit          quit
/quit          quit
/transcript    print current transcript path
/multi         fallback manual multiline mode; normal paste at CB> should work
```

## Interaction Flow

`CB.js` follows this sequence:

1. Parse CLI args and default to `http://127.0.0.1:9222`.
2. Attach to the existing Chromium browser with `chromium.connectOverCDP`.
3. Reuse the first open `DICTATION_SERVICE_URL/` tab, or open dictation service if none exists.
4. Derive the transcript path from the dictation service URL:

   ```text
   DICTATION_SERVICE_URL/c/<session-id>
   -> ~/dev/chatbot-cli/outputs/<session-id>.txt
   ```

5. Find the visible dictation service composer. The current reliable selector is `#prompt-textarea`; hidden helper textareas can also exist, so visibility matters.
6. Insert text with Playwright keyboard input and press `Enter`.
7. Append the user message to the transcript.
8. Wait for the assistant turn after the matching user turn.
9. Poll dictation service UI state about every 3 seconds while Stop / Interrupt / Cancel generation controls are visible.
10. Once generation is idle, read the final assistant text, print it, and append it to the transcript.

Text-stability is only a long fallback; the primary completion check is dictation service's visible generation state.

## Transcript Behavior

Transcripts are append-only text files:

```text
ChatBot CLI transcript
Started: <iso timestamp>

[<iso timestamp>] USER
...

[<iso timestamp>] ASSISTANT
...
```

Important details:

- One dictation service browser conversation maps to one transcript file.
- A new chat may start as `new-chat.txt`, then switch to `<session-id>.txt` after dictation service assigns `/c/<id>`.
- `--transcript` is an override for temporary tests; normal operation should use session-derived files.
- The most recent RPC test saved:

  ```text
  ~/dev/chatbot-cli/outputs/6a1a3995-2d40-8323-8741-d24b031e041c.txt
  ```

## Health Checks

Check the CLI:

```bash
command -v CB
ls -l ~/.local/bin/CB ~/dev/chatbot-cli/CB.js
node --check ~/dev/chatbot-cli/CB.js
CB --help
```

Check DevTools:

```bash
curl -sS --max-time 5 http://127.0.0.1:9222/json/version
curl -sS http://127.0.0.1:9222/json/list \
  | jq -r 'map(select(.type=="page"))[] | [.title,.url] | @tsv'
```

Check Playwright attach:

```bash
cd ~/takeout-browser && node - <<'JS'
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');
(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222', { timeout: 10000 });
  const ctx = browser.contexts()[0];
  console.log('contexts', browser.contexts().length, 'pages', ctx.pages().length);
  await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
JS
```

Run a deterministic end-to-end test:

```bash
CB --message "Reply with exactly: rpc chatbot test ok" --timeout 180000
```

Expected response:

```text
rpc chatbot test ok
```

## Direct DevTools Readback

Use this to inspect the live dictation service DOM without sending a message:

```bash
cd ~/takeout-browser && node - <<'JS'
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222', { timeout: 10000 });
  const ctx = browser.contexts()[0];
  const page = ctx.pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  if (!page) throw new Error('No dictation service page found');

  const state = await page.evaluate(() => {
    const visible = (el) => {
      if (!el) return false;
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
    };
    const textOf = (el) => (el?.innerText || el?.textContent || '').replace(/\s+/g, ' ').trim();
    const turns = [...document.querySelectorAll('[data-testid^="conversation-turn-"]')]
      .map((turn, index) => {
        const roleEl = turn.querySelector('[data-message-author-role]');
        return {
          index,
          role: roleEl?.getAttribute('data-message-author-role') || '',
          text: textOf(roleEl || turn),
        };
      })
      .filter(t => t.role && t.text);
    const controls = [...document.querySelectorAll('button,[role="button"]')]
      .filter(visible)
      .map(el => `${el.getAttribute('data-testid') || ''} ${el.getAttribute('aria-label') || ''} ${textOf(el)}`)
      .filter(text => /stop|interrupt|cancel/i.test(text));
    const composer = document.querySelector('#prompt-textarea, [data-testid="composer-input"], textarea[placeholder], div[contenteditable="true"]');
    return {
      url: location.href,
      title: document.title,
      composerVisible: visible(composer),
      generationActive: controls.length > 0,
      lastTurns: turns.slice(-4),
    };
  });

  console.log(JSON.stringify(state, null, 2));
  await browser.close();
})().catch(e => { console.error(e.stack || e.message); process.exit(1); });
JS
```

## Starting Chromium If DevTools Is Down

First inspect current display/browser state:

```bash
hostname
ps -ef | rg 'Xvfb|x11vnc|websockify|chrome-linux64/chrome'
ss -ltnp | rg '5900|5903|6080|6083|9222'
ls -ld ~/takeout-browser/profile /mnt/data/takeout-browser-profile/profile
```

If the VNC/X display stack is already running, start only Chromium on that display. On 2026-05-30 the active display was `:95`, so this worked:

```bash
DISPLAY=:95 setsid ~/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome \
  --user-data-dir=~/takeout-browser/profile \
  --remote-debugging-port=9222 \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --window-size=1400,1000 \
  --no-sandbox \
  DICTATION_SERVICE_URL/ \
  > ~/takeout-browser/logs/chrome.log 2>&1 < /dev/null &
```

If no display stack is running, use the `rpc-chromium-browser` skill's full stack startup sequence. Its older default is `Xvfb :99`, `x11vnc 5900`, noVNC `6080`, and Chromium CDP `9222`.

## Troubleshooting

If `CB` cannot connect:

```bash
curl -sS --max-time 5 http://127.0.0.1:9222/json/version
```

- If this fails, Chromium with remote debugging is not listening.
- If this succeeds but Playwright attach hangs, the DevTools websocket may be wedged; restart only Chromium with the preserved profile.
- Do not delete the Chromium profile to fix attach problems.

If `CB` sends but captures too early:

- Check whether dictation service changed its generation controls.
- Inspect visible buttons for Stop / Interrupt / Cancel.
- Keep state-based waiting as the primary completion signal.

If multiline paste is cropped:

- Normal paste at `CB>` should work through bracketed paste mode.
- Use `/multi` as the manual fallback.
- Regression-test with a final sentinel line and verify it appears in the transcript.

If random keystrokes become messages while waiting:

- Re-test `discardInputDuringWait`.
- The intended behavior is to discard input while waiting for dictation service, then create a fresh prompt after the response.

## Recent Verified State

On 2026-05-30, the RPC test path was verified:

```text
Prompt: Reply with exactly: rpc chatbot test ok
Response: rpc chatbot test ok
Transcript: ~/dev/chatbot-cli/outputs/6a1a3995-2d40-8323-8741-d24b031e041c.txt
dictation service URL: DICTATION_SERVICE_URL/c/6a1a3995-2d40-8323-8741-d24b031e041c
```

Direct DevTools readback confirmed:

- the dictation service tab was open,
- the final user and assistant turns were present in the DOM,
- generation was idle,
- the visible composer was available at `#prompt-textarea`.
