'use strict';
// wispr transcription service — implements contract/transcribe.md.
// Batch uploads are streamed to a private temp file, validated as bounded WAV,
// then serialized onto the single dictation service dictation backend.

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');
const Busboy = require('busboy');
const dictate = require('./dictate');
const { WebSocket, WebSocketServer } = require('ws');
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
const cfg = (name, fallback = '') => process.env[name] || env[name] || fallback;
const numCfg = (name, fallback) => {
  const n = Number(cfg(name, ''));
  return Number.isFinite(n) && n > 0 ? n : fallback;
};

const TOKEN = cfg('WISPR_BEARER_TOKEN');
const HTTP_PORT = numCfg('PORT', 8090);
const HTTP_HOST = cfg('HOST', '0.0.0.0'); // reached by VPS Caddy/WG and legacy LAN clients.
const HTTPS_PORT = numCfg('LAN_TLS_PORT', 8443);
const HTTPS_HOST = cfg('LAN_TLS_HOST', '0.0.0.0');
const LAN_TLS_KEY = cfg('LAN_TLS_KEY', '~/.wispr/mtls/rpc-server.key');
const LAN_TLS_CERT = cfg('LAN_TLS_CERT', '~/.wispr/mtls/rpc-server.crt');
const LAN_TLS_CA = cfg('LAN_TLS_CA', '~/.wispr/mtls/ca.crt');
const REQUIRE_LAN_MTLS = /^(1|true|yes)$/i.test(cfg('REQUIRE_LAN_MTLS', '0'));
const CLIENT_CERT_SHA256 = new Set(
  cfg('MTLS_CLIENT_CERT_SHA256', '')
    .split(',')
    .map(s => s.replace(/[^0-9a-f]/gi, '').toUpperCase())
    .filter(Boolean)
);

const ENGINE = 'dictation-service';
const DEVTOOLS = 'http://127.0.0.1:9223/json/version'; // the dedicated dictation service service browser

const MAX_AUDIO_SECONDS = numCfg('MAX_AUDIO_SECONDS', 600);
const BATCH_UPLOAD_MAX_BYTES = numCfg('BATCH_UPLOAD_MAX_BYTES', 64 * 1024 * 1024);
const INTERNET_PROBE_URLS = cfg('INTERNET_PROBE_URLS', 'https://www.google.com/generate_204,https://cloudflare.com/cdn-cgi/trace')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);
const INTERNET_PROBE_TIMEOUT_MS = numCfg('INTERNET_PROBE_TIMEOUT_MS', 2500);
const INTERNET_FAILURE_THRESHOLD = numCfg('INTERNET_FAILURE_THRESHOLD', 3);
const INTERNET_RECENT_OK_MS = numCfg('INTERNET_RECENT_OK_MS', 120000);

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

function makeHttpError(status, code, message) {
  const e = new Error(message);
  e.status = status;
  e.code = code;
  return e;
}

function statusForError(e) {
  if (e.status) return e.status;
  switch (e.code) {
    case 'busy':
    case 'overloaded':
      return 409;
    case 'bad_request':
    case 'invalid_audio':
      return 400;
    case 'audio_too_large':
      return 413;
    case 'transcription_timeout':
      return 504;
    case 'client_closed':
      return 499;
    case 'busy':
      return 409;
    default:
      return 503;
  }
}

function safeEqual(a, b) {
  const aa = Buffer.from(String(a || ''), 'utf8');
  const bb = Buffer.from(String(b || ''), 'utf8');
  if (aa.length !== bb.length) return false;
  return crypto.timingSafeEqual(aa, bb);
}

function bearerOk(req) {
  const m = /^Bearer\s+(.+)$/i.exec(req.headers['authorization'] || '');
  return !!m && safeEqual(m[1], TOKEN);
}

