'use strict';
// Web dictation backend. Two modes, both serialized onto the single composer/mic:
//   - batch : transcribe(buf)                       -> paplay a full WAV, submit, scrape
//   - stream: startStream()/pushAudio()/stopStream() -> pacat live PCM into the mic, submit, scrape
// Audio is injected into the PulseAudio virtual mic (sink "virtmic").

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

function loadPlaywrightCore() {
  const mod = process.env.WISPR_PLAYWRIGHT_CORE_PATH || 'playwright-core';
  try {
    return require(mod);
  } catch (e) {
    const hint = process.env.WISPR_PLAYWRIGHT_CORE_PATH
      ? `WISPR_PLAYWRIGHT_CORE_PATH=${process.env.WISPR_PLAYWRIGHT_CORE_PATH}`
      : 'install playwright-core or set WISPR_PLAYWRIGHT_CORE_PATH';
    e.message = `failed to load playwright-core (${hint}): ${e.message}`;
    throw e;
  }
}
const { chromium } = loadPlaywrightCore();

const CDP = process.env.DICTATE_CDP || 'http://127.0.0.1:9223';
const SINK = process.env.DICTATE_SINK || 'virtmic';
const XDG = process.env.XDG_RUNTIME_DIR || '/run/user/1000';
const BASE_CDP_PORT = Number(process.env.DICTATE_CDP_PORT || 9223);

// Internal batch lanes (k = 1..WISPR_LANES): each is its own Chromium (CDP BASE_CDP_PORT+k) feeding
// its own virtual mic (virtmic{k}). The live frontend (streaming) always stays on lane 0 (CDP/SINK
// above); the batch /transcribe path fans out across these lanes so internal callers run concurrently
// and never block — or cross-talk with — the frontend. WISPR_LANES unset/0 = legacy single-backend
// behavior (batch shares lane 0). Each lane has its own logged-in profile + tiled window on :95.
const INTERNAL_LANES = Math.max(0, Number(process.env.WISPR_LANES || 0));
const _lanes = [];
for (let k = 1; k <= INTERNAL_LANES; k++) {
  _lanes.push({ id: k, cdp: `http://127.0.0.1:${BASE_CDP_PORT + k}`, sink: `virtmic${k}`, browser: null, page: null, busy: false });
}
function acquireLane() { const l = _lanes.find(x => !x.busy); if (l) { l.busy = true; } return l || null; }
function internalPoolFull() { return _lanes.length > 0 && _lanes.every(l => l.busy); }
// Whether a *batch* (/transcribe) request would be rejected right now: all internal lanes busy, or —
// with no lanes provisioned — the single lane-0 backend is busy. Streaming uses isBusy() (lane 0).
function batchBusy() { return INTERNAL_LANES > 0 ? internalPoolFull() : _busy; }
// Stop drain (see COORDINATION 2026-06-08/09). On Stop we must let the unplayed tail actually render
// into the mic before clicking Submit, or the last words are cropped.
//   - default 'drain' mode: close pacat's stdin and wait for its REAL drain-complete (pa_stream_drain
//     on EOF -> process exit). Correct by construction regardless of pacat startup delay / underruns.
//   - 'bytes' mode (STREAM_DRAIN_MODE=bytes): estimate the tail as audio_written - elapsed and wait
//     that + margin, skipping pacat's ~0.9s teardown. Lower latency but it UNDER-waits when pacat's
//     startup delay exceeds the margin -> intermittent end-clip. Opt-in only.
//   - STREAM_SUBMIT_SETTLE_MS : brief pause after the tail is rendered so the dictation service finalizes it.
//   - STREAM_TAIL_MARGIN_MS   : ('bytes' mode) safety margin over the estimated tail.
//   - STREAM_DRAIN_MAX_MS     : hard cap on the drain wait (safety net for a wedged pacat).
const STREAM_DRAIN_MODE = (process.env.STREAM_DRAIN_MODE || 'drain').toLowerCase();
const STREAM_DRAIN_MAX_MS = Number(process.env.STREAM_DRAIN_MAX_MS || 15000);
const STREAM_SUBMIT_SETTLE_MS = Number(process.env.STREAM_SUBMIT_SETTLE_MS || 250);
const STREAM_TAIL_MARGIN_MS = Number(process.env.STREAM_TAIL_MARGIN_MS || 200);
const EMPTY_TRANSCRIPT_SETTLE_MS = Number(process.env.EMPTY_TRANSCRIPT_SETTLE_MS || 1200);
const BYTES_PER_MS = 48000 * 2 / 1000; // 96 — s16le, mono, 48 kHz
const sleep = ms => new Promise(r => setTimeout(r, ms));
function makeAbortError() { const e = new Error('client disconnected'); e.code = 'client_closed'; return e; }
function makeBackendUnavailable(message) { const e = new Error(message); e.code = 'backend_unavailable'; return e; }
function throwIfAborted(signal) { if (signal && signal.aborted) throw makeAbortError(); }
function abortableSleep(ms, signal) {
  if (!signal) return sleep(ms);
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(makeAbortError()); return; }
    const timer = setTimeout(done, ms);
    function done() {
      signal.removeEventListener('abort', aborted);
      resolve();
    }
    function aborted() {
      clearTimeout(timer);
      signal.removeEventListener('abort', aborted);
      reject(makeAbortError());
    }
    signal.addEventListener('abort', aborted, { once: true });
  });
}

