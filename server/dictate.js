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
  const candidates = [];
  if (process.env.WISPR_PLAYWRIGHT_CORE_PATH) {
    candidates.push({ mod: process.env.WISPR_PLAYWRIGHT_CORE_PATH, source: 'WISPR_PLAYWRIGHT_CORE_PATH' });
  }
  if (process.env.WISPR_PLAYWRIGHT_PACKAGE) {
    candidates.push({ mod: process.env.WISPR_PLAYWRIGHT_PACKAGE, source: 'WISPR_PLAYWRIGHT_PACKAGE' });
  }
  candidates.push({ mod: 'rebrowser-playwright-core', source: 'default' });
  candidates.push({ mod: 'playwright-core', source: 'fallback' });

  const errors = [];
  for (const candidate of candidates) {
    try {
      return require(candidate.mod);
    } catch (e) {
      errors.push(`${candidate.source}=${candidate.mod}: ${e.message}`);
    }
  }

  throw new Error(`failed to load Rebrowser/Playwright CDP driver (${errors.join('; ')})`);
}
const { chromium } = loadPlaywrightCore();

const CDP = process.env.DICTATE_CDP || 'http://127.0.0.1:9223';
const SINK = process.env.DICTATE_SINK || 'virtmic';
const SOURCE = process.env.DICTATE_SOURCE || `${SINK}_in`;
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
  _lanes.push({
    id: k,
    cdp: `http://127.0.0.1:${BASE_CDP_PORT + k}`,
    sink: `virtmic${k}`,
    browser: null,
    page: null,
    busy: false,
    unhealthyUntil: 0,
    consecutiveFailures: 0
  });
}
function hasHealthyFreeLane() {
  const now = Date.now();
  return _lanes.some(l => !l.busy && (l.unhealthyUntil || 0) <= now);
}

function acquireLane() {
  const now = Date.now();
  const lane = _lanes.find(x => !x.busy && (x.unhealthyUntil || 0) <= now);
  if (lane) { lane.busy = true; }
  return lane || null;
}
function internalPoolFull() { return !hasHealthyFreeLane(); }
// Whether a *batch* (/transcribe) request would be rejected right now: all internal lanes busy/quarantined, or —
// with no lanes provisioned — the single lane-0 backend is busy. Streaming uses isBusy() (lane 0).
function batchBusy() { return INTERNAL_LANES > 0 ? !hasHealthyFreeLane() : _busy; }
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
//   - STREAM_END_SILENCE_MS   : real silence played into the mic before drain/Submit. Short live
//     utterances can otherwise enter the service's transcribing state and complete with empty text.
const STREAM_DRAIN_MODE = (process.env.STREAM_DRAIN_MODE || 'drain').toLowerCase();
const STREAM_DRAIN_MAX_MS = Number(process.env.STREAM_DRAIN_MAX_MS || 15000);
const STREAM_SUBMIT_SETTLE_MS = Number(process.env.STREAM_SUBMIT_SETTLE_MS || 250);
const STREAM_TAIL_MARGIN_MS = Number(process.env.STREAM_TAIL_MARGIN_MS || 200);
const STREAM_END_SILENCE_MS = Number(process.env.STREAM_END_SILENCE_MS || 1000);
const STREAM_SOURCE_WARMUP = !/^(0|false|no)$/i.test(process.env.STREAM_SOURCE_WARMUP || '1');
const EMPTY_TRANSCRIPT_SETTLE_MS = Number(process.env.EMPTY_TRANSCRIPT_SETTLE_MS || 1200);
const BYTES_PER_MS = 48000 * 2 / 1000; // 96 — s16le, mono, 48 kHz
const STREAM_END_SILENCE_CHUNK = Buffer.alloc(Math.round(BYTES_PER_MS * 20));
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
const MAIN_PAGE_OWNER = Symbol('main dictation request');
function ownsDictationPage(owner) {
  return owner === MAIN_PAGE_OWNER ? _busy : _lanes.includes(owner) && owner.busy;
}

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
const isDictationServicePage = page => {
  if (!page || page.isClosed()) return false;
  try {
    const target = new URL(DICTATION_SERVICE_URL), current = new URL(page.url());
    return current.origin === target.origin && (target.pathname === '/' || current.pathname === target.pathname.replace(/\/$/, '') || current.pathname.startsWith(target.pathname));
  } catch (_) { return false; }
};
const isBlankPage = page => {
  if (!page || page.isClosed()) return false;
  const url = page.url();
  return url === 'about:blank' || url === 'chrome://new-tab-page/' || url === 'chrome://newtab/';
};

async function inspectPagePreservation(page) {
  try {
    const state = await dictationUIState(page);
    return { state, protected: Boolean(state.text || state.active || state.submitted || state.retry || state.providerStopped || state.viewRecording || state.recordingMedia || state.settingsView || state.recordingView || providerChallengeBlocked(page, state)), unknown: false };
  } catch (_) { return { state: null, protected: true, unknown: true }; }
}

function attachProviderGuards(page) {
  if (page._wisprProviderGuardsAttached) return;
  page._wisprProviderGuardsAttached = true;
  page.on('response', async response => {
    try {
      const target = new URL(response.url());
      if (target.origin !== new URL(DICTATION_SERVICE_URL).origin) return;
      const status = response.status();
      const isMainNavigation = typeof response.request === 'function' && response.request().isNavigationRequest() &&
                               typeof response.frame === 'function' && typeof page.mainFrame === 'function' && response.frame() === page.mainFrame();
      const isCriticalApi = target.pathname === '/backend-api/transcribe';
      if (status === 403 && (isMainNavigation || isCriticalApi)) {
        const mitigation = await response.headerValue('cf-mitigated');
        const contentType = await response.headerValue('content-type');
        if (mitigation === 'challenge' || /text\/html/i.test(contentType || '')) {
          page._wisprChallengeBlocked = true;
          page._wisprResolvedHomeDocument = false;
        }
      } else if (status >= 200 && status < 300 && target.pathname === '/backend-api/transcribe') {
        page._wisprChallengeBlocked = false;
        page._wisprResolvedHomeDocument = false;
      } else if (page._wisprChallengeBlocked && status >= 200 && status < 300 && target.pathname === new URL(DICTATION_SERVICE_URL).pathname && isMainNavigation) {
        const contentType = await response.headerValue('content-type');
        if (/text\/html/i.test(contentType || '')) page._wisprResolvedHomeDocument = true;
      }
    } catch (_) {}
  });
}

