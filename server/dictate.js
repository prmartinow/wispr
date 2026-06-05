'use strict';
// dictation service web-dictation backend. Two modes, both serialized onto the single composer/mic:
//   - batch : transcribe(buf)                       -> paplay a full WAV, submit, scrape
//   - stream: startStream()/pushAudio()/stopStream() -> pacat live PCM into the mic, submit, scrape
// Audio is injected into the PulseAudio virtual mic (sink "virtmic"). Never sends to dictation service.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');

const CDP = process.env.DICTATE_CDP || 'http://127.0.0.1:9223';
const SINK = process.env.DICTATE_SINK || 'virtmic';
const XDG = process.env.XDG_RUNTIME_DIR || '/run/user/1000';
// We do NOT use a fixed drain delay. On stop we close pacat's stdin and wait for its *real*
// drain-complete (pa_stream_drain on EOF → process exit), which is exactly as long as the live
// stream is behind real time — no more, no less. These two bounds are only safety nets:
//   - STREAM_DRAIN_MAX_MS : hard cap so a wedged pacat can never hang Stop forever.
//   - STREAM_SUBMIT_SETTLE_MS : a brief pause after full playout so dictation service's streaming ASR can
//     ingest the just-played tail before we click Submit (the audio is in the mic; the recognizer
//     needs a beat to finalize it). Kept small; the heavy lifting is the real drain above.
const STREAM_DRAIN_MAX_MS = Number(process.env.STREAM_DRAIN_MAX_MS || 15000);
const STREAM_SUBMIT_SETTLE_MS = Number(process.env.STREAM_SUBMIT_SETTLE_MS || 400);
const sleep = ms => new Promise(r => setTimeout(r, ms));
function makeAbortError() { const e = new Error('client disconnected'); e.code = 'client_closed'; return e; }
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
const dictationService_URL = 'DICTATION_SERVICE_URL/';
const isdictationServicePage = page => page && !page.isClosed() && page.url().startsWith(dictationService_URL);
const isBlankPage = page => {
  if (!page || page.isClosed()) return false;
  const url = page.url();
  return url === 'about:blank' || url === 'chrome://new-tab-page/' || url === 'chrome://newtab/';
};