// --- single-flight mutex (one composer + one mic), no server-side queue -----
let _busy = false;
function busyError() { const e = new Error('dictation backend is busy; retry shortly'); e.code = 'busy'; return e; }
function acquireNow() { if (_busy) throw busyError(); _busy = true; }
function tryAcquire() { if (_busy) return false; _busy = true; return true; }
function release() { _busy = false; }

// --- last-dictation result (surfaced in /healthz as lastDictation) ----------
let _last = null;
function recordResult(ok, ms, error) { _last = { ok, ms, at: new Date().toISOString(), ...(error ? { error } : {}) }; }
function lastResult() { return _last; }

// --- browser page (reused; reconnects if dropped) ---------------------------
let _browser = null, _page = null;
const DICTATION_SERVICE_URL = normalizeDictationServiceURL(process.env.DICTATION_SERVICE_URL || '');
function normalizeDictationServiceURL(raw) {
  const value = raw.trim();
  if (!value) throw new Error('DICTATION_SERVICE_URL is required');
  const url = new URL(value);
  if (!/^https?:$/.test(url.protocol)) throw new Error('DICTATION_SERVICE_URL must be http(s)');
  url.hash = '';
  return url.href.endsWith('/') ? url.href : `${url.href}/`;
}
const isDictationServicePage = page => page && !page.isClosed() && page.url().startsWith(DICTATION_SERVICE_URL);
const isBlankPage = page => {
  if (!page || page.isClosed()) return false;
  const url = page.url();
  return url === 'about:blank' || url === 'chrome://new-tab-page/' || url === 'chrome://newtab/';
};

async function normalizeServicePages(ctx, preferred = null) {
  let pages = ctx.pages().filter(p => !p.isClosed());
  let servicePages = pages.filter(isDictationServicePage);
  let page = isDictationServicePage(preferred) ? preferred : servicePages[0];

  if (!page) {
    page = pages.find(isBlankPage) || await ctx.newPage();
    if (!isDictationServicePage(page)) await page.goto(DICTATION_SERVICE_URL);
  }

  servicePages = ctx.pages().filter(isDictationServicePage);
  const duplicateServicePages = servicePages.filter(p => p !== page);
  if (duplicateServicePages.length) console.warn(`[wispr-dictate] closing ${duplicateServicePages.length} duplicate dictation service tab(s)`);
  await Promise.all(duplicateServicePages.map(p => p.close().catch(() => {})));

  const blankPages = ctx.pages().filter(p => p !== page && isBlankPage(p));
  await Promise.all(blankPages.map(p => p.close().catch(() => {})));
  return page;
}