// A human-resolved home document must be observed after the challenge, then confirmed ready.
// If the page is already idle and ready with composer and start dictation controls, it cannot be challenge-blocked.
function providerChallengeBlocked(page, state) {
  if (state && state.composer && state.start && !state.challenge) {
    page._wisprChallengeBlocked = false;
    page._wisprResolvedHomeDocument = false;
    return false;
  }
  if (page._wisprChallengeBlocked && page._wisprResolvedHomeDocument && !state.challenge && !state.loggedOut && state.composer && state.start) {
    page._wisprChallengeBlocked = false;
    page._wisprResolvedHomeDocument = false;
  }
  return Boolean(state.challenge || page._wisprChallengeBlocked);
}

function watchOwnedServiceTabs(ctx) {
  if (ctx._wisprTabPolicyInstalled) return;
  ctx._wisprTabPolicyInstalled = true;
  let closed = false;
  const timers = new Map(), handlers = new Map();
  const cancelTimer = page => {
    if (timers.has(page)) clearTimeout(timers.get(page));
    timers.delete(page);
  };
  const closeExtra = (page, allowBlank = false) => {
    if (closed || page.isClosed() || page === ctx._wisprSelectedServicePage) { cancelTimer(page); return; }
    if (isDictationServicePage(page)) { page._wisprWasServiceTab = true; cancelTimer(page); return; }
    // A prior service page can contain a draft/recording or be in a same-tab login redirect.
    if (page._wisprWasServiceTab || /^(?:blob:|data:(?:audio|video)\/)/i.test(page.url())) { cancelTimer(page); return; }
    if (isBlankPage(page) && !allowBlank) {
      if (!timers.has(page)) timers.set(page, setTimeout(() => {
        timers.delete(page);
        if (!ctx._wisprCreatingSelectedPage) closeExtra(page, true);
      }, 750));
      return;
    }
    cancelTimer(page);
    page.close().catch(() => {});
  };
  const observe = page => {
    if (closed || handlers.has(page)) return;
    const navigated = frame => { if (frame === page.mainFrame()) closeExtra(page); };
    const pageClosed = () => {
      cancelTimer(page);
      page.off('framenavigated', navigated);
      page.off('close', pageClosed);
      handlers.delete(page);
    };
    handlers.set(page, { navigated, pageClosed });
    page.on('framenavigated', navigated);
    page.on('close', pageClosed);
    closeExtra(page);
  };
  ctx.on('page', observe);
  ctx.on('close', () => {
    closed = true;
    ctx.off('page', observe);
    for (const [page, handler] of handlers) {
      cancelTimer(page);
      page.off('framenavigated', handler.navigated);
      page.off('close', handler.pageClosed);
    }
    handlers.clear();
  });
  for (const page of ctx.pages()) observe(page);
}

// These contexts belong only to the dedicated Wispr service profiles.
async function normalizeServicePages(ctx, preferred = null) {
  let pages = ctx.pages().filter(p => !p.isClosed());
  const previousSelection = ctx._wisprSelectedServicePage;
  if (previousSelection && !previousSelection.isClosed() && previousSelection._wisprWasServiceTab && !isDictationServicePage(previousSelection)) {
    throw makeBackendUnavailable('Selected service tab changed origin; preserving its login or recording view');
  }
  let servicePages = pages.filter(isDictationServicePage);
  const inspected = await Promise.all(servicePages.map(async candidate => ({ candidate, ...await inspectPagePreservation(candidate) })));
  const protectedPages = inspected.filter(entry => entry.protected);
  if (protectedPages.length > 1 || (servicePages.length > 1 && inspected.some(entry => entry.unknown))) {
    throw makeBackendUnavailable('Multiple or uninspectable service tabs may contain recordings or drafts; preserving every tab');
  }
  let page = protectedPages[0]?.candidate || (servicePages.includes(preferred) ? preferred : null) || inspected.find(entry => entry.state?.composer && entry.state?.start)?.candidate || servicePages[0];
  const needsNavigation = !page;
  if (!page) {
    page = pages.find(isBlankPage);
    if (!page) {
      ctx._wisprCreatingSelectedPage = true;
      try { page = await ctx.newPage(); }
      finally { ctx._wisprCreatingSelectedPage = false; }
    }
  }
  // Protect the selected bootstrap tab before its first navigation or any page event.
  ctx._wisprSelectedServicePage = page;
  page._wisprWasServiceTab = true;
  watchOwnedServiceTabs(ctx);
  attachProviderGuards(page);
  if (needsNavigation && !isDictationServicePage(page)) await page.goto(DICTATION_SERVICE_URL);
  pages = ctx.pages().filter(p => !p.isClosed());
  const extraPages = pages.filter(p => p !== page && !/^(?:blob:|data:(?:audio|video)\/)/i.test(p.url()) && !(p._wisprWasServiceTab && !isDictationServicePage(p)));
  if (extraPages.length) console.log(`[wispr-dictate] closing ${extraPages.length} extra service-profile tab(s)`);
  await Promise.all(extraPages.map(p => p.close().catch(() => {})));
  return page;
}