async function normalizeServicePages(ctx, preferred = null) {
  let pages = ctx.pages().filter(p => !p.isClosed());
  let chatPages = pages.filter(isdictationServicePage);
  let page = isdictationServicePage(preferred) ? preferred : chatPages[0];

  if (!page) {
    page = pages.find(isBlankPage) || await ctx.newPage();
    if (!isdictationServicePage(page)) await page.goto(dictationService_URL);
  }

  chatPages = ctx.pages().filter(isdictationServicePage);
  const duplicateChat = chatPages.filter(p => p !== page);
  if (duplicateChat.length) console.warn(`[wispr-dictate] closing ${duplicateChat.length} duplicate dictation service service tab(s)`);
  await Promise.all(duplicateChat.map(p => p.close().catch(() => {})));

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

const composerText = page => page.evaluate(() => {
  const c = document.querySelector('#prompt-textarea');
  return c ? (c.innerText || c.textContent || '').trim() : '';
});
const dictationUIState = page => page.evaluate(() => {
  const labels = [...document.querySelectorAll('[aria-label]')]
    .map(el => el.getAttribute('aria-label') || '');
  const has = re => labels.some(label => re.test(label));
  const c = document.querySelector('#prompt-textarea');
  return {
    text: c ? (c.innerText || c.textContent || '').trim() : '',
    start: has(/^Start dictation$/i),
    submit: has(/^Submit dictation$/i),
    cancel: has(/^Cancel dictation$/i)
  };
});
async function clearComposer(page) {
  try { await page.click('#prompt-textarea', { timeout: 4000 }); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace'); } catch (_) {}
}
// self-heal: if a previous run left dictation active (e.g. client abandoned), cancel it, then clear.
async function resetDictation(page) {
  try { const c = await page.$('[aria-label="Cancel dictation"]'); if (c) { await c.click().catch(() => {}); await sleep(400); } } catch (_) {}
  await clearComposer(page);
}

// --- audio injectors --------------------------------------------------------
function killProcessTree(child, signal) {
  if (!child || !child.pid) return;
  try { process.kill(-child.pid, signal); return; } catch (_) {}
  try { child.kill(signal); } catch (_) {}
}

function playWavFile(file, durationMs = 0, signal) {
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) { reject(makeAbortError()); return; }
    const p = spawn('paplay', ['--device=' + SINK, file], { env: { ...process.env, XDG_RUNTIME_DIR: XDG }, detached: true });
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
  await resetDictation(page);
  throwIfAborted(signal);
  await page.click('[aria-label="Start dictation"]', { timeout: 8000 });
  throwIfAborted(signal);
  await page.waitForSelector('[aria-label="Submit dictation"]', { timeout: 8000 });
}
async function submitAndScrape(page, timeoutMs = 40000, signal) {
  throwIfAborted(signal);
  const submit = await page.$('[aria-label="Submit dictation"]');
  if (submit) await submit.click({ timeout: 8000 }).catch(() => {});
  const deadline = Date.now() + timeoutMs;
  let text = '';
  let doneSince = 0;
  while (Date.now() < deadline) {
    throwIfAborted(signal);
    const st = await dictationUIState(page);
    text = st.text;
    if (text) break;
    if (st.submit || st.cancel) {
      doneSince = 0;
    } else if (st.start) {
      doneSince ||= Date.now();
      if (Date.now() - doneSince >= 800) break;
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
  acquireNow();
  const durationMs = Number(audio.durationMs || 0);
  const t0 = Date.now();
  const signal = options.signal;
  let page = null;
  try {
    throwIfAborted(signal);
    page = await getPage();
    await startDictation(page, signal);
    await playWavFile(file, durationMs, signal);
    await abortableSleep(1200, signal);
    const scrapeMs = Math.max(40000, Math.min(180000, Math.round(durationMs * 0.25) + 30000));
    const text = await submitAndScrape(page, scrapeMs, signal);
    recordResult(!!(text && text.length), Date.now() - t0, text ? undefined : 'empty transcript');
    return text;
  } catch (e) {
    if (page && (e.code === 'client_closed' || (signal && signal.aborted))) {
      try { await resetDictation(page); } catch (_) {}
    }
    recordResult(false, Date.now() - t0, e.message);
    throw e;
  } finally {
    release();
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
    return { page, pacat, t0: Date.now() };
  } catch (e) {
    recordResult(false, Date.now() - t0, `stream start failed: ${e.message}`);
    console.warn(`[wispr-dictate] stream start failed: ${e.stack || e.message}`);
    release();
    throw e;
  }
}
function pushAudio(s, buf) { try { if (s && s.pacat && s.pacat.stdin.writable) s.pacat.stdin.write(buf); } catch (_) {} }
async function stopStream(s) {
  try {
    const drainStarted = Date.now();
    // 1) EOF the pipe, then wait for pacat to finish *playing out* every buffered sample into the
    //    mic. pacat does pa_stream_drain on EOF and only emits 'close' once PulseAudio has rendered
    //    the whole backlog — so this waits exactly the amount the live stream is behind real time
    //    (the cap is a safety net for a wedged pacat, not a fixed delay).
    await new Promise(res => { try { s.pacat.stdin.end(res); } catch (_) { res(); } });
    let drainedCleanly = false;
    await Promise.race([
      new Promise(res => s.pacat.once('close', () => { drainedCleanly = true; res(); })),
      sleep(STREAM_DRAIN_MAX_MS)
    ]);
    // 2) Brief settle so dictation service's streaming recognizer finalizes the just-played tail before Submit.
    if (STREAM_SUBMIT_SETTLE_MS > 0) await sleep(STREAM_SUBMIT_SETTLE_MS);
    const drainMs = Date.now() - drainStarted;
    const text = await submitAndScrape(s.page);
    console.log(`[wispr-dictate] stream stop drain=${drainMs}ms clean=${drainedCleanly} text=${text ? text.length : 0}`);
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
    const st = await page.evaluate(() => {
      const txt = el => (el.innerText || el.textContent || '').trim();
      const loggedOut = [...document.querySelectorAll('button,a,[role="button"]')].some(e => /^log in$|^sign up for free$/i.test(txt(e)));
      const dict = !!document.querySelector('[aria-label="Start dictation"],[aria-label="Submit dictation"]');
      return { loggedOut, dict };
    });
    return { browser: 'up', dictationService: st.loggedOut ? 'logged_out' : (st.dict ? 'ready' : 'loading') };
  } catch (_) {
    return { browser: 'down', dictationService: 'unreachable' };
  } finally { try { await b.close(); } catch (_) {} }
}

module.exports = { transcribe, transcribeFile, startStream, pushAudio, stopStream, abortStream, probe, isBusy, lastResult };

if (require.main === module) {
  const wav = process.argv[2];
  if (!wav) { console.error('usage: node dictate.js <wav>'); process.exit(1); }
  const t0 = Date.now();
  transcribe(fs.readFileSync(wav))
    .then(t => { console.log(`(${Date.now() - t0}ms) TRANSCRIPT: ${JSON.stringify(t)}`); process.exit(0); })
    .catch(e => { console.error('ERR', e.stack || e.message); process.exit(1); });
}
