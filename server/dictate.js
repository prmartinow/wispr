'use strict';
// dictation service web-dictation backend for /transcribe.
// Per request: clear composer -> Start dictation -> play WAV into the PulseAudio virtual
// mic (real time) -> Submit dictation -> scrape #prompt-textarea -> clear. Never sends.
// Requests are serialized (one composer + one virtual mic).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { chromium } = require('~/takeout-browser/node_modules/playwright-core');

const CDP = process.env.DICTATE_CDP || 'http://127.0.0.1:9223';
const SINK = process.env.DICTATE_SINK || 'virtmic';
const XDG = process.env.XDG_RUNTIME_DIR || '/run/user/1000';
const sleep = ms => new Promise(r => setTimeout(r, ms));

let _browser = null, _page = null;
async function getPage() {
  if (_page && !_page.isClosed()) {
    try { await _page.evaluate(() => 1); return _page; } catch (_) { _page = null; }
  }
  if (_browser) { try { await _browser.close(); } catch (_) {} _browser = null; }
  _browser = await chromium.connectOverCDP(CDP, { timeout: 10000 });
  const ctx = _browser.contexts()[0];
  _page = ctx.pages().find(p => p.url().startsWith('DICTATION_SERVICE_URL/'));
  if (!_page) { _page = await ctx.newPage(); await _page.goto('DICTATION_SERVICE_URL/'); }
  return _page;
}

function playWav(file) {
  return new Promise((resolve, reject) => {
    const p = spawn('paplay', ['--device=' + SINK, file], { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });
    let err = '';
    p.stderr.on('data', d => (err += d));
    p.on('error', reject);
    p.on('close', code => (code === 0 ? resolve() : reject(new Error('paplay exit ' + code + ': ' + err.trim()))));
  });
}

const composerText = page => page.evaluate(() => {
  const c = document.querySelector('#prompt-textarea');
  return c ? (c.innerText || c.textContent || '').trim() : '';
});
async function clearComposer(page) {
  try {
    await page.click('#prompt-textarea', { timeout: 4000 });
    await page.keyboard.press('Control+A');
    await page.keyboard.press('Backspace');
  } catch (_) { /* composer may not be focusable yet; ignore */ }
}

async function _transcribe(audioBuffer) {
  const page = await getPage();
  const tmp = path.join(os.tmpdir(), `dictate-${Date.now()}-${Math.random().toString(36).slice(2)}.wav`);
  fs.writeFileSync(tmp, audioBuffer);
  try {
    await clearComposer(page);
    await page.click('[aria-label="Start dictation"]', { timeout: 8000 });
    await page.waitForSelector('[aria-label="Submit dictation"]', { timeout: 8000 });
    await playWav(tmp);            // real-time playback into the virtual mic
    await sleep(1200);             // let trailing words finish transcribing
    await page.click('[aria-label="Submit dictation"]', { timeout: 8000 });
    let text = '';
    for (let i = 0; i < 40; i++) { text = await composerText(page); if (text) break; await sleep(500); }
    await clearComposer(page);     // leave it clean; never send
    return text;
  } finally {
    fs.unlink(tmp, () => {});
  }
}

// serialize concurrent requests onto one composer/mic
let _chain = Promise.resolve();
function transcribe(audioBuffer) {
  const result = _chain.then(() => _transcribe(audioBuffer), () => _transcribe(audioBuffer));
  _chain = result.catch(() => {});
  return result;
}

module.exports = { transcribe };

if (require.main === module) {
  const wav = process.argv[2];
  if (!wav) { console.error('usage: node dictate.js <wav>'); process.exit(1); }
  const t0 = Date.now();
  transcribe(fs.readFileSync(wav))
    .then(t => { console.log(`(${Date.now() - t0}ms) TRANSCRIPT: ${JSON.stringify(t)}`); process.exit(0); })
    .catch(e => { console.error('ERR', e.stack || e.message); process.exit(1); });
}
