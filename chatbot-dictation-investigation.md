# dictation service Dictation Investigation on RPC

Date: 2026-05-30

## Summary

The dictation service web composer exposes two separate audio-related controls:

- `Start dictation` / tooltip `Dictate Ctrl+Shift+D`
- `Start Voice`

The dictation feature is the composer microphone path. It is separate from voice mode. In the current normal RPC Chromium launch, dictation does not start because Chromium has no audio input device available.

The important finding is that this is not primarily a dictation service transcript or `CB` issue. It is a browser media-device issue on the RPC node.

## Current Normal Browser State

Normal launch path:

```bash
DISPLAY=:95 setsid ~/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome \
  --user-data-dir=~/takeout-browser/profile \
  --remote-debugging-port=9222 \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --window-size=1400,1000 \
  --no-sandbox \
  DICTATION_SERVICE_URL/c/6a1a3995-2d40-8323-8741-d24b031e041c \
  > ~/takeout-browser/logs/chrome.log 2>&1 < /dev/null &
```

Current dictation service tab:

```text
DICTATION_SERVICE_URL/c/6a1a3995-2d40-8323-8741-d24b031e041c
```

Current media result in normal launch:

```json
{
  "micPermission": "prompt",
  "devices": [],
  "getUserMedia": {
    "ok": false,
    "name": "NotFoundError",
    "message": "Requested device not found"
  }
}
```

OS-level audio input check:

```text
/dev/snd contains only seq and timer; no capture device was exposed.
```

So, even when microphone permission is temporarily granted through Playwright, the browser still cannot create an audio stream:

```json
{
  "micPermission": "granted",
  "devices": [],
  "getUserMedia": {
    "ok": false,
    "name": "NotFoundError",
    "message": "Requested device not found"
  }
}
```

## UI Controls Found

The visible composer area contains:

```text
Start dictation
Start Voice
```

On hover, the dictation button shows:

```text
Dictate Ctrl+Shift+D
```

The visible composer input is:

```text
#prompt-textarea
role="textbox"
aria-label="Chat with dictation service"
contenteditable="true"
```

There is also a hidden `textarea[placeholder="Ask anything"]`; automation must ignore hidden composer candidates.

## Normal Dictation Click Result

Test:

1. Click `Start dictation`.
2. Wait and inspect DOM.
3. Try `Ctrl+Shift+D`.
4. Check console, failed requests, permissions, controls, and screenshot.

Observed:

- No browser permission bubble appeared.
- `micPermission` stayed `prompt` unless manually overridden.
- `enumerateDevices()` returned no audio input devices.
- `getUserMedia({ audio: true })` returned `NotFoundError`.
- The UI remained at `Start dictation` / `Start Voice`.
- No console errors or failed network requests were captured.
- No message was sent to dictation service.

Interpretation:

The dictation button is present and clickable, but the current browser session cannot enter dictation because no microphone exists from Chromium's perspective.

## Fake-Media Test

To isolate dictation service UI behavior from the missing RPC mic, Chromium was temporarily restarted with fake media devices:

```bash
DISPLAY=:95 setsid ~/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome \
  --user-data-dir=~/takeout-browser/profile \
  --remote-debugging-port=9222 \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --window-size=1400,1000 \
  --no-sandbox \
  --use-fake-device-for-media-stream \
  --use-fake-ui-for-media-stream \
  DICTATION_SERVICE_URL/c/6a1a3995-2d40-8323-8741-d24b031e041c \
  > ~/takeout-browser/logs/chrome.log 2>&1 < /dev/null &
```

With fake media, Chromium exposed:

```text
Fake Default Audio Input
Fake Audio Input 1
Fake Audio Input 2
Fake Default Audio Output
Fake Audio Output 1
Fake Audio Output 2
```

`getUserMedia({ audio: true })` then succeeded:

```json
{
  "ok": true,
  "tracks": [
    {
      "kind": "audio",
      "label": "Fake Default Audio Input",
      "readyState": "live",
      "muted": false
    }
  ]
}
```

Clicking `Start dictation` changed the dictation service controls to:

```text
Cancel dictation
Submit dictation
```

During dictation mode:

- the normal composer candidates disappeared,
- `Cancel dictation` became the left audio control,
- `Submit dictation` became the right audio control,
- no chat message was submitted,
- no actual speech transcription was validated because the fake stream did not contain a known spoken phrase.

This proves the dictation service dictation UI itself can activate on RPC when Chromium has an audio input device.

## Proposed Audio Injection Path

The most direct next test is to feed a known WAV file into Chromium as a fake microphone. This does not require a real microphone or PulseAudio setup, and it tests the exact dictation service web dictation path.

Target flow:

```text
spoken WAV file
  -> Chromium fake audio capture
  -> dictation service Start dictation
  -> dictation service transcribes into dictation draft
  -> Submit dictation
  -> text appears in composer or is submitted by dictation service UI
```

Use a deterministic phrase, for example:

```text
rpc dictation test successful
```

### Prepare Audio

Chrome's fake audio capture path expects an audio file suitable for WebRTC fake capture. Use WAV. If the source is MP3, M4A, Opus, or another format, convert it first:

```bash
mkdir -p ~/takeout-browser/audio-tests
ffmpeg -y \
  -i /path/to/source-audio.ext \
  -ac 1 \
  -ar 48000 \
  -sample_fmt s16 \
  ~/takeout-browser/audio-tests/rpc-dictation-test.wav
```

The source audio should be short and clear, ideally 3-8 seconds, with only the phrase being tested. Avoid background noise and long silence.

This RPC node has `ffmpeg`, but no obvious local text-to-speech command was found during the first investigation. So the first test audio probably needs to come from an external recording or another machine.

### Relaunch Chromium With File-Backed Fake Mic

Save current tabs first:

```bash
curl -sS http://127.0.0.1:9222/json/list \
  | jq -r 'map(select(.type=="page"))[] | .url' \
  > /tmp/rpc-chromium-tabs-before-audio-test.txt
```

Stop only Chromium, not the VNC/X display stack:

```bash
chrome_pid="$(ss -ltnp | awk '/127.0.0.1:9222/ {print $NF}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$chrome_pid" ]; then
  kill "$chrome_pid"
fi
```

Start Chromium with fake media and the WAV file:

```bash
DISPLAY=:95 setsid ~/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome \
  --user-data-dir=~/takeout-browser/profile \
  --remote-debugging-port=9222 \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --window-size=1400,1000 \
  --no-sandbox \
  --use-fake-device-for-media-stream \
  --use-fake-ui-for-media-stream \
  --use-file-for-fake-audio-capture=~/takeout-browser/audio-tests/rpc-dictation-test.wav \
  DICTATION_SERVICE_URL/c/6a1a3995-2d40-8323-8741-d24b031e041c \
  > ~/takeout-browser/logs/chrome.log 2>&1 < /dev/null &
```

Then confirm the browser sees an audio device:

```bash
cd ~/takeout-browser && node - <<'JS'
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');
(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const page = browser.contexts()[0].pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  const state = await page.evaluate(async () => {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const gum = await navigator.mediaDevices.getUserMedia({ audio: true })
      .then(stream => {
        const tracks = stream.getTracks().map(t => ({ kind: t.kind, label: t.label, readyState: t.readyState }));
        stream.getTracks().forEach(t => t.stop());
        return { ok: true, tracks };
      })
      .catch(e => ({ ok: false, name: e.name, message: e.message }));
    return {
      devices: devices.map(d => ({ kind: d.kind, label: d.label })),
      gum,
    };
  });
  console.log(JSON.stringify(state, null, 2));
  await browser.close();
})();
JS
```

### Run The Dictation Test

Use DevTools to click dictation and observe the draft:

```bash
cd ~/takeout-browser && node - <<'JS'
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const page = browser.contexts()[0].pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  if (!page) throw new Error('No dictation service page found');

  await page.bringToFront();
  await page.getByLabel(/start dictation/i).first().click();
  await page.waitForTimeout(12000);

  const state = await page.evaluate(() => {
    const visible = (el) => {
      if (!el) return false;
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
    };
    const textOf = (el) => (el?.innerText || el?.textContent || '').replace(/\s+/g, ' ').trim();
    const controls = [...document.querySelectorAll('button,[role="button"]')]
      .filter(visible)
      .map(el => ({
        aria: el.getAttribute('aria-label') || '',
        text: textOf(el),
      }))
      .filter(b => /dictat|submit|cancel|voice|mic/i.test(`${b.aria} ${b.text}`));
    const bodyText = textOf(document.body);
    const expectedSeen = /rpc dictation test successful/i.test(bodyText);
    return { controls, expectedSeen, bodyTextSnippet: bodyText.slice(-1200) };
  });

  console.log(JSON.stringify(state, null, 2));
  await browser.close();
})();
JS
```

If the phrase appears in the dictation UI, the next step is to click `Submit dictation` and inspect whether dictation service places the text into the composer or directly sends it. Do that only after confirming the draft text is correct; otherwise cancel dictation with `Escape` or `Cancel dictation`.

### Restore Normal Browser Mode

After the test, return Chromium to the normal non-fake-media launch:

