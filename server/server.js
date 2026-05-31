'use strict';
// wispr transcription service — implements contract/transcribe.md.
// Backend is pluggable: transcribe() returns stub text now; swap it for the
// dictation service web-dictation driver later without touching routing/auth. Zero deps.

const http = require('http');
const fs = require('fs');
const path = require('path');
const dictate = require('./dictate');
const { WebSocketServer } = require('ws');
const { spawn } = require('child_process');

// --- config (server/.env, gitignored) -------------------------------------
function loadEnv(p) {
  const out = {};
  try {
    for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/i);
      if (m) out[m[1]] = m[2];
    }
  } catch (_) { /* no .env -> rely on process.env */ }
  return out;
}
const env = loadEnv(path.join(__dirname, '.env'));
const TOKEN = process.env.WISPR_BEARER_TOKEN || env.WISPR_BEARER_TOKEN || '';
const PORT = Number(process.env.PORT || env.PORT || 8080);
const HOST = '0.0.0.0'; // both LAN subnets (wispr.local and wispr.local)
const ENGINE = 'dictation-service';
const DEVTOOLS = 'http://127.0.0.1:9223/json/version'; // the dedicated dictation service service browser

if (!TOKEN) {
  console.error('[wispr-server] refusing to start: no WISPR_BEARER_TOKEN (server/.env)');
  process.exit(1);
}

// --- helpers ----------------------------------------------------------------
function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}
const sendErr = (res, status, code, message) => sendJson(res, status, { error: { code, message } });

function bearerOk(req) {
  const m = /^Bearer\s+(.+)$/i.exec(req.headers['authorization'] || '');
  return !!m && m[1] === TOKEN;
}

// --- health monitor: a cached snapshot so /healthz is instant and never disturbs dictation ---
let _health = { ok: true, engine: ENGINE, browser: 'unknown', dictationService: 'unknown', mic: 'unknown', internet: 'unknown', busy: false, lastDictation: null, checkedAt: null };

function micOk() {
  return new Promise(resolve => {
    const p = spawn('pactl', ['list', 'short', 'sources'], { env: { ...process.env, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR || '/run/user/1000' } });
    let out = ''; p.stdout.on('data', d => (out += d));
    p.on('error', () => resolve(false));
    p.on('close', () => resolve(/virtmic_in/.test(out)));
  });
}
async function internetOk() {
  try {
    const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 3000);
    const r = await fetch('https://www.google.com/generate_204', { signal: ac.signal });
    clearTimeout(t); return r.status < 400;
  } catch (_) { return false; }
}
// browser/dictationService come from a read-only probe; skipped while a transcription is in flight (don't disturb it).
async function refreshHealth() {
  const busy = dictate.isBusy();
  let browser = 'up', dictationService = 'ready';
  if (!busy) { const p = await dictate.probe(); browser = p.browser; dictationService = p.dictationService; }
  const [mic, net] = await Promise.all([micOk(), internetOk()]);
  _health = { ok: true, engine: ENGINE, browser, dictationService, mic: mic ? 'ok' : 'missing', internet: net ? 'ok' : 'down', busy, lastDictation: dictate.lastResult(), checkedAt: new Date().toISOString() };
}
setInterval(() => refreshHealth().catch(() => {}), 20000);
refreshHealth().catch(() => {});

function readBody(req, maxBytes = 25 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) { req.destroy(); reject(Object.assign(new Error('too large'), { tooLarge: true })); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// Minimal multipart/form-data extraction of the first part's bytes (the "audio"
// field). Both the macOS client and contract-test.sh send exactly one part.
function extractAudio(buf, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  if (!m) return null;
  const bb = Buffer.from('--' + (m[1] || m[2]).trim());
  const start = buf.indexOf(bb);
  if (start < 0) return null;
  const headerEnd = buf.indexOf('\r\n\r\n', start);
  if (headerEnd < 0) return null;
  const bodyStart = headerEnd + 4;
  const next = buf.indexOf(bb, bodyStart);
  if (next < 0) return null;
  return buf.slice(bodyStart, next - 2); // drop the trailing CRLF before the boundary
}

// --- transcription backend: dictation service web dictation (see dictate.js) ----------
async function transcribe(audioBuf) {
  return dictate.transcribe(audioBuf);
}

// --- routing ----------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  try {
    const url = req.url.split('?')[0];

    if (req.method === 'GET' && url === '/healthz') {
      if (!bearerOk(req)) return sendErr(res, 401, 'unauthorized', 'missing or invalid bearer token');
      return sendJson(res, 200, { ..._health, busy: dictate.isBusy() }); // busy live; rest cached
    }
    if (req.method === 'GET' && url === '/readyz') {
      if (!bearerOk(req)) return sendErr(res, 401, 'unauthorized', 'missing or invalid bearer token');
      const ready = _health.browser === 'up' && _health.dictationService === 'ready' && _health.mic === 'ok' && _health.internet === 'ok';
      return sendJson(res, ready ? 200 : 503, _health);
    }

    if (req.method === 'POST' && url === '/transcribe') {
      if (!bearerOk(req)) return sendErr(res, 401, 'unauthorized', 'missing or invalid bearer token');
      const ct = req.headers['content-type'] || '';
      if (!/^multipart\/form-data/i.test(ct)) return sendErr(res, 415, 'unsupported_media_type', 'expected multipart/form-data');
      let body;
      try { body = await readBody(req); }
      catch (e) { if (e.tooLarge) return sendErr(res, 400, 'bad_request', 'audio too large'); throw e; }
      const audio = extractAudio(body, ct);
      if (!audio || audio.length === 0) return sendErr(res, 400, 'bad_request', 'missing or empty audio part');
      const t0 = Date.now();
      let text;
      try { text = await transcribe(audio); }
      catch (e) { return sendErr(res, 503, e.code || 'backend_unavailable', String(e.message || e)); }
      if (!text) return sendErr(res, 504, 'transcription_timeout', 'dictation produced no text');
      return sendJson(res, 200, { text, engine: ENGINE, duration_ms: Date.now() - t0 });
    }

    return sendErr(res, 404, 'not_found', `no route for ${req.method} ${url}`);
  } catch (e) {
    sendErr(res, 500, 'internal', e.message || 'error');
  }
});