async function getPage() {
  if (_page && !_page.isClosed()) {
    try {
      await _page.evaluate(() => 1);
      _page = await normalizeServicePages(_page.context(), _page);
      return _page;
    } catch (_) {
      _page = null;
    }
  }
  if (_browser) { try { await _browser.close(); } catch (_) {} _browser = null; }
  _browser = await chromium.connectOverCDP(CDP, { timeout: 10000 });
  const ctx = _browser.contexts()[0];
  _page = await normalizeServicePages(ctx);
  return _page;
}

// Same as getPage() but for an internal batch lane (its own CDP endpoint + cached browser/page).
async function getLanePage(lane) {
  if (lane.page && !lane.page.isClosed()) {
    try {
      await lane.page.evaluate(() => 1);
      lane.page = await normalizeServicePages(lane.page.context(), lane.page);
      return lane.page;
    } catch (_) { lane.page = null; }
  }
  if (lane.browser) { try { await lane.browser.close(); } catch (_) {} lane.browser = null; }
  lane.browser = await chromium.connectOverCDP(lane.cdp, { timeout: 10000 });
  lane.page = await normalizeServicePages(lane.browser.contexts()[0]);
  return lane.page;
}

const composerText = page => page.evaluate(() => {
  const c = document.querySelector('#prompt-textarea');
  return c ? (c.innerText || c.textContent || '').trim() : '';
});
const dictationUIState = page => page.evaluate(() => {
  const visible = el => {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  };
  const controls = [...document.querySelectorAll('button[aria-label],[role="button"][aria-label]')]
    .filter(visible)
    .map(el => ({
      label: el.getAttribute('aria-label') || '',
      disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true'
    }));
  const hasEnabled = re => controls.some(c => re.test(c.label) && !c.disabled);
  const hasAny = re => controls.some(c => re.test(c.label));
  const hasDisabled = re => controls.some(c => re.test(c.label) && c.disabled);
  const c = document.querySelector('#prompt-textarea');
  const submit = hasEnabled(/^Submit dictation$/i);
  const cancel = hasEnabled(/^Cancel dictation$/i);
  const transcribing = hasAny(/^Transcribing dictation$/i);
  const cancelDisabled = hasDisabled(/^Cancel dictation$/i);
  return {
    text: c ? (c.innerText || c.textContent || '').trim() : '',
    start: hasEnabled(/^Start dictation$/i),
    submit,
    cancel,
    recording: submit && cancel,
    transcribing,
    cancelDisabled,
    submitted: transcribing || cancelDisabled
  };
});

async function waitForUIState(page, predicate, timeoutMs, signal, intervalMs = 100) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    throwIfAborted(signal);
    last = await dictationUIState(page);
    if (predicate(last)) return last;
    await abortableSleep(intervalMs, signal);
  }
  return last || await dictationUIState(page);
}

async function clickVisible(page, selector, timeout = 2000) {
  const loc = page.locator(`${selector}:visible`).first();
  if (await loc.count().catch(() => 0)) {
    await loc.click({ timeout });
    return true;
  }
  return false;
}

const KNOWN_BLOCKING_MODALS = [
  '#modal-subscription-failure',
  '[data-testid="modal-subscription-failure"]'
];

function blockerLabel(blocker) {
  if (!blocker) return 'unknown browser overlay';
  if (blocker.kind === 'subscription_failure') return 'dictation service subscription failure modal';
  if (blocker.id) return `browser overlay #${blocker.id}`;
  if (blocker.testid) return `browser overlay ${blocker.testid}`;
  return 'browser overlay';
}