function tlsClientOk(req) {
  if (!req.socket.encrypted || CLIENT_CERT_SHA256.size === 0) return true;
  const cert = req.socket.getPeerCertificate();
  const fp = String(cert && cert.fingerprint256 || '').replace(/[^0-9a-f]/gi, '').toUpperCase();
  return !!fp && CLIENT_CERT_SHA256.has(fp);
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
  const probe = async (url) => {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), INTERNET_PROBE_TIMEOUT_MS);
    try {
      const r = await fetch(url, { signal: ac.signal });
      return r.status < 400;
    } catch (_) {
      return false;
    } finally {
      clearTimeout(t);
    }
  };
  const ok = (await Promise.all(INTERNET_PROBE_URLS.map(probe))).some(Boolean);
  if (ok) {
    internetOk.failures = 0;
    internetOk.lastOk = Date.now();
    return true;
  }
  internetOk.failures = (internetOk.failures || 0) + 1;
  const recentSuccess = internetOk.lastOk && Date.now() - internetOk.lastOk < INTERNET_RECENT_OK_MS;
  return internetOk.failures < INTERNET_FAILURE_THRESHOLD || recentSuccess;
}
internetOk.failures = 0;
internetOk.lastOk = 0;
// browser/dictationService come from a read-only probe; skipped while a transcription is in flight (don't disturb it).
async function refreshHealth() {
  const busy = dictate.isBusy();
  let browser = 'up', dictationService = 'ready', dictationServiceBlocker = null;
  if (!busy) {
    const p = await dictate.probe();
    browser = p.browser;
    dictationService = p.dictationService;
    dictationServiceBlocker = p.blocker || null;
  }
  const [mic, net] = await Promise.all([micOk(), internetOk()]);
  _health = { ok: true, engine: ENGINE, browser, dictationService, ...(dictationServiceBlocker ? { dictationServiceBlocker } : {}), mic: mic ? 'ok' : 'missing', internet: net ? 'ok' : 'down', busy, lastDictation: dictate.lastResult(), checkedAt: new Date().toISOString() };
}
setInterval(() => refreshHealth().catch(() => {}), 20000);
refreshHealth().catch(() => {});

function rmrf(p) {
  try { fs.rmSync(p, { recursive: true, force: true }); } catch (_) {}
}

function receiveAudioFile(req) {
  return new Promise((resolve, reject) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wispr-upload-'));
    fs.chmodSync(tmpDir, 0o700);
    const filePath = path.join(tmpDir, 'audio.wav');
    let audioSeen = false;
    let bytes = 0;
    let writeDone = Promise.resolve();
    let settled = false;

    const fail = (err) => {
      if (settled) return;
      settled = true;
      req.unpipe();
      req.resume();
      rmrf(tmpDir);
      reject(err);
    };

    let bb;
    try {
      bb = Busboy({
        headers: req.headers,
        limits: { files: 1, fields: 0, parts: 2, fileSize: BATCH_UPLOAD_MAX_BYTES }
      });
    } catch (e) {
      rmrf(tmpDir);
      reject(makeHttpError(400, 'bad_request', 'invalid multipart/form-data'));
      return;
    }

    bb.on('file', (name, stream) => {
      if (name !== 'audio' || audioSeen) {
        stream.resume();
        fail(makeHttpError(400, 'bad_request', 'expected exactly one audio file part'));
        return;
      }
      audioSeen = true;
      const out = fs.createWriteStream(filePath, { flags: 'wx', mode: 0o600 });
      writeDone = new Promise((res, rej) => {
        out.on('finish', res);
        out.on('error', rej);
      });
      stream.on('data', chunk => { bytes += chunk.length; });
      stream.on('limit', () => fail(makeHttpError(413, 'audio_too_large', 'audio upload exceeds 10-minute batch limit')));
      stream.on('error', fail);
      stream.pipe(out);
    });

    bb.on('field', () => fail(makeHttpError(400, 'bad_request', 'unexpected form field')));
    bb.on('filesLimit', () => fail(makeHttpError(400, 'bad_request', 'too many file parts')));
    bb.on('fieldsLimit', () => fail(makeHttpError(400, 'bad_request', 'unexpected form field')));
    bb.on('partsLimit', () => fail(makeHttpError(400, 'bad_request', 'too many multipart parts')));
    bb.on('error', fail);
    bb.on('close', async () => {
      if (settled) return;
      try {
        await writeDone;
        if (!audioSeen || bytes === 0) throw makeHttpError(400, 'bad_request', 'missing or empty audio part');
        settled = true;
        resolve({ tmpDir, filePath, bytes });
      } catch (e) {
        rmrf(tmpDir);
        reject(e);
      }
    });
    req.pipe(bb);
  });
}

const riff = b => b.toString('ascii');
const u16 = (b, o) => b.readUInt16LE(o);
const u32 = (b, o) => b.readUInt32LE(o);