async function getPage() {
  if (_page && !_page.isClosed()) {
    try {
      await _page.evaluate(() => 1);
      _page = await normalizeServicePages(_page.context(), _page);
      return _page;
    } catch (error) {
      if (error.code === 'backend_unavailable') throw error;
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
    } catch (error) {
      if (error.code === 'backend_unavailable') throw error;
      lane.page = null;
    }
  }
  if (lane.browser) { try { await lane.browser.close(); } catch (_) {} lane.browser = null; }
  lane.browser = await chromium.connectOverCDP(lane.cdp, { timeout: 10000 });
  lane.page = await normalizeServicePages(lane.browser.contexts()[0]);
  return lane.page;
}

const DICTATION_LABELS = {
  start: /^(?:Start dictation|Dictate)$/i,
  finish: /^(?:Submit dictation|Stop dictation)$/i,
  cancel: /^Cancel dictation$/i,
  transcribeAndSend: /^Transcribe and send$/i, // NEVER click in Wispr
  transcribing: /^Transcribing dictation$/i
};

const COMPOSER_SELECTORS = [
  '[role="textbox"][aria-label="Ask ChatGPT"][contenteditable="true"]',
  '.ProseMirror[role="textbox"][contenteditable="true"]',
  '#prompt-textarea'
];

async function findComposer(page) {
  for (const selector of COMPOSER_SELECTORS) {
    const candidates = page.locator(selector);
    const count = await candidates.count().catch(() => 0);
    for (let i = 0; i < count; i++) {
      const candidate = candidates.nth(i);
      if (await candidate.isVisible().catch(() => false)) {
        return candidate;
      }
    }
  }
  return null;
}

async function readComposerText(composer) {
  if (!composer) return null;
  return composer.evaluate(el => {
    if (!el) return null;
    if ('value' in el && typeof el.value === 'string') return el.value.trim();
    return (el.innerText || el.textContent || '').trim();
  }).catch(() => null);
}

const composerText = async page => {
  const c = await findComposer(page);
  return readComposerText(c);
};

const dictationUIState = page => page.evaluate(() => {
  const visible = el => {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  };
  const label = el => (el.getAttribute('aria-label') || el.innerText || el.textContent || '').trim();
  const enabled = el => !el.disabled && el.getAttribute('aria-disabled') !== 'true';
  const controls = [...document.querySelectorAll('button,[role="button"]')].filter(visible);
  const hasEnabled = re => controls.some(el => re.test(label(el)) && enabled(el));
  const hasAny = re => controls.some(el => re.test(label(el)));
  const hasDisabled = re => controls.some(el => re.test(label(el)) && !enabled(el));
  // A generic Retry in Voice Settings is unrelated. Require a shared, bounded dictation panel.
  const markers = [...document.querySelectorAll('p,span,div,h1,h2,h3,[role="status"],[role="alert"]')]
    .filter(el => visible(el) && /^Dictation stopped$/i.test((el.innerText || el.textContent || '').trim()));
  let providerStopped = false, viewRecording = false, providerRetry = false;
  for (const marker of markers) {
    let panel = marker.parentElement;
    for (let depth = 0; panel && depth < 5 && panel !== document.body && panel !== document.documentElement; depth++, panel = panel.parentElement) {
      const buttons = [...panel.querySelectorAll('button,[role="button"]')].filter(visible);
      if (!buttons.some(el => /^View recording$/i.test(label(el)))) continue;
      providerStopped = true;
      viewRecording = true;
      providerRetry ||= buttons.some(el => /^Retry$/i.test(label(el)) && enabled(el));
      break;
    }
  }
  const start = hasEnabled(/^(?:Start dictation|Dictate)$/i);
  const finish = hasEnabled(/^(?:Submit dictation|Stop dictation)$/i);
  const cancel = hasEnabled(/^Cancel dictation$/i);
  const retry = hasEnabled(/^Retry dictation$/i) || providerRetry;
  const transcribeAndSend = hasEnabled(/^Transcribe and send$/i);
  const transcribing = hasAny(/^Transcribing dictation$/i);
  const cancelDisabled = hasDisabled(/^Cancel dictation$/i);
  const composerEl = document.querySelector('[role="textbox"][aria-label="Ask ChatGPT"][contenteditable="true"]') ||
                     document.querySelector('.ProseMirror[role="textbox"][contenteditable="true"]') ||
                     document.querySelector('#prompt-textarea');
  let text = '';
  if (composerEl) text = ('value' in composerEl && typeof composerEl.value === 'string') ? composerEl.value.trim() : (composerEl.innerText || composerEl.textContent || '').trim();
  const challenge = /^(?:Just a moment|Attention required|Security verification)/i.test(document.title || '') || [...document.querySelectorAll('iframe[src*="challenges.cloudflare.com"],#challenge-form,#challenge-running,#challenge-stage,[data-testid="challenge-stage"]')].some(visible) ||
    [...document.querySelectorAll('h1,h2,p')].some(el => visible(el) && /^(?:Just a moment\.*|Verify you are human|Verifying you are human|Checking your browser|Performing security verification)$/i.test((el.innerText || el.textContent || '').trim()));
  const settingsView = typeof location !== 'undefined' && /^\/settings(?:\/|$)/.test(location.pathname);
  const recordingView = hasAny(/^(?:Retry transcription|Recording actions|Show all recordings)$/i);
  const accountLoadError = controls.some(el => /^(?:Reload|Try again)$/i.test(label(el))) &&
    [...document.querySelectorAll('h1,h2,h3,p,div')].some(el => visible(el) && /We couldn[’']t load your account|The browser check couldn[’']t finish/i.test((el.innerText || el.textContent || '').trim()));
  return {
    text, composer: visible(composerEl), start, finish, cancel, retry, providerStopped, viewRecording, settingsView, recordingView,
    accountLoadError,
    pendingRecording: retry || providerStopped || viewRecording,
    recordingMedia: [...document.querySelectorAll('audio[src^="blob:"],video[src^="blob:"]')].some(visible),
    pendingHome: !!document.querySelector('#pending-home-input'), challenge,
    loggedOut: [...document.querySelectorAll('button,a,[role="button"]')].filter(visible).some(el => /^log in$|^sign up for free$/i.test(label(el))),
    transcribeAndSend, transcribing, recording: finish && cancel,
    active: cancel || finish || transcribeAndSend, cancelDisabled, submitted: transcribing || cancelDisabled
  };
});