async function blockingModalState(page) {
  return page.evaluate((knownSelectors) => {
    const visible = el => {
      if (!el) return false;
      const style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
      const r = el.getBoundingClientRect();
      return r.width > 1 && r.height > 1;
    };
    const details = (kind, el) => ({
      kind,
      id: el.id || '',
      testid: el.getAttribute('data-testid') || '',
      role: el.getAttribute('role') || ''
    });

    for (const sel of knownSelectors) {
      const el = document.querySelector(sel);
      if (visible(el)) return details('subscription_failure', el);
    }

    const target = document.querySelector('button[aria-label="Start dictation"],button[aria-label="Submit dictation"]');
    if (!visible(target)) return null;
    const r = target.getBoundingClientRect();
    const x = Math.max(0, Math.min(window.innerWidth - 1, r.left + r.width / 2));
    const y = Math.max(0, Math.min(window.innerHeight - 1, r.top + r.height / 2));
    const top = document.elementFromPoint(x, y);
    if (!top || top === target || target.contains(top)) return null;

    const overlay = top.closest('[id^="modal-"],[data-testid*="modal"],[data-testid*="Modal"],[role="dialog"],[data-state="open"]');
    if (!overlay || overlay === target || target.contains(overlay) || !visible(overlay)) return null;
    return details('blocking_overlay', overlay);
  }, KNOWN_BLOCKING_MODALS);
}

async function dismissBlockingModal(page) {
  const before = await blockingModalState(page);
  if (!before) return null;
  const closeSelectors = [
    '#modal-subscription-failure button[aria-label="Close"]',
    '[data-testid="modal-subscription-failure"] button[aria-label="Close"]',
    '#modal-subscription-failure [role="button"][aria-label="Close"]',
    '[data-testid="modal-subscription-failure"] [role="button"][aria-label="Close"]',
    '#modal-subscription-failure button:has-text("Close")',
    '[data-testid="modal-subscription-failure"] button:has-text("Close")',
    '#modal-subscription-failure button:has-text("Not now")',
    '[data-testid="modal-subscription-failure"] button:has-text("Not now")',
    'button[aria-label="Close"]'
  ];
  for (const sel of closeSelectors) {
    try {
      await page.locator(sel).first().click({ timeout: 800 });
      await sleep(250);
      const after = await blockingModalState(page);
      if (!after) return null;
    } catch (_) {}
  }
  try {
    await page.keyboard.press('Escape');
    await sleep(250);
  } catch (_) {}
  return blockingModalState(page);
}

async function ensureDictationUnblocked(page) {
  let blocker = await blockingModalState(page);
  if (!blocker) return;
  console.warn(`[wispr-dictate] ${blockerLabel(blocker)} blocks dictation; trying to dismiss`);
  blocker = await dismissBlockingModal(page);
  if (blocker) throw makeBackendUnavailable(`Dictation service is blocked by ${blockerLabel(blocker)}`);
}

async function clearComposer(page) {
  try { await page.click('#prompt-textarea', { timeout: 4000 }); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace'); } catch (_) {}
}
// self-heal: if a previous run left dictation active (e.g. client abandoned), cancel it, then clear.
async function resetDictation(page, signal) {
  const st = await dictationUIState(page).catch(() => ({}));
  if (st.submitted) {
    console.warn('[wispr-dictate] reset: dictation is already transcribing; waiting before next run');
    await waitForUIState(page, s => !s.submitted, 30000, signal).catch(() => null);
  }
  const afterWait = await dictationUIState(page).catch(() => ({}));
  if (afterWait.recording || afterWait.cancel || afterWait.submit) {
    console.warn('[wispr-dictate] reset: active dictation controls visible; cancelling before next run');
    const clicked = await clickVisible(page, 'button[aria-label="Cancel dictation"]').catch(() => false);
    if (!clicked) {
      try { await page.keyboard.press('Escape'); } catch (_) {}
    }
    await waitForUIState(page, s => !s.cancel && !s.submit, 5000, signal).catch(() => null);
  }
  await clearComposer(page);
}

// --- audio injectors --------------------------------------------------------
function killProcessTree(child, signal) {
  if (!child || !child.pid) return;
  try { process.kill(-child.pid, signal); return; } catch (_) {}
  try { child.kill(signal); } catch (_) {}
}

function playWavFile(file, durationMs = 0, signal, sink = SINK) {
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) { reject(makeAbortError()); return; }
    const p = spawn('paplay', ['--device=' + sink, file], { env: { ...process.env, XDG_RUNTIME_DIR: XDG }, detached: true });
    let settled = false;
    let err = ''; p.stderr.on('data', d => (err += d));
    const timeoutMs = Math.max(15000, Math.min(700000, Number(durationMs || 0) + 15000));
    let timer = null;
    let killTimer = null;
    const cleanup = () => {
      if (timer) clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      if (signal) signal.removeEventListener('abort', onAbort);
    };
    const stopPlayback = () => {
      killProcessTree(p, 'SIGTERM');
      killTimer = setTimeout(() => killProcessTree(p, 'SIGKILL'), 1000);
    };
    const fail = e => {
      if (settled) return;
      settled = true;
      cleanup();
      stopPlayback();
      reject(e);
    };
    const onAbort = () => fail(makeAbortError());
    timer = setTimeout(() => {
      const e = new Error('audio playback timed out');
      e.code = 'transcription_timeout';
      fail(e);
    }, timeoutMs);
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
    p.on('error', e => fail(e));
    p.on('close', c => {
      if (settled) return;
      settled = true; cleanup();
      if (c === 0) resolve();
      else reject(new Error('paplay exit ' + c + ': ' + err.trim()));
    });
  });
}
const spawnPacat = () => spawn('pacat',
  ['--playback', '--raw', '--rate=48000', '--format=s16le', '--channels=1',
    '--latency-msec=20', '--process-time-msec=10', '--device=' + SINK],
  { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });

async function startDictation(page, signal) {
  throwIfAborted(signal);
  await ensureDictationUnblocked(page);
  await resetDictation(page, signal);
  throwIfAborted(signal);
  await ensureDictationUnblocked(page);
  try {
    const st = await waitForUIState(page, s => s.start, 5000, signal);
    if (!st.start) throw new Error('Start dictation control not visible');
    await page.locator('[aria-label="Start dictation"]:visible').first().click({ timeout: 5000 });
  } catch (e) {
    const blocker = await blockingModalState(page).catch(() => null);
    if (blocker) throw makeBackendUnavailable(`Dictation service is blocked by ${blockerLabel(blocker)}`);
    throw e;
  }
  throwIfAborted(signal);
  try {
    const st = await waitForUIState(page, s => s.submit || s.cancel, 8000, signal);
    if (!st.submit && !st.cancel) throw new Error('dictation controls did not enter recording state');
  } catch (e) {
    const blocker = await blockingModalState(page).catch(() => null);
    if (blocker) throw makeBackendUnavailable(`Dictation service is blocked by ${blockerLabel(blocker)}`);
    throw e;
  }
}
async function submitAndScrape(page, timeoutMs = 40000, signal, hooks = {}) {
  throwIfAborted(signal);
  let submitted = false;
  let lastSubmitClick = 0;
  const clickSubmit = async (reason) => {
    const clicked = await clickVisible(page, 'button[aria-label="Submit dictation"]', 3000).catch(() => false);
    if (clicked) {
      lastSubmitClick = Date.now();
      console.log(`[wispr-dictate] submit click (${reason})`);
    }
    return clicked;
  };
  await clickSubmit('initial');
  const deadline = Date.now() + timeoutMs;
  let text = '';
  let doneSince = 0;
  let emptyWaitLogged = false;
  while (Date.now() < deadline) {
    throwIfAborted(signal);
    const st = await dictationUIState(page);
    if (!submitted && st.submitted) {
      submitted = true;
      try { hooks.onSubmitted?.(); } catch (_) {}
    }

    if (st.submitted) {
      doneSince = 0;
      await abortableSleep(250, signal);
      continue;
    }

    if (st.recording || st.submit || st.cancel) {
      doneSince = 0;
      if (st.submit && Date.now() - lastSubmitClick > 2000) await clickSubmit('still-recording');
      await abortableSleep(250, signal);
      continue;
    }

    if (!submitted) {
      submitted = true;
      try { hooks.onSubmitted?.(); } catch (_) {}
    }

    text = st.text;
    if (text) {
      break;
    } else if (st.start) {
      doneSince ||= Date.now();
      if (!emptyWaitLogged) {
        console.log(`[wispr-dictate] submitted UI returned to idle with empty text; debouncing ${EMPTY_TRANSCRIPT_SETTLE_MS}ms`);
        emptyWaitLogged = true;
      }
      if (Date.now() - doneSince >= EMPTY_TRANSCRIPT_SETTLE_MS) break;
    } else {
      doneSince = 0;
    }
    await abortableSleep(st.start ? 100 : 250, signal);
  }
  if (!text) text = await composerText(page);
  await clearComposer(page);
  return text;
}