function validateWavFile(filePath) {
  const st = fs.statSync(filePath);
  if (st.size > BATCH_UPLOAD_MAX_BYTES) throw makeHttpError(413, 'audio_too_large', 'audio upload exceeds 10-minute batch limit');
  if (st.size < 44) throw makeHttpError(400, 'invalid_audio', 'WAV is too small');
  const b = fs.readFileSync(filePath);
  if (riff(b.subarray(0, 4)) !== 'RIFF' || riff(b.subarray(8, 12)) !== 'WAVE') {
    throw makeHttpError(400, 'invalid_audio', 'expected RIFF/WAVE audio');
  }

  let fmt = null;
  let dataBytes = 0;
  let off = 12;
  while (off + 8 <= b.length) {
    const id = riff(b.subarray(off, off + 4));
    const size = u32(b, off + 4);
    const body = off + 8;
    const next = body + size + (size % 2);
    if (body + size > b.length) throw makeHttpError(400, 'invalid_audio', 'truncated WAV chunk');
    if (id === 'fmt ') {
      if (size < 16) throw makeHttpError(400, 'invalid_audio', 'invalid WAV fmt chunk');
      fmt = {
        audioFormat: u16(b, body),
        channels: u16(b, body + 2),
        sampleRate: u32(b, body + 4),
        byteRate: u32(b, body + 8),
        blockAlign: u16(b, body + 12),
        bitsPerSample: u16(b, body + 14)
      };
    } else if (id === 'data') {
      dataBytes = size;
      break;
    }
    off = next;
  }

  if (!fmt || !dataBytes) throw makeHttpError(400, 'invalid_audio', 'WAV missing fmt or data chunk');
  if (fmt.audioFormat !== 1) throw makeHttpError(400, 'invalid_audio', 'WAV must be PCM');
  if (fmt.channels !== 1) throw makeHttpError(400, 'invalid_audio', 'WAV must be mono');
  if (fmt.bitsPerSample !== 16) throw makeHttpError(400, 'invalid_audio', 'WAV must be 16-bit PCM');
  if (fmt.sampleRate !== 48000) throw makeHttpError(400, 'invalid_audio', 'WAV must be 48 kHz');
  if (fmt.blockAlign !== 2 || fmt.byteRate !== 96000) throw makeHttpError(400, 'invalid_audio', 'WAV byte rate/block alignment mismatch');

  const durationMs = Math.round((dataBytes / fmt.byteRate) * 1000);
  if (!Number.isFinite(durationMs) || durationMs <= 0) throw makeHttpError(400, 'invalid_audio', 'WAV contains no audio');
  if (durationMs > MAX_AUDIO_SECONDS * 1000) throw makeHttpError(413, 'audio_too_large', `audio exceeds ${MAX_AUDIO_SECONDS}s max duration`);
  return { durationMs, dataBytes, sampleRate: fmt.sampleRate };
}