async function dismissStoppedDictationPanel(page) {
  try {
    const dismissBtn = page.locator('button[aria-label="Dismiss"], button:has-text("Dismiss")').first();
    if (await dismissBtn.isVisible({ timeout: 1000 }).catch(() => false)) {
      console.log('[wispr-dictate] found stopped dictation panel; clicking Dismiss to recover');
      await dismissBtn.click().catch(() => {});
      await sleep(1000);
      return true;
    }
  } catch (_) {}
  return false;
}

async function requirePreservedTakeRecovery(state, page = null) {
  if (state.settingsView || state.recordingView) throw makeBackendUnavailable('Voice settings or saved recordings view must return home before dictation; preserving saved recordings');
  if (state.pendingRecording || state.retry || state.providerStopped || state.viewRecording || state.recordingMedia) {
    if (page) {
      const dismissed = await dismissStoppedDictationPanel(page);
      if (dismissed) {
        const after = await dictationUIState(page).catch(() => ({}));
        if (!after.pendingRecording && !after.retry && !after.providerStopped && !after.viewRecording && !after.recordingMedia) return;
      }
    }
    throw makeBackendUnavailable('Stopped or failed dictation is awaiting recovery; preserving the existing recording');
  }
}

async function recoverMisloadedPage(page, signal, owner) {
  throwIfAborted(signal);
  if (!ownsDictationPage(owner)) throw makeBackendUnavailable('Browser recovery requires ownership of the transcription lane');
  let state = await dictationUIState(page);
  await requirePreservedTakeRecovery(state, page);
  if (providerChallengeBlocked(page, state)) throw makeBackendUnavailable('Provider access challenge requires human completion');
  if (state.loggedOut) throw makeBackendUnavailable('Dictation service login requires human completion');
  if (state.text || state.active || state.submitted) throw makeBackendUnavailable('Existing draft or dictation activity prevents browser refresh');
  if (state.composer && state.start) return;

  // Tier 1: If there is an in-page transient account-load error / browser-check failure, click Try again/Reload
  try {
    const retryBtn = page.locator('button:has-text("Try again"), button:has-text("Reload")').first();
    if (await retryBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
      console.log('[wispr-dictate] detected transient account load error; clicking in-page recovery button');
      await retryBtn.click().catch(() => {});
      await sleep(3500);
      state = await dictationUIState(page).catch(() => ({}));
      if (state.composer && state.start) {
        console.log('[wispr-dictate] in-page retry successfully recovered dictation service');
        return;
      }
    }
  } catch (_) {}

  // Tier 2: Dedicated page reload with network settlement
  throwIfAborted(signal);
  console.log('[wispr-dictate] performing automated page reload recovery for misloaded service page');
  try {
    await page.reload({ waitUntil: 'load', timeout: 15000 });
  } catch (_) {
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 10000 }).catch(() => {});
  }
  await sleep(3000);
  state = await waitForUIState(page, st => st.pendingRecording || st.settingsView || st.recordingView || st.challenge || st.loggedOut || (st.composer && st.start), 12000, signal);
  await requirePreservedTakeRecovery(state, page);
  if (providerChallengeBlocked(page, state)) throw makeBackendUnavailable('Provider access challenge requires human completion');
  if (state.loggedOut) throw makeBackendUnavailable('Dictation service login requires human completion');
  if (!state.composer || !state.start) throw makeBackendUnavailable('Dictation service did not become ready after automated idle refresh');
}

async function ensureHighestThinkingEffort(page, owner) {
  if (!ownsDictationPage(owner)) throw makeBackendUnavailable('Thinking effort selection requires ownership of the transcription lane');
  const state = await dictationUIState(page);
  await requirePreservedTakeRecovery(state, page);
  if (state.text || state.active || state.submitted || providerChallengeBlocked(page, state) || state.loggedOut || !state.composer || !state.start) {
    throw makeBackendUnavailable('Thinking effort can only be configured on an idle, ready dictation page');
  }
  const button = page.locator('button[aria-label="Select ChatGPT model"]:visible');
  if (await button.count() !== 1) return;
  const normalized = text => String(text || '').replace(/\s+/g, ' ').trim();
  if (normalized(await button.innerText()) === 'Extra High') return;
  let opened = false;
  try {
    if (await button.getAttribute('aria-expanded') !== 'true') await button.click({ timeout: 3000 });
    opened = true;
    await sleep(250);
    const menu = page.locator('[role="menu"]:visible');
    await menu.waitFor({ state: 'visible', timeout: 3000 });
    if (await menu.count() !== 1) throw makeBackendUnavailable('Thinking effort menu is missing or ambiguous');
    const slider = menu.locator('[role="slider"]:visible');
    if (await slider.count() !== 1) throw makeBackendUnavailable('Verified thinking effort slider is missing or ambiguous');
    if (!await slider.isEnabled() || await slider.getAttribute('aria-disabled') === 'true') throw makeBackendUnavailable('Verified thinking effort slider is disabled; preserving the selected model');
    const minimum = await slider.getAttribute('aria-valuemin');
    const maximum = await slider.getAttribute('aria-valuemax');
    const currentAttribute = await slider.getAttribute('aria-valuenow');
    let current = Number(currentAttribute);
    if (currentAttribute === null || minimum !== '0' || maximum !== '4' || !Number.isInteger(current) || current < 0 || current > 4) {
      throw makeBackendUnavailable('Thinking effort slider contract changed; preserving the selected model');
    }
    // Value 3 is the verified available Extra High level. Value 4 is locked; never use End/max.
    while (current !== 3) {
      const expected = current + (current < 3 ? 1 : -1);
      await slider.press(current < 3 ? 'ArrowRight' : 'ArrowLeft');
      let observed = current;
      for (let attempt = 0; attempt < 10; attempt++) {
        observed = Number(await slider.getAttribute('aria-valuenow'));
        if (observed === expected) break;
        await sleep(50);
      }
      if (observed !== expected) throw makeBackendUnavailable('Thinking effort slider did not accept the verified bounded step');
      current = observed;
    }
    const items = menu.locator('[role="menuitem"]:visible');
    let confirmed = false;
    for (let i = 0; i < await items.count(); i++) confirmed ||= normalized(await items.nth(i).innerText()) === 'Extra High';
    if (!confirmed) throw makeBackendUnavailable('Thinking effort level 3 did not render the verified Extra High label');
  } finally {
    if (opened && await page.locator('[role="menu"]:visible').count().catch(() => 0)) await page.keyboard.press('Escape').catch(() => {});
  }
  if (normalized(await button.innerText()) !== 'Extra High') throw makeBackendUnavailable('Thinking effort selection did not persist as Extra High');
}

