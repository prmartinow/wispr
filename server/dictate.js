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
const sleep = ms => new Promise(r => setTimeout(r, ms));

// --- single-flight mutex (one composer + one mic) ---------------------------
let _busy = false; const _q = [];
function acquire() { return new Promise(res => { const t = () => { _busy = true; res(); }; _busy ? _q.push(t) : t(); }); }
function tryAcquire() { if (_busy) return false; _busy = true; return true; }
function release() { _busy = false; const n = _q.shift(); if (n) n(); }

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
async function clearComposer(page) {
  try { await page.click('#prompt-textarea', { timeout: 4000 }); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace'); } catch (_) {}
}
// self-heal: if a previous run left dictation active (e.g. client abandoned), cancel it, then clear.
async function resetDictation(page) {
  try { const c = await page.$('[aria-label="Cancel dictation"]'); if (c) { await c.click().catch(() => {}); await sleep(400); } } catch (_) {}
  await clearComposer(page);
}

// --- audio injectors --------------------------------------------------------
function playWavFile(file) {
  return new Promise((resolve, reject) => {
    const p = spawn('paplay', ['--device=' + SINK, file], { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });
    let err = ''; p.stderr.on('data', d => (err += d));
    p.on('error', reject);
    p.on('close', c => (c === 0 ? resolve() : reject(new Error('paplay exit ' + c + ': ' + err.trim()))));
  });
}
const spawnPacat = () => spawn('pacat',
  ['--playback', '--raw', '--rate=48000', '--format=s16le', '--channels=1', '--device=' + SINK],
  { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });

async function startDictation(page) {
  await resetDictation(page);
  await page.click('[aria-label="Start dictation"]', { timeout: 8000 });
  await page.waitForSelector('[aria-label="Submit dictation"]', { timeout: 8000 });
}
async function submitAndScrape(page) {
  const submit = await page.$('[aria-label="Submit dictation"]');
  if (submit) await submit.click({ timeout: 8000 }).catch(() => {});
  let text = '';
  for (let i = 0; i < 40; i++) { text = await composerText(page); if (text) break; await sleep(500); }
  await clearComposer(page);
  return text;
}

// --- batch mode -------------------------------------------------------------
async function transcribe(audioBuffer) {
  await acquire();
  const tmp = path.join(os.tmpdir(), `dictate-${Date.now()}-${Math.random().toString(36).slice(2)}.wav`);
  fs.writeFileSync(tmp, audioBuffer);
  try {
    const page = await getPage();
    await startDictation(page);
    await playWavFile(tmp);
    await sleep(1200);
    return await submitAndScrape(page);
  } finally { fs.unlink(tmp, () => {}); release(); }
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
    // flush remaining PCM and let pulse drain it into the mic
    await new Promise(res => { let done = false; const fin = () => { if (!done) { done = true; res(); } };
      s.pacat.on('close', fin); try { s.pacat.stdin.end(); } catch (_) { fin(); } setTimeout(fin, 8000); });
    await sleep(2000); // dictation service finishes transcribing the tail still in the pulse buffer
    const text = await submitAndScrape(s.page);
    return { text, duration_ms: Date.now() - s.t0 };
  } finally { try { s.pacat.kill(); } catch (_) {} release(); }
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

module.exports = { transcribe, startStream, pushAudio, stopStream, abortStream, probe, isBusy };

if (require.main === module) {
  const wav = process.argv[2];
  if (!wav) { console.error('usage: node dictate.js <wav>'); process.exit(1); }
  const t0 = Date.now();
  transcribe(fs.readFileSync(wav))
    .then(t => { console.log(`(${Date.now() - t0}ms) TRANSCRIPT: ${JSON.stringify(t)}`); process.exit(0); })
    .catch(e => { console.error('ERR', e.stack || e.message); process.exit(1); });
}