// --- batch mode -------------------------------------------------------------
async function transcribe(audioBuffer) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wispr-dictate-'));
  fs.chmodSync(tmpDir, 0o700);
  const tmp = path.join(tmpDir, 'audio.wav');
  fs.writeFileSync(tmp, audioBuffer, { mode: 0o600 });
  try { return await transcribeFile(tmp); }
  finally { try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) {} }
}

async function transcribeFile(file, audio = {}, options = {}) {
  // Batch fans out across internal lanes (1..N); if none are provisioned, fall back to lane 0 (the
  // legacy single-backend path, shared with streaming via the _busy mutex).
  const lane = INTERNAL_LANES > 0 ? acquireLane() : null;
  if (INTERNAL_LANES > 0 && !lane) { const e = new Error('all transcription lanes busy'); e.code = 'busy'; throw e; }
  if (!lane) acquireNow();
  const durationMs = Number(audio.durationMs || 0);
  const t0 = Date.now();
  const laneLabel = lane ? `lane=${lane.id}` : 'lane=0';
  const signal = options.signal;
  let page = null;
  try {
    throwIfAborted(signal);
    page = lane ? await getLanePage(lane) : await getPage();
    console.log(`[wispr-dictate] batch ${laneLabel} start duration=${Math.round(durationMs)}ms`);
    await startDictation(page, signal);
    await playWavFile(file, durationMs, signal, lane ? lane.sink : SINK);
    await abortableSleep(1200, signal);
    const scrapeMs = Math.max(40000, Math.min(180000, Math.round(durationMs * 0.25) + 30000));
    const text = await submitAndScrape(page, scrapeMs, signal);
    console.log(`[wispr-dictate] batch ${laneLabel} final text=${text ? text.length : 0} ms=${Date.now() - t0}`);
    recordResult(!!(text && text.length), Date.now() - t0, text ? undefined : 'empty transcript');
    return text;
  } catch (e) {
    if (page && (e.code === 'client_closed' || (signal && signal.aborted))) {
      try { await resetDictation(page); } catch (_) {}
    }
    recordResult(false, Date.now() - t0, e.message);
    throw e;
  } finally {
    if (lane) lane.busy = false; else release();
  }
}