async function clickDictationControl(page, kind, timeout = 4000) {
  const re = DICTATION_LABELS[kind];
  if (!re) throw new Error(`Unknown dictation control kind: ${kind}`);
  if (kind === 'transcribeAndSend') throw new Error('Wispr is forbidden from clicking transcribeAndSend');

  const controls = page.locator('button[aria-label], [role="button"][aria-label]');
  const count = await controls.count();
  for (let i = 0; i < count; i++) {
    const el = controls.nth(i);
    const label = await el.getAttribute('aria-label');
    if (label && re.test(label) && await el.isVisible()) {
      await el.click({ timeout });
      return true;
    }
  }
  return false;
}

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

    const target = document.querySelector('button[aria-label="Dictate"],button[aria-label="Start dictation"],button[aria-label="Stop dictation"],button[aria-label="Submit dictation"]') ||
                   document.querySelector('[role="textbox"][aria-label="Ask ChatGPT"]') ||
                   document.querySelector('#prompt-textarea');
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

async function dismissBlockingModal(page, owner) {
  if (!ownsDictationPage(owner)) throw makeBackendUnavailable('Modal recovery requires ownership of the transcription lane');
  const state = await dictationUIState(page);
  await requirePreservedTakeRecovery(state, page);
  if (providerChallengeBlocked(page, state)) throw makeBackendUnavailable('Provider access challenge requires human completion');
  if (state.text || state.active || state.submitted) throw makeBackendUnavailable('Existing draft or dictation activity prevents modal recovery');
  let before = await blockingModalState(page);
  if (!before) return null;

  // Tier 1: Primary self-healing — trigger page reload to flush transient promotional/announcement overlays
  try {
    console.log(`[wispr-dictate] attempting primary recovery (reload) for ${blockerLabel(before)}`);
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 8000 });
    await sleep(2500);
    before = await blockingModalState(page);
    if (!before) {
      console.log('[wispr-dictate] primary recovery (reload) successfully unblocked dictation');
      return null;
    }
  } catch (e) {
    console.warn(`[wispr-dictate] reload recovery failed or timed out: ${e.message}`);
  }

  const afterReload = await dictationUIState(page);
  await requirePreservedTakeRecovery(afterReload, page);
  if (providerChallengeBlocked(page, afterReload)) throw makeBackendUnavailable('Provider access challenge requires human completion');
  if (afterReload.text || afterReload.active || afterReload.submitted) throw makeBackendUnavailable('Existing draft or dictation activity prevents modal recovery');

  // Tier 2: Fallback recovery — targeted modal close selectors and keyboard escape
  const closeSelectors = [
    '#modal-subscription-failure button[aria-label="Close"]',
    '[data-testid="modal-subscription-failure"] button[aria-label="Close"]',
    '#modal-subscription-failure [role="button"][aria-label="Close"]',
    '[data-testid="modal-subscription-failure"] [role="button"][aria-label="Close"]',
    '#modal-subscription-failure button:has-text("Close")',
    '[data-testid="modal-subscription-failure"] button:has-text("Close")',
    '#modal-subscription-failure button:has-text("Not now")',
    '[data-testid="modal-subscription-failure"] button:has-text("Not now")',
    '[role="dialog"] [data-testid="close-button"]',
    '[role="dialog"] button[aria-label="Close"]',
    '[role="dialog"] [role="button"][aria-label="Close"]',
    '[role="dialog"] button:has-text("Close")',
    '[role="dialog"] button:has-text("Dismiss")',
    '[role="dialog"] button:has-text("Not now")',
    '[role="dialog"] button:has-text("Done")',
    '[data-testid="close-button"]',
    'button[aria-label="Close"]',
    'button[aria-label^="Dismiss "]'
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

async function ensureDictationUnblocked(page, owner) {
  let blocker = await blockingModalState(page);
  if (!blocker) return;
  console.warn(`[wispr-dictate] ${blockerLabel(blocker)} blocks dictation; trying to dismiss`);
  blocker = await dismissBlockingModal(page, owner);
  if (blocker) throw makeBackendUnavailable(`Dictation service is blocked by ${blockerLabel(blocker)}`);
}

async function clearComposer(page) {
  const composer = await findComposer(page);
  if (!composer) return false;
  try {
    await composer.clear({ timeout: 3000 }).catch(() => {});
  } catch (_) {}
  const text = await readComposerText(composer);
  if (text === '') return true;
  if (text === null) return false;
  try {
    await composer.click({ timeout: 2000 });
    await page.keyboard.press('ControlOrMeta+A');
    await page.keyboard.press('Backspace');
  } catch (_) {}
  const textAfter = await readComposerText(composer);
  return textAfter === '';
}

// self-heal: if a previous run left dictation active (e.g. client abandoned), cancel it, then clear.
async function resetDictation(page, signal) {
  await dismissStoppedDictationPanel(page);
  const st = await dictationUIState(page).catch(() => ({}));
  await requirePreservedTakeRecovery(st, page);
  if (st.submitted) {
    console.warn('[wispr-dictate] reset: dictation is already transcribing; waiting before next run');
    await waitForUIState(page, s => !s.submitted, 30000, signal).catch(() => null);
  }
  const afterWait = await dictationUIState(page).catch(() => ({}));
  await requirePreservedTakeRecovery(afterWait, page);
  if (afterWait.recording || afterWait.cancel || afterWait.finish || afterWait.active) {
    console.warn('[wispr-dictate] reset: active dictation controls visible; cancelling before next run');
    const clicked = await clickDictationControl(page, 'cancel', 2000).catch(() => false);
    if (!clicked) {
      try { await page.keyboard.press('Escape'); } catch (_) {}
    }
    await waitForUIState(page, s => !s.cancel && !s.finish, 5000, signal).catch(() => null);
  }
  const cleared = await clearComposer(page);
  if (!cleared) {
    throw makeBackendUnavailable('Composer is missing or could not be cleared');
  }
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
    let err = '';
    if (p.stderr) {
      p.stderr.on('data', d => (err += d));
      p.stderr.on('error', () => {});
    }
    if (p.stdin) p.stdin.on('error', () => {});
    if (p.stdout) p.stdout.on('error', () => {});
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
const spawnPacat = () => {
  const p = spawn('pacat',
    ['--playback', '--raw', '--rate=48000', '--format=s16le', '--channels=1',
      '--latency-msec=20', '--process-time-msec=10', '--device=' + SINK],
    { env: { ...process.env, XDG_RUNTIME_DIR: XDG } });
  p.on('error', e => console.warn(`[wispr-dictate] pacat process error: ${e.message || e}`));
  if (p.stdin) p.stdin.on('error', () => {});
  if (p.stdout) p.stdout.on('error', () => {});
  if (p.stderr) p.stderr.on('error', () => {});
  return p;
};
function spawnSourceWarmup(source = SOURCE) {
  if (!STREAM_SOURCE_WARMUP) return null;
  const p = spawn('parec',
    ['--device=' + source, '--raw', '--rate=48000', '--format=s16le', '--channels=1'],
    { env: { ...process.env, XDG_RUNTIME_DIR: XDG }, stdio: ['ignore', 'ignore', 'ignore'] });
  p.on('error', e => console.warn(`[wispr-dictate] source warmup failed for ${source}: ${e.message || e}`));
  return p;
}
function stopSourceWarmup(p) {
  if (!p) return;
  try { p.kill('SIGTERM'); } catch (_) {}
  const t = setTimeout(() => { try { p.kill('SIGKILL'); } catch (_) {} }, 1000);
  if (t.unref) t.unref();
}

async function startDictation(page, signal, owner) {
  throwIfAborted(signal);
  await recoverMisloadedPage(page, signal, owner);
  await ensureDictationUnblocked(page, owner);
  await ensureHighestThinkingEffort(page, owner);
  await resetDictation(page, signal);
  throwIfAborted(signal);
  await ensureDictationUnblocked(page, owner);
  try {
    const st = await waitForUIState(page, s => s.start, 5000, signal);
    if (!st.start) throw new Error('Start dictation control not visible');
    const clicked = await clickDictationControl(page, 'start', 5000);
    if (!clicked) throw new Error('Failed to click start dictation control');
  } catch (e) {
    const blocker = await blockingModalState(page).catch(() => null);
    if (blocker) throw makeBackendUnavailable(`Dictation service is blocked by ${blockerLabel(blocker)}`);
    throw e;
  }
  throwIfAborted(signal);
  try {
    const st = await waitForUIState(page, s => s.recording, 8000, signal);
    if (!st?.recording) {
      throw makeBackendUnavailable(
        `Safe recording state not established (finish=${!!st?.finish}, cancel=${!!st?.cancel}, transcribeAndSend=${!!st?.transcribeAndSend})`
      );
    }
  } catch (e) {
    const blocker = await blockingModalState(page).catch(() => null);
    if (blocker) throw makeBackendUnavailable(`Dictation service is blocked by ${blockerLabel(blocker)}`);
    throw e;
  }
}
async function submitAndScrape(page, timeoutMs = 40000, signal, hooks = {}, audioDurationMs = 0) {
  throwIfAborted(signal);
  let submitted = false;
  let lastFinishClick = 0;
  const clickFinish = async (reason) => {
    const clicked = await clickDictationControl(page, 'finish', 3000).catch(() => false);
    if (clicked) {
      lastFinishClick = Date.now();
      console.log(`[wispr-dictate] finish click (${reason})`);
    }
    return clicked;
  };

  let apiTranscribeDone = false;
  let apiTranscribeText = null;
  const onTranscribeResponse = async (resp) => {
    try {
      if (resp.url().includes('/backend-api/transcribe') && resp.request().method() === 'POST') {
        apiTranscribeDone = true;
        if (resp.status() === 200) {
          const json = await resp.json().catch(() => null);
          if (json && typeof json.text === 'string') {
            apiTranscribeText = json.text.trim();
            console.log(`[wispr-dictate] captured /backend-api/transcribe API text (${apiTranscribeText.length} chars)`);
          }
        }
      }
    } catch (_) {}
  };
  page.on('response', onTranscribeResponse);

  const dynamicEmptySettleMs = Math.max(
    EMPTY_TRANSCRIPT_SETTLE_MS,
    Math.min(25000, Math.round(audioDurationMs * 0.18) + 3500)
  );

  try {
    const clickedInitial = await clickFinish('initial');
    if (!clickedInitial) {
      throw makeBackendUnavailable('Safe dictation finish control disappeared before finalization');
    }
    const deadline = Date.now() + timeoutMs;
    let text = '';
    let doneSince = 0;
    let emptyWaitLogged = false;
    let completed = false;
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

      if (st.recording || st.finish || st.cancel) {
        doneSince = 0;
        if (st.finish && Date.now() - lastFinishClick > 2000) await clickFinish('still-recording');
        await abortableSleep(250, signal);
        continue;
      }

      if (!submitted) {
        submitted = true;
        try { hooks.onSubmitted?.(); } catch (_) {}
      }

      text = st.text || apiTranscribeText || '';
      if (text) {
        completed = true;
        break;
      }

      // If OpenAI's transcribe API request is still in-flight, do not cut off wait prematurely
      if (!apiTranscribeDone && (Date.now() - lastFinishClick < dynamicEmptySettleMs)) {
        doneSince = 0;
        await abortableSleep(150, signal);
        continue;
      }

      if (st.start) {
        doneSince ||= Date.now();
        if (!emptyWaitLogged) {
          console.log(`[wispr-dictate] submitted UI returned to idle with empty text; debouncing ${dynamicEmptySettleMs}ms (audio=${Math.round(audioDurationMs)}ms)`);
          emptyWaitLogged = true;
        }
        if (Date.now() - doneSince >= (apiTranscribeDone ? 500 : dynamicEmptySettleMs)) {
          completed = true;
          break;
        }
      } else {
        doneSince = 0;
      }
      await abortableSleep(st.start ? 100 : 250, signal);
    }
    if (!completed) {
      const error = new Error('Dictation did not finish before the transcription deadline');
      error.code = 'transcription_timeout';
      throw error;
    }
    if (!text && apiTranscribeText) {
      text = apiTranscribeText;
    }
    if (!text) {
      const raw = await composerText(page);
      if (typeof raw === 'string') text = raw;
    }
    await clearComposer(page).catch(() => {});
    return text || '';
  } finally {
    page.off('response', onTranscribeResponse);
  }
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
    await startDictation(page, signal, lane || MAIN_PAGE_OWNER);
    await playWavFile(file, durationMs, signal, lane ? lane.sink : SINK);
    await abortableSleep(1200, signal);
    const scrapeMs = Math.max(40000, Math.min(180000, Math.round(durationMs * 0.25) + 30000));
    const text = await submitAndScrape(page, scrapeMs, signal, {}, durationMs);
    console.log(`[wispr-dictate] batch ${laneLabel} final text=${text ? text.length : 0} ms=${Date.now() - t0}`);
    recordResult(!!(text && text.length), Date.now() - t0, text ? undefined : 'empty transcript');
    if (lane) {
      lane.consecutiveFailures = 0;
      lane.unhealthyUntil = 0;
    }
    return text;
  } catch (e) {
    if (page && (e.code === 'client_closed' || (signal && signal.aborted))) {
      try { await resetDictation(page); } catch (_) {}
    }
    recordResult(false, Date.now() - t0, e.message);
    if (lane && e.code !== 'client_closed' && !(signal && signal.aborted)) {
      lane.consecutiveFailures = (lane.consecutiveFailures || 0) + 1;
      const quarantineSec = Math.min(30, 5 * lane.consecutiveFailures);
      lane.unhealthyUntil = Date.now() + quarantineSec * 1000;
      console.warn(`[wispr-dictate] lane=${lane.id} quarantined for ${quarantineSec}s (failures=${lane.consecutiveFailures}): ${e.message}`);
    }
    throw e;
  } finally {
    if (lane) lane.busy = false; else release();
  }
}