```bash
chrome_pid="$(ss -ltnp | awk '/127.0.0.1:9222/ {print $NF}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$chrome_pid" ]; then
  kill "$chrome_pid"
fi

DISPLAY=:95 setsid ~/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome \
  --user-data-dir=~/takeout-browser/profile \
  --remote-debugging-port=9222 \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --window-size=1400,1000 \
  --no-sandbox \
  DICTATION_SERVICE_URL/c/6a1a3995-2d40-8323-8741-d24b031e041c \
  > ~/takeout-browser/logs/chrome.log 2>&1 < /dev/null &
```

Restore any missing tabs if needed using `/tmp/rpc-chromium-tabs-before-audio-test.txt`.

## Durable Virtual Microphone Path

For repeated arbitrary audio, a virtual microphone is better than Chrome's launch-time fake WAV file.

Desired architecture:

```text
audio file / stream
  -> ffmpeg or player
  -> virtual microphone source
  -> Chromium getUserMedia({ audio: true })
  -> dictation service dictation
```

Possible implementations:

- PulseAudio or PipeWire virtual source.
- ALSA loopback device with routing into Chromium.
- A browser launched with a controlled fake-audio file for each test case.

The PulseAudio/PipeWire version is operationally cleanest if the node has those services:

```text
create virtual sink/source
set it as Chromium's default input
play audio into the monitor/source
start dictation service dictation
submit or cancel after transcription
```

This needs more system setup than the fake-WAV test. The current quick checks did not find an active `pactl` setup or ALSA capture device, so this is a separate environment task.

## Cleanup Performed

After the fake-media test:

- dictation was cancelled with `Escape` / cancel control,
- Chromium was restarted back to the normal non-fake-media launch,
- duplicate restored dictation service tabs were closed,
- the final tab list was back to one dictation service tab plus the pre-existing non-dictation service tabs,
- media state returned to no microphone:

```json
{
  "micPermission": "prompt",
  "devices": [],
  "getUserMedia": {
    "ok": false,
    "name": "NotFoundError",
    "message": "Requested device not found"
  }
}
```

## Useful DevTools Probes

List audio controls:

```bash
cd ~/takeout-browser && node - <<'JS'
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');
(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const page = browser.contexts()[0].pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  const controls = await page.evaluate(() => {
    const visible = (el) => {
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
    };
    return [...document.querySelectorAll('button,[role="button"]')]
      .filter(visible)
      .map(el => ({
        aria: el.getAttribute('aria-label') || '',
        testid: el.getAttribute('data-testid') || '',
        text: (el.innerText || '').trim()
      }))
      .filter(b => /dictat|voice|mic|microphone|record|audio|stop|cancel|submit/i.test(`${b.aria} ${b.testid} ${b.text}`));
  });
  console.log(JSON.stringify(controls, null, 2));
  await browser.close();
})();
JS
```

Probe browser media state:

```bash
cd ~/takeout-browser && node - <<'JS'
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');
(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const page = browser.contexts()[0].pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  const state = await page.evaluate(async () => {
    const micPermission = await navigator.permissions.query({ name: 'microphone' }).then(p => p.state).catch(e => `error: ${e.message}`);
    const devices = await navigator.mediaDevices.enumerateDevices().then(ds => ds.map(d => ({ kind: d.kind, label: d.label }))).catch(e => [{ error: e.message }]);
    const gum = await navigator.mediaDevices.getUserMedia({ audio: true })
      .then(stream => {
        const tracks = stream.getTracks().map(t => ({ kind: t.kind, label: t.label, readyState: t.readyState }));
        stream.getTracks().forEach(t => t.stop());
        return { ok: true, tracks };
      })
      .catch(e => ({ ok: false, name: e.name, message: e.message }));
    return { micPermission, devices, gum };
  });
  console.log(JSON.stringify(state, null, 2));
  await browser.close();
})();
JS
```

## What This Means For `CB`

`CB` does not use dictation. It inserts text into the dictation service composer through Playwright and is not blocked by missing microphone devices.

Dictation is useful only for browser-side speech input. If the goal is voice-to-chat through the CLI, the better architecture is probably:

```text
audio source -> local speech-to-text -> text -> CB / dictation service composer
```

That avoids depending on dictation service web dictation UI state and browser microphone plumbing.

## Next Options

To test real transcription, one of these is needed:

- a real microphone device exposed to Chromium on RPC,
- a PulseAudio/PipeWire virtual microphone source,
- a Chrome fake-audio WAV file with spoken content via `--use-file-for-fake-audio-capture=/path/to/file.wav`,
- or a separate local speech-to-text path outside dictation service web.

The current RPC install has `ffmpeg`, but no obvious local text-to-speech command such as `espeak`, `espeak-ng`, `pico2wave`, or `festival` was found during this test.