// --- WebSocket /v1/stream: live PCM dictation (start -> binary PCM -> stop -> final) ---------
const HEARTBEAT_MS = 10000;   // ws ping cadence; a missed pong terminates the socket
const STREAM_IDLE_MS = 25000; // a started stream with no audio this long -> free the mic
const STREAM_MAX_MS = 600000; // hard cap on one stream (10 min) -> free the mic
const STREAM_START_MS = 10000; // socket opened but no start -> close it
const STREAM_MAX_FRAME_BYTES = 256 * 1024;
const STREAM_MAX_PRE_READY_BYTES = 2 * 1024 * 1024;
const STREAM_MAX_BYTES = 48000 * 2 * 600; // 10 minutes of s16le/48k/mono
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  if (req.url.split('?')[0] !== '/v1/stream') { socket.destroy(); return; }
  if (!bearerOk(req)) { socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n'); socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, ws => handleStream(ws));
});

function handleStream(ws) {
  let startP = null, session = null, stopped = false, lastActivity = Date.now(), openedAt = Date.now(), startedAt = 0, alive = true;
  const pre = []; // binary frames that arrive before the session is ready -> flushed on ready
  let preBytes = 0, streamBytes = 0, closing = false;
  const send = obj => { try { ws.send(JSON.stringify(obj)); } catch (_) {} };
  const abort = async (code, message) => {
    if (closing) return;
    closing = true;
    if (session) { const s = session; session = null; await dictate.abortStream(s).catch(() => {}); }
    if (code) send({ type: 'error', code, message });
    try { ws.close(); } catch (_) {}
  };
  ws.on('pong', () => { alive = true; });
  ws.on('message', async (data, isBinary) => {
    lastActivity = Date.now();
    if (isBinary) {
      const n = Buffer.byteLength(data);
      if (n > STREAM_MAX_FRAME_BYTES) { abort('frame_too_large', 'audio frame too large'); return; }
      streamBytes += n;
      if (streamBytes > STREAM_MAX_BYTES) { abort('max_duration', 'stream exceeded max audio bytes'); return; }
      if (session) {
        dictate.pushAudio(session, data);
      } else {
        preBytes += n;
        if (preBytes > STREAM_MAX_PRE_READY_BYTES) { abort('pre_ready_overflow', 'audio sent before ready exceeded buffer limit'); return; }
        pre.push(data);
      }
      return;
    }
    let msg; try { msg = JSON.parse(data.toString()); } catch (_) { return; }
    if (msg.type === 'start') {
      if (startP) return;                          // extra start fields (format/lang) are ignored
      startedAt = Date.now();
      startP = dictate.startStream();
      try { session = await startP; for (const b of pre.splice(0)) dictate.pushAudio(session, b); preBytes = 0; send({ type: 'ready' }); }
      catch (e) { send({ type: 'error', code: e.code || 'backend_unavailable', message: String(e.message || e) }); try { ws.close(); } catch (_) {} }
    } else if (msg.type === 'stop') {
      if (stopped) return; stopped = true;
      try { if (startP) await startP; } catch (_) {}
      if (!session) { send({ type: 'error', code: 'bad_request', message: 'no active stream' }); try { ws.close(); } catch (_) {} return; }
      const s = session; session = null;
      try { const r = await dictate.stopStream(s); send({ type: 'final', text: r.text, duration_ms: r.duration_ms }); }
      catch (e) { send({ type: 'error', code: 'transcription_error', message: String(e.message || e) }); }
      try { ws.close(); } catch (_) {}
    }
  });
  // watchdog: dead-TCP detection (ping/pong) + free the mic if a started stream goes silent or runs away
  const wd = setInterval(() => {
    if (!alive) { try { ws.terminate(); } catch (_) {} return; }   // -> 'close' -> abortStream frees the mic
    alive = false; try { ws.ping(); } catch (_) {}
    if (!startP && Date.now() - openedAt > STREAM_START_MS) abort('start_timeout', 'stream did not start');
    if (session && !stopped) {
      if (Date.now() - lastActivity > STREAM_IDLE_MS) abort('idle_timeout', 'no audio received; freeing the mic');
      else if (startedAt && Date.now() - startedAt > STREAM_MAX_MS) abort('max_duration', 'stream exceeded max duration');
    }
  }, HEARTBEAT_MS);
  ws.on('close', () => { clearInterval(wd); if (session) { const s = session; session = null; dictate.abortStream(s).catch(() => {}); } });
  ws.on('error', () => {});
}

server.listen(PORT, HOST, () => {
  console.log(`[wispr-server] engine=${ENGINE} listening on ${HOST}:${PORT} (POST /transcribe + WS /v1/stream)`);
});