// Transcode anything ffmpeg can decode (mp3/m4a/opus/flac/16k WAV/…) into the canonical playback
// format (48 kHz / mono / s16le WAV) so internal callers aren't constrained to the mac client's format.
function transcodeToCanonicalWav(src, dst) {
  return new Promise((resolve, reject) => {
    const ff = spawn('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error',
      '-i', src, '-ar', '48000', '-ac', '1', '-c:a', 'pcm_s16le', '-f', 'wav', dst],
      { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = ''; ff.stderr.on('data', d => (err += d));
    const timer = setTimeout(() => { try { ff.kill('SIGKILL'); } catch (_) {} }, 120000);
    ff.on('error', e => { clearTimeout(timer); reject(makeHttpError(400, 'invalid_audio', 'ffmpeg unavailable: ' + e.message)); });
    ff.on('close', c => {
      clearTimeout(timer);
      if (c === 0) resolve();
      else reject(makeHttpError(400, 'invalid_audio', 'could not decode audio: ' + err.trim().slice(0, 200)));
    });
  });
}

// Fast-path already-canonical WAV (the mac client); otherwise transcode + validate. → { path, audio }.
async function normalizeAudioUpload(uploaded) {
  try {
    return { path: uploaded.filePath, audio: validateWavFile(uploaded.filePath) };
  } catch (e) {
    if (e.status === 413) throw e; // too large/long — don't bother transcoding
    const dst = uploaded.filePath + '.48k.wav';
    await transcodeToCanonicalWav(uploaded.filePath, dst);
    return { path: dst, audio: validateWavFile(dst) };
  }
}

// --- routing ----------------------------------------------------------------
async function handleRequest(req, res) {
  let uploaded = null;
  try {
    const url = req.url.split('?')[0];

    if (!tlsClientOk(req)) return sendErr(res, 401, 'unauthorized', 'untrusted client certificate');

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
      if (dictate.batchBusy()) return sendErr(res, 409, 'busy', 'all transcription lanes are busy; retry shortly');
      const ct = req.headers['content-type'] || '';
      if (!/^multipart\/form-data/i.test(ct)) return sendErr(res, 415, 'unsupported_media_type', 'expected multipart/form-data');

      uploaded = await receiveAudioFile(req);
      const { path: audioPath, audio } = await normalizeAudioUpload(uploaded);
      const t0 = Date.now();
      const ac = new AbortController();
      const abortTranscription = () => {
        if (!res.writableEnded) ac.abort();
      };
      req.on('aborted', abortTranscription);
      res.on('close', abortTranscription);
      let text;
      try {
        text = await dictate.transcribeFile(audioPath, audio, { signal: ac.signal });
      } catch (e) {
        if (ac.signal.aborted || res.destroyed || res.writableEnded) return;
        return sendErr(res, statusForError(e), e.code || 'backend_unavailable', String(e.message || e));
      } finally {
        req.off('aborted', abortTranscription);
        res.off('close', abortTranscription);
      }
      if (!text) return sendErr(res, 504, 'transcription_timeout', 'dictation produced no text');
      return sendJson(res, 200, { text, engine: ENGINE, duration_ms: Date.now() - t0, audio_duration_ms: audio.durationMs });
    }

    return sendErr(res, 404, 'not_found', `no route for ${req.method} ${url}`);
  } catch (e) {
    if (!res.destroyed && !res.writableEnded) sendErr(res, statusForError(e), e.code || 'internal', e.message || 'error');
  } finally {
    if (uploaded) rmrf(uploaded.tmpDir);
  }
}

// --- WebSocket /v1/stream: live PCM dictation (start -> binary PCM -> stop -> final) ---------
const HEARTBEAT_MS = 10000;   // ws ping cadence; a missed pong terminates the socket
const STREAM_IDLE_MS = 25000; // a started stream with no audio this long -> free the mic
const STREAM_STOP_GRACE_MS = numCfg('STREAM_STOP_GRACE_MS', 30000);
const STREAM_MAX_MS = MAX_AUDIO_SECONDS * 1000 + STREAM_STOP_GRACE_MS; // client stops at MAX_AUDIO_SECONDS; grace avoids cap races
const STREAM_START_MS = 10000; // socket opened but no start -> close it
const STREAM_MAX_FRAME_BYTES = 256 * 1024;
const STREAM_MAX_PRE_READY_BYTES = 2 * 1024 * 1024;
const STREAM_MAX_BYTES = 48000 * 2 * MAX_AUDIO_SECONDS; // s16le/48k/mono
const wss = new WebSocketServer({ noServer: true, maxPayload: STREAM_MAX_FRAME_BYTES });