// --- streaming mode ---------------------------------------------------------
async function startStream() {
  if (!tryAcquire()) { const e = new Error('busy'); e.code = 'busy'; throw e; }
  const t0 = Date.now();
  let sourceWarmup = null;
  try {
    const page = await getPage();
    sourceWarmup = spawnSourceWarmup(SOURCE);
    await startDictation(page, undefined, MAIN_PAGE_OWNER);
    const pacat = spawnPacat();
    pacat.on('error', () => {});
    return { page, pacat, sourceWarmup, t0: Date.now(), bytesWritten: 0, firstAudioAt: 0 };
  } catch (e) {
    stopSourceWarmup(sourceWarmup);
    recordResult(false, Date.now() - t0, `stream start failed: ${e.message}`);
    console.warn(`[wispr-dictate] stream start failed: ${e.stack || e.message}`);
    release();
    throw e;
  }
}
function pushAudio(s, buf) {
  try {
    if (s && s.pacat && s.pacat.stdin && s.pacat.stdin.writable) {
      s.pacat.stdin.write(buf);
      if (!s.firstAudioAt) s.firstAudioAt = Date.now();
      s.bytesWritten = (s.bytesWritten || 0) + buf.length; // total audio handed to pacat (will be played)
    }
  } catch (_) {}
}
async function writeEndSilence(s, ms) {
  const target = Math.max(0, Math.round(ms || 0));
  if (!target || !s || !s.pacat || !s.pacat.stdin || !s.pacat.stdin.writable) return 0;
  const chunks = Math.ceil(target / 20);
  for (let i = 0; i < chunks; i++) {
    if (!s.pacat.stdin || !s.pacat.stdin.writable) break;
    try {
      if (!s.pacat.stdin.write(STREAM_END_SILENCE_CHUNK)) {
        await new Promise(resolve => {
          s.pacat.stdin.once('drain', resolve);
          s.pacat.stdin.once('error', resolve);
        });
      }
      s.bytesWritten = (s.bytesWritten || 0) + STREAM_END_SILENCE_CHUNK.length;
    } catch (_) {
      break;
    }
    await sleep(20);
  }
  return chunks * 20;
}
async function stopStream(s, hooks = {}) {
  try {
    const drainStarted = Date.now();
    const endSilenceMs = await writeEndSilence(s, STREAM_END_SILENCE_MS);
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
      console.log(`[wispr-dictate] drain est wrote=${Math.round(wroteMs)}ms played=${playedMs}ms tail=${tailMs}ms wait=${waitMs}ms silence=${endSilenceMs}ms bytes=${s.bytesWritten || 0}`);
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
    const audioMs = (s.bytesWritten || 0) / BYTES_PER_MS;
    const text = await submitAndScrape(s.page, 40000, undefined, {
      onSubmitted: hooks.onSubmitting
    }, audioMs);
    console.log(`[wispr-dictate] stream stop drain=${drainMs}ms mode=${mode} tail=${tailMs}ms silence=${endSilenceMs}ms text=${text ? text.length : 0}`);
    recordResult(!!(text && text.length), Date.now() - s.t0, text ? undefined : 'empty transcript');
    return { text, duration_ms: Date.now() - s.t0 };
  } catch (e) { recordResult(false, Date.now() - s.t0, e.message); throw e; }
  finally { try { s.pacat.kill(); } catch (_) {} stopSourceWarmup(s.sourceWarmup); release(); }
}
async function abortStream(s) {
  try { s.pacat.kill(); } catch (_) {}
  stopSourceWarmup(s.sourceWarmup);
  try { await resetDictation(s.page); } catch (_) {}
  release();
}

