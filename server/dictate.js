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
const STREAM_DRAIN_GRACE_MS = Number(process.env.STREAM_DRAIN_GRACE_MS || 1300);
const sleep = ms => new Promise(r => setTimeout(r, ms));

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
async function getPage() {
  if (_page && !_page.isClosed()) { try { await _page.evaluate(() => 1); return _page; } catch (_) { _page = null; } }
  if (_browser) { try { await _browser.close(); } catch (_) {} _browser = null; }
  _browser = await chromium.connectOverCDP(CDP, { timeout: 10000 });
  const ctx = _browser.contexts()[0];
  _page = ctx.pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  if (!_page) { _page = await ctx.newPage(); await _page.goto('DICTATION_SERVICE_URL/'); }
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
function playWavFile(file, durationMs = 0) {
  return new Promise((resolve, reject) => {
    const p = spawn('paplay', ['--device=' + SINK, file], { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });
    let settled = false;
    let err = ''; p.stderr.on('data', d => (err += d));
    const timeoutMs = Math.max(15000, Math.min(700000, Number(durationMs || 0) + 15000));
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { p.kill('SIGKILL'); } catch (_) {}
      const e = new Error('audio playback timed out');
      e.code = 'transcription_timeout';
      reject(e);
    }, timeoutMs);
    p.on('error', e => {
      if (settled) return;
      settled = true; clearTimeout(timer); reject(e);
    });
    p.on('close', c => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (c === 0) resolve();
      else reject(new Error('paplay exit ' + c + ': ' + err.trim()));
    });
  });
}
const spawnPacat = () => spawn('pacat',
  ['--playback', '--raw', '--rate=48000', '--format=s16le', '--channels=1',
    '--latency-msec=20', '--process-time-msec=10', '--device=' + SINK],
  { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });

async function startDictation(page) {
  await resetDictation(page);
  await page.click('[aria-label="Start dictation"]', { timeout: 8000 });
  await page.waitForSelector('[aria-label="Submit dictation"]', { timeout: 8000 });
}
async function submitAndScrape(page, timeoutMs = 40000) {
  const submit = await page.$('[aria-label="Submit dictation"]');
  if (submit) await submit.click({ timeout: 8000 }).catch(() => {});
  const deadline = Date.now() + timeoutMs;
  let text = '';
  let doneSince = 0;
  while (Date.now() < deadline) {
    const st = await dictationUIState(page);
    text = st.text;
    if (text) break;
    if (st.submit || st.cancel) {
      doneSince = 0;
    } else if (st.start) {
      doneSince ||= Date.now();
      if (Date.now() - doneSince >= 800) break;
    }
    await sleep(st.start ? 100 : 250);
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

async function transcribeFile(file, audio = {}) {
  acquireNow();
  const durationMs = Number(audio.durationMs || 0);
  const t0 = Date.now();
  try {
    const page = await getPage();
    await startDictation(page);
    await playWavFile(file, durationMs);
    await sleep(1200);
    const scrapeMs = Math.max(40000, Math.min(180000, Math.round(durationMs * 0.25) + 30000));
    const text = await submitAndScrape(page, scrapeMs);
    recordResult(!!(text && text.length), Date.now() - t0, text ? undefined : 'empty transcript');
    return text;
  } catch (e) {
    recordResult(false, Date.now() - t0, e.message);
    throw e;
  } finally {
    release();
  }
}

// --- streaming mode ---------------------------------------------------------
async function startStream() {
  if (!tryAcquire()) { const e = new Error('busy'); e.code = 'busy'; throw e; }
  try {
    const page = await getPage();
    await startDictation(page);
    const pacat = spawnPacat();
    pacat.on('error', () => {});
    return { page, pacat, t0: Date.now() };
  } catch (e) { release(); throw e; }
}
function pushAudio(s, buf) { try { if (s && s.pacat && s.pacat.stdin.writable) s.pacat.stdin.write(buf); } catch (_) {} }
async function stopStream(s) {
  try {
    const drainStarted = Date.now();
    // Flush the pipe, but do not wait for pacat process exit; with low Pulse latency, a short
    // grace is enough and avoids making Stop feel like it has a multi-second dead zone.
    await new Promise(res => { try { s.pacat.stdin.end(res); } catch (_) { res(); } });
    await Promise.race([
      new Promise(res => s.pacat.once('close', res)),
      sleep(STREAM_DRAIN_GRACE_MS)
    ]);
    const drainMs = Date.now() - drainStarted;
    const text = await submitAndScrape(s.page);
    console.log(`[wispr-dictate] stream stop drain=${drainMs}ms text=${text ? text.length : 0}`);
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
    const page = b.contexts()[0].pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
    if (!page) return { browser: 'up', dictationService: 'no-tab' };
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