function attachUpgrade(srv) {
  srv.on('upgrade', (req, socket, head) => {
    if (req.url.split('?')[0] !== '/v1/stream') { socket.destroy(); return; }
    if (!tlsClientOk(req)) { socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n'); socket.destroy(); return; }
    if (!bearerOk(req)) { socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n'); socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, ws => handleStream(ws, req));
  });
}

function handleStream(ws, req) {
  const streamId = crypto.randomBytes(4).toString('hex');
  let startP = null, session = null, stopped = false, lastActivity = Date.now(), openedAt = Date.now(), startedAt = 0, alive = true;
  const pre = []; // binary frames that arrive before the session is ready -> flushed on ready
  let preBytes = 0, streamBytes = 0, closing = false;
  console.log(`[wispr-stream ${streamId}] open remote=${req.socket.remoteAddress || '?'} tls=${!!req.socket.encrypted}`);
  const send = obj => { try { ws.send(JSON.stringify(obj)); } catch (_) {} };
  const abort = async (code, message) => {
    if (closing) return;
    closing = true;
    console.warn(`[wispr-stream ${streamId}] abort code=${code || 'close'} message=${message || ''} started=${!!startP} ready=${!!session} stopped=${stopped} bytes=${streamBytes} preBytes=${preBytes} age=${Date.now() - openedAt}ms`);
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
      console.log(`[wispr-stream ${streamId}] start`);
      startP = dictate.startStream();
      try {
        const s = await startP;
        if (closing || ws.readyState !== WebSocket.OPEN) {
          await dictate.abortStream(s).catch(() => {});
          return;
        }
        session = s;
        const flushedBytes = preBytes;
        const flushedFrames = pre.length;
        for (const b of pre.splice(0)) dictate.pushAudio(session, b);
        preBytes = 0;
        send({ type: 'ready' });
        console.log(`[wispr-stream ${streamId}] ready in ${Date.now() - startedAt}ms flushedFrames=${flushedFrames} flushedBytes=${flushedBytes}`);
      }
      catch (e) {
        if (!closing) {
          console.warn(`[wispr-stream ${streamId}] start failed in ${Date.now() - startedAt}ms code=${e.code || 'backend_unavailable'} message=${String(e.message || e)}`);
          send({ type: 'error', code: e.code || 'backend_unavailable', message: String(e.message || e) });
          try { ws.close(); } catch (_) {}
        }
      }
    } else if (msg.type === 'stop') {
      if (stopped) return; stopped = true;
      console.log(`[wispr-stream ${streamId}] stop bytes=${streamBytes} age=${Date.now() - openedAt}ms`);
      try { if (startP) await startP; } catch (_) {}
      if (!session) { send({ type: 'error', code: 'bad_request', message: 'no active stream' }); try { ws.close(); } catch (_) {} return; }
      const s = session; session = null;
      try {
        const r = await dictate.stopStream(s);
        send({ type: 'final', text: r.text, duration_ms: r.duration_ms });
        console.log(`[wispr-stream ${streamId}] final text=${r.text ? r.text.length : 0} duration=${r.duration_ms}ms`);
      }
      catch (e) {
        console.warn(`[wispr-stream ${streamId}] stop failed code=${e.code || 'transcription_error'} message=${String(e.message || e)}`);
        send({ type: 'error', code: 'transcription_error', message: String(e.message || e) });
      }
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
  ws.on('close', () => {
    closing = true;
    clearInterval(wd);
    if (session) {
      const s = session;
      session = null;
      dictate.abortStream(s).catch(() => {});
    }
    console.log(`[wispr-stream ${streamId}] close stopped=${stopped} bytes=${streamBytes} age=${Date.now() - openedAt}ms`);
  });
  ws.on('error', e => { console.warn(`[wispr-stream ${streamId}] socket error ${e.message || e}`); });
}

function loadLanTlsOptions() {
  const files = [LAN_TLS_KEY, LAN_TLS_CERT, LAN_TLS_CA];
  if (!files.every(p => p && fs.existsSync(p))) {
    if (REQUIRE_LAN_MTLS) {
      console.error(`[wispr-server] refusing to start: LAN mTLS files missing (${files.join(', ')})`);
      process.exit(1);
    }
    console.warn('[wispr-server] LAN mTLS disabled: key/cert/CA files not found');
    return null;
  }
  return {
    key: fs.readFileSync(LAN_TLS_KEY),
    cert: fs.readFileSync(LAN_TLS_CERT),
    ca: fs.readFileSync(LAN_TLS_CA),
    requestCert: true,
    rejectUnauthorized: true,
    minVersion: 'TLSv1.2'
  };
}

const httpServer = http.createServer(handleRequest);
attachUpgrade(httpServer);
httpServer.listen(HTTP_PORT, HTTP_HOST, () => {
  console.log(`[wispr-server] engine=${ENGINE} HTTP listening on ${HTTP_HOST}:${HTTP_PORT}`);
});

const lanTlsOptions = loadLanTlsOptions();
if (lanTlsOptions) {
  const httpsServer = https.createServer(lanTlsOptions, handleRequest);
  attachUpgrade(httpsServer);
  httpsServer.listen(HTTPS_PORT, HTTPS_HOST, () => {
    console.log(`[wispr-server] engine=${ENGINE} LAN mTLS listening on ${HTTPS_HOST}:${HTTPS_PORT}`);
  });
}