// --- strictly observational health probe (independent of the transcribe mutex/page) ------
function isBusy() { return _busy; }
async function servicePageTargetId(page) {
  let session;
  try {
    session = await page.context().newCDPSession(page);
    const result = await session.send('Target.getTargetInfo');
    return result.targetInfo?.targetId || null;
  } catch (_) { return null; }
  finally { try { if (session) await session.detach(); } catch (_) {} }
}

async function probe() {
  let b;
  try {
    b = await chromium.connectOverCDP(CDP, { timeout: 4000 });
    const pages = b.contexts()[0]?.pages() || [];
    const page = pages.find(p => !p.isClosed() && isDictationServicePage(p));
    if (!page) {
      return { browser: 'up', dictationService: 'loading' };
    }
    const blocker = await blockingModalState(page).catch(() => null);
    const st = await dictationUIState(page).catch(() => ({}));
    let guardedPage = page;
    if (_page && !_page.isClosed() && (_page._wisprChallengeBlocked || _page._wisprResolvedHomeDocument)) {
      const [cachedTarget, observedTarget] = await Promise.all([servicePageTargetId(_page), servicePageTargetId(page)]);
      if (!cachedTarget || cachedTarget !== observedTarget) {
        return { browser: 'up', dictationService: 'blocked', blocker: 'guarded primary service target could not be verified' };
      }
      guardedPage = _page;
    }
    if (providerChallengeBlocked(guardedPage, st)) return { browser: 'up', dictationService: 'blocked', blocker: 'provider access challenge requires human completion' };
    if (st.accountLoadError) return { browser: 'up', dictationService: 'blocked', blocker: 'transient account load error; automated recovery required' };
    if (st.settingsView || st.recordingView) return { browser: 'up', dictationService: 'blocked', blocker: 'voice settings or saved recordings view needs returning home' };
    if (st.pendingRecording || st.retry || st.providerStopped || st.viewRecording || st.recordingMedia) return { browser: 'up', dictationService: 'blocked', blocker: 'stopped or failed dictation awaiting recording recovery' };
    if (blocker) return { browser: 'up', dictationService: 'blocked', blocker: blockerLabel(blocker) };
    if (st.loggedOut) return { browser: 'up', dictationService: 'logged_out' };
    const ready = Boolean(st.composer && st.start);
    return { browser: 'up', dictationService: ready ? 'ready' : 'loading' };
  } catch (_) {
    return { browser: 'down', dictationService: 'unreachable' };
  } finally { try { await b.close(); } catch (_) {} }
}