// --- streaming mode ---------------------------------------------------------
async function startStream() {
  if (!tryAcquire()) { const e = new Error('busy'); e.code = 'busy'; throw e; }
  const t0 = Date.now();
  try {
    const page = await getPage();
    await startDictation(page);
    const pacat = spawnPacat();
    pacat.on('error', () => {});
    return { page, pacat, t0: Date.now(), bytesWritten: 0, firstAudioAt: 0 };
  } catch (e) {
    recordResult(false, Date.now() - t0, `stream start failed: ${e.message}`);
    console.warn(`[wispr-dictate] stream start failed: ${e.stack || e.message}`);
    release();
    throw e;
  }
}
function pushAudio(s, buf) {
  try {
    if (s && s.pacat && s.pacat.stdin.writable) {
      s.pacat.stdin.write(buf);
      if (!s.firstAudioAt) s.firstAudioAt = Date.now();
      s.bytesWritten = (s.bytesWritten || 0) + buf.length; // total audio handed to pacat (will be played)
    }
  } catch (_) {}
}
async function stopStream(s, hooks = {}) {
  try {
    const drainStarted = Date.now();
    let mode, tailMs = 0, waitMs = 0;
    if (STREAM_DRAIN_MODE === 'bytes') {
      // Opt-in low-latency estimate: unplayed tail ~= audio_written - elapsed. Skips pacat's teardown
      // but UNDER-waits when pacat's startup delay exceeds the margin -> intermittent end-clip.
      mode = 'bytes';
      const wroteMs = (s.bytesWritten || 0) / BYTES_PER_MS;
      const playedMs = s.firstAudioAt ? (Date.now() - s.firstAudioAt) : 0;
      tailMs = Math.max(0, Math.round(wroteMs - playedMs));
      waitMs = Math.min(STREAM_DRAIN_MAX_MS, tailMs + STREAM_TAIL_MARGIN_MS);
      try { s.pacat.stdin.end(); } catch (_) {}
      await sleep(waitMs);
      console.log(`[wispr-dictate] drain est wrote=${Math.round(wroteMs)}ms played=${playedMs}ms tail=${tailMs}ms wait=${waitMs}ms bytes=${s.bytesWritten || 0}`);
    } else {
      // Default: EOF the pipe and wait for pacat's REAL drain-complete (pa_stream_drain on EOF ->
      // process close), i.e. until PulseAudio has actually rendered every buffered sample into the mic.
      // Correct regardless of pacat startup delay / network underruns — no end-clip. The cap is only a
      // safety net for a wedged pacat.
      mode = 'drain';
      await new Promise(res => { try { s.pacat.stdin.end(res); } catch (_) { res(); } });
      await Promise.race([ new Promise(res => s.pacat.once('close', res)), sleep(STREAM_DRAIN_MAX_MS) ]);
    }
    // Brief settle so the streaming recognizer finalizes the just-rendered tail before Submit.
    if (STREAM_SUBMIT_SETTLE_MS > 0) await sleep(STREAM_SUBMIT_SETTLE_MS);
    const drainMs = Date.now() - drainStarted;
    const text = await submitAndScrape(s.page, 40000, undefined, {
      onSubmitted: hooks.onSubmitting
    });
    console.log(`[wispr-dictate] stream stop drain=${drainMs}ms mode=${mode} tail=${tailMs}ms text=${text ? text.length : 0}`);
    recordResult(!!(text && text.length), Date.now() - s.t0, text ? undefined : 'empty transcript');
    return { text, duration_ms: Date.now() - s.t0 };
  } catch (e) { recordResult(false, Date.now() - s.t0, e.message); throw e; }
  finally { try { s.pacat.kill(); } catch (_) {} release(); }
}
async function abortStream(s) {
  try { s.pacat.kill(); } catch (_) {}
  try { await resetDictation(s.page); } catch (_) {}
  release();
}

// --- read-only health probe (independent of the transcribe mutex/page) ------
function isBusy() { return _busy; }
async function probe() {
  let b;
  try {
    b = await chromium.connectOverCDP(CDP, { timeout: 4000 });
    const page = await normalizeServicePages(b.contexts()[0]);
    const blocker = await blockingModalState(page);
    const st = await page.evaluate(() => {
      const txt = el => (el.innerText || el.textContent || '').trim();
      const loggedOut = [...document.querySelectorAll('button,a,[role="button"]')].some(e => /^log in$|^sign up for free$/i.test(txt(e)));
      const dict = !!document.querySelector('button[aria-label="Start dictation"],button[aria-label="Submit dictation"],button[aria-label="Transcribing dictation"]');
      return { loggedOut, dict };
    });
    if (blocker) return { browser: 'up', dictationService: 'blocked', blocker: blockerLabel(blocker) };
    return { browser: 'up', dictationService: st.loggedOut ? 'logged_out' : (st.dict ? 'ready' : 'loading') };
  } catch (_) {
    return { browser: 'down', dictationService: 'unreachable' };
  } finally { try { await b.close(); } catch (_) {} }
}

module.exports = { transcribe, transcribeFile, startStream, pushAudio, stopStream, abortStream, probe, isBusy, batchBusy, lastResult };

if (require.main === module) {
  const wav = process.argv[2];
  if (!wav) { console.error('usage: node dictate.js <wav>'); process.exit(1); }
  const t0 = Date.now();
  transcribe(fs.readFileSync(wav))
    .then(t => { console.log(`(${Date.now() - t0}ms) TRANSCRIPT: ${JSON.stringify(t)}`); process.exit(0); })
    .catch(e => { console.error('ERR', e.stack || e.message); process.exit(1); });
}