async function warmupLanes() {
  const tasks = [];
  const warmLane = async (fn, label, owner) => {
    const acquired = owner === MAIN_PAGE_OWNER ? tryAcquire() : !owner.busy;
    if (!acquired) return { label, skipped: true };
    if (owner !== MAIN_PAGE_OWNER) owner.busy = true;
    try {
      const page = await fn();
      if (page) {
        await recoverMisloadedPage(page, null, owner).catch(() => {});
        await ensureDictationUnblocked(page, owner).catch(() => {});
        await ensureHighestThinkingEffort(page, owner).catch(() => {});
      }
      return { label, skipped: false };
    } finally {
      if (owner === MAIN_PAGE_OWNER) release(); else owner.busy = false;
    }
  };
  tasks.push(warmLane(getPage, 'main', MAIN_PAGE_OWNER));
  for (const lane of _lanes) tasks.push(warmLane(() => getLanePage(lane), `lane-${lane.id}`, lane));
  const results = await Promise.allSettled(tasks);
  let ok = 0, skipped = 0;
  for (const result of results) {
    if (result.status === 'fulfilled') {
      if (result.value.skipped) skipped++; else ok++;
    } else console.warn(`[wispr-dictate] warmup failed: ${result.reason?.message || result.reason}`);
  }
  console.log(`[wispr-dictate] pre-warmed ${ok}/${tasks.length} lane(s); ${skipped} active lane(s) left untouched`);
}

module.exports = { transcribe, transcribeFile, startStream, pushAudio, stopStream, abortStream, probe, isBusy, batchBusy, lastResult, warmupLanes };

if (require.main === module) {
  const wav = process.argv[2];
  if (!wav) { console.error('usage: node dictate.js <wav>'); process.exit(1); }
  const t0 = Date.now();
  transcribe(fs.readFileSync(wav))
    .then(t => { console.log(`(${Date.now() - t0}ms) TRANSCRIPT: ${JSON.stringify(t)}`); process.exit(0); })
    .catch(e => { console.error('ERR', e.stack || e.message); process.exit(1); });
}
