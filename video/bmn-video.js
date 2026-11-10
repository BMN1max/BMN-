/* BMN video engine.  window.BMNVideo
 *
 * Takes over <video> elements whose source is a BMN R2 playback link
 * (…/api/media/play?key=uploads/<user>/<video>.<ext>) and plays the processed version instead:
 *
 *   adaptive HLS  ->  progressive compressed MP4  ->  the original upload   (first that works)
 *
 *  - A video only gets a source while it is near the screen, and loses it again (and stops
 *    downloading) when it is far away. A video that is not visible is paused.
 *  - Nothing is preloaded beyond playlists and about one segment; playing raises the buffer a bit.
 *  - Data mode  auto | low | high  caps the quality: low = 360p, auto = by network / screen,
 *    high = best available. Existing videos with no processed version keep playing the original.
 *  - Videos that are not BMN R2 links (Supabase storage, blob:, camera previews) are never touched.
 */
(() => {
  'use strict';
  if (window.BMNVideo) return;

  const HLS_VERSION = '1.5.17';
  const KEY_RE = /^uploads\/[0-9a-f-]{36}\/([0-9a-f-]{36})\.(mp4|mov|webm)$/i;
  const INFO_OK_TTL = 10 * 60 * 1000;
  const INFO_WAIT_TTL = 20 * 1000;
  const WATCHDOG_MS = 10000;
  const SETTINGS_KEY = 'lgtt:v1';

  const cfg = { mode: 'auto', dataSaver: false };
  const log = (...a) => { if (window.BMN_VIDEO_DEBUG) console.log('[BMNVideo]', ...a); };

  /* ------------------------------------------------------------------ settings */
  function readSettings() {
    try {
      const s = JSON.parse(localStorage.getItem(SETTINGS_KEY) || 'null');
      if (s && s.settings) {
        if (['auto', 'low', 'high'].includes(s.settings.videoData)) cfg.mode = s.settings.videoData;
        cfg.dataSaver = !!s.settings.dataSaver;
      }
    } catch (_) { /* storage unavailable */ }
  }
  readSettings();

  const conn = () => navigator.connection || navigator.mozConnection || navigator.webkitConnection || null;
  const effectiveMode = () => (cfg.mode === 'auto' && cfg.dataSaver ? 'low' : cfg.mode);

  /** Largest picture short side (px) we are willing to download right now. */
  function capShort() {
    const m = effectiveMode();
    if (m === 'low') return 360;
    if (m === 'high') return 1080;
    const c = conn();
    if (c) {
      if (c.saveData) return 360;
      const et = String(c.effectiveType || '');
      if (et === 'slow-2g' || et === '2g' || et === '3g') return 360;
      if (c.type === 'cellular') return 540;
      if (et === '4g' && c.downlink && c.downlink < 2.5) return 540;
    }
    // Browsers without the Network Information API (iOS Safari) and fast links: a phone
    // screen never needs more than 720p, big screens may use 1080p.
    return Math.min(screen.width, screen.height) >= 700 ? 1080 : 720;
  }

  /**
   * How much a video that is NOT playing may fetch ahead. 'none' = nothing (the poster is shown),
   * 'metadata' = playlist + first bytes so the first frame appears sooner. Only high quality
   * mode, or Auto on a Wi-Fi/Ethernet link, is allowed to look ahead; everything else waits for play.
   */
  function idlePreload() {
    const m = effectiveMode();
    if (m === 'high') return 'metadata';
    if (m === 'auto') {
      const c = conn();
      if (c && !c.saveData && (c.type === 'wifi' || c.type === 'ethernet')) return 'metadata';
    }
    return 'none';
  }

  /* ------------------------------------------------------------------ keys + info */
  function parse(url) {
    try {
      const u = new URL(url, location.href);
      if (!/\/api\/media\/play$/.test(u.pathname)) return null;
      const key = u.searchParams.get('key');
      const m = KEY_RE.exec(key || '');
      if (!m) return null;
      u.hash = '';
      return { base: u.origin, key, orig: u.href };
    } catch (_) { return null; }
  }

  const cache = new Map();        // key -> { v, exp }
  const waiting = new Map();      // key -> { base, resolvers[] }
  const enqueued = new Set();
  let flushTimer = 0;

  const token = async () => {
    try { const r = await window.bmnSupabase.auth.getSession(); return r.data.session.access_token; } catch (_) { return ''; }
  };

  function getInfo(p) {
    const hit = cache.get(p.key);
    if (hit && hit.exp > Date.now()) return Promise.resolve(hit.v);
    return new Promise((resolve) => {
      let w = waiting.get(p.key);
      if (!w) { w = { base: p.base, resolvers: [] }; waiting.set(p.key, w); }
      w.resolvers.push(resolve);
      if (!flushTimer) flushTimer = setTimeout(flush, 25);
    });
  }
  const peek = (p) => { const h = cache.get(p.key); return h && h.exp > Date.now() ? h.v : undefined; };

  async function flush() {
    flushTimer = 0;
    const batch = [...waiting.entries()];
    waiting.clear();
    const byBase = new Map();
    for (const [key, w] of batch) {
      if (!byBase.has(w.base)) byBase.set(w.base, []);
      byBase.get(w.base).push([key, w]);
    }
    for (const [base, entries] of byBase) {
      for (let i = 0; i < entries.length; i += 24) {
        const part = entries.slice(i, i + 24);
        const keys = part.map((e) => e[0]);
        let items = null;
        try {
          const r = await fetch(`${base}/api/media/info?keys=${keys.map(encodeURIComponent).join(',')}`);
          if (r.ok) items = (await r.json()).items || {};
        } catch (_) { /* offline / API asleep: fall back to originals */ }
        for (const [key, w] of part) {
          const v = items && items[key] ? items[key] : { status: 'unavailable' };
          const ready = v.status === 'ready';
          cache.set(key, { v, exp: Date.now() + (ready ? INFO_OK_TTL : INFO_WAIT_TTL) });
          w.resolvers.forEach((res) => res(v));
          if (v.status === 'none' && !enqueued.has(key)) enqueueOld(base, key);
        }
      }
    }
  }

  // Videos posted before the pipeline existed: ask the API (signed in) to queue them once.
  async function enqueueOld(base, key) {
    enqueued.add(key);
    const t = await token();
    if (!t) return;
    try { await fetch(`${base}/api/media/info?keys=${encodeURIComponent(key)}`, { headers: { Authorization: `Bearer ${t}` } }); } catch (_) { /* ignore */ }
  }

  /* ------------------------------------------------------------------ hls.js (lazy) */
  let hlsPromise = null;
  let hlsFailedAt = 0;
  function loadHls() {
    if (window.Hls && window.Hls.isSupported && window.Hls.isSupported()) return Promise.resolve(window.Hls);
    if (hlsPromise) return hlsPromise;
    if (Date.now() - hlsFailedAt < 60000) return Promise.reject(new Error('hls.js unavailable'));
    const urls = [
      window.BMN_HLS_JS_URL,
      `https://cdn.jsdelivr.net/npm/hls.js@${HLS_VERSION}/dist/hls.min.js`,
      `https://unpkg.com/hls.js@${HLS_VERSION}/dist/hls.min.js`
    ].filter(Boolean);
    hlsPromise = (async () => {
      for (const u of urls) {
        try {
          await new Promise((res, rej) => {
            const s = document.createElement('script');
            s.src = u; s.async = true; s.onload = res; s.onerror = rej;
            document.head.appendChild(s);
          });
          if (window.Hls && window.Hls.isSupported()) return window.Hls;
        } catch (_) { /* try next */ }
      }
      throw new Error('hls.js unavailable');
    })();
    hlsPromise.catch(() => { hlsPromise = null; hlsFailedAt = Date.now(); });
    return hlsPromise;
  }

  const nativeHls = (v) => !!v.canPlayType && v.canPlayType('application/vnd.apple.mpegurl') !== '';

  /* ------------------------------------------------------------------ per-video state */
  const recs = new WeakMap();
  const all = new Set();          // weak-ish: removed on disconnect scans

  function prep(v) {
    v.setAttribute('playsinline', '');
    v.setAttribute('webkit-playsinline', '');
    v.playsInline = true;
    if (!v.hasAttribute('x-webkit-airplay')) v.setAttribute('x-webkit-airplay', 'allow');
  }

  function setSrc(v, rec, url) {
    rec.own = url;
    v.setAttribute('src', url);
  }

  function teardown(v, rec) {
    clearTimeout(rec.watch);
    if (rec.hls) { try { rec.hls.destroy(); } catch (_) { /* ignore */ } rec.hls = null; }
    rec.listeners.forEach(([t, fn]) => v.removeEventListener(t, fn));
    rec.listeners = [];
    if (v.getAttribute('src')) { rec.own = null; v.removeAttribute('src'); try { v.load(); } catch (_) { /* ignore */ } }
  }

  function listen(v, rec, type, fn) { v.addEventListener(type, fn); rec.listeners.push([type, fn]); }

  function register(v) {
    if (recs.has(v)) return recs.get(v);
    if (v.srcObject || v.closest('#bmnCam,#lgttCreate,#bmnOverlayPreviewV17,.bmn-cam-prev')) return null;
    const p = parse(v.getAttribute('src') || v.dataset.bmnSrc || '');
    if (!p) return null;
    const rec = { p, active: false, gen: 0, mode: '', chain: [], stage: -1, hls: null, listeners: [], own: null, watch: 0, resume: null };
    recs.set(v, rec); all.add(v);
    prep(v);
    // Strip the original now so nothing is fetched until the video is actually near the screen.
    v.dataset.bmnSrc = p.orig;
    // play() may already have been called on the freshly inserted element; stripping its source
    // aborts that, so remember it and start again once the right source is attached.
    if (!v.paused && !v.ended) { rec.wantPlay = true; }
    if (v.getAttribute('src')) { v.removeAttribute('src'); try { v.load(); } catch (_) { /* ignore */ } }
    v.preload = 'none';
    if (v.closest('.lgtt-slide')) v.removeAttribute('autoplay');
    (v.closest('.lgtt-slide') ? nearSlide : nearTile).observe(v);
    viewport.observe(v);
    preposter(v, rec);
    return rec;
  }

  // Show the poster as soon as we know it (needs the info call, which is one tiny batch request).
  function preposter(v, rec) {
    getInfo(rec.p).then((info) => { if (info && info.poster && !v.poster) v.poster = info.poster; });
  }

  /* ------------------------------------------------------------------ activate / deactivate */
  function activate(v, rec, immediate) {
    if (rec.active) return;
    rec.active = true;
    const gen = ++rec.gen;
    const known = peek(rec.p);
    if (known !== undefined) return begin(v, rec, known, gen);
    if (immediate) return begin(v, rec, { status: 'unavailable' }, gen);   // user pressed play: no waiting
    getInfo(rec.p).then((info) => { if (rec.gen === gen && rec.active) begin(v, rec, info, gen); });
  }

  function deactivate(v, rec) {
    if (!rec.active) return;
    if (!v.paused && !v.ended) return;   // never cut a video that is playing
    rec.active = false; rec.gen++; rec.mode = '';
    teardown(v, rec);
    v.preload = 'none';
  }

  function begin(v, rec, info, gen) {
    const chain = [];
    if (info && info.poster && !v.poster) v.poster = info.poster;
    if (info && info.status === 'ready') {
      if (info.hls) chain.push(nativeHls(v) ? 'native' : 'hlsjs');
      const low = capShort() <= 360;
      const mp4 = low ? (info.mp4_low || info.mp4_main) : (info.mp4_main || info.mp4_low);
      if (mp4) chain.push({ mp4 });
    }
    chain.push('orig');
    rec.info = info; rec.chain = chain; rec.stage = -1; rec.gen = gen;
    advance(v, rec, gen);
  }

  function advance(v, rec, gen) {
    if (rec.gen !== gen || !rec.active) return;
    const resumeAt = v.currentTime || 0;
    const wasPlaying = !v.paused && !v.ended;
    teardown(v, rec);
    rec.stage += 1;
    const step = rec.chain[rec.stage] || 'orig';
    const failNext = () => advance(v, rec, gen);

    const afterMeta = () => {
      if (resumeAt > 0.5) { try { v.currentTime = resumeAt; } catch (_) { /* ignore */ } }
      if (wasPlaying) v.play().catch(() => {});
    };
    if (resumeAt > 0.5 || wasPlaying) listen(v, rec, 'loadedmetadata', afterMeta);

    // A source that never produces metadata is treated as failed.
    // (Only armed once something is actually being loaded: an idle video with preload=none is not "stuck".)
    const arm = () => {
      clearTimeout(rec.watch);
      rec.watch = setTimeout(() => { if (v.readyState === 0 && rec.gen === gen && rec.stage < rec.chain.length - 1) failNext(); }, WATCHDOG_MS);
    };
    if (idlePreload() !== 'none' || !v.paused) arm();
    listen(v, rec, 'play', arm);
    listen(v, rec, 'loadedmetadata', () => clearTimeout(rec.watch));
    listen(v, rec, 'error', () => { if (rec.stage < rec.chain.length - 1) failNext(); });

    v.preload = idlePreload();
    log('stage', step, rec.p.key);

    // Chromium's built-in HLS player only accepts cross-origin segments in CORS mode, so the
    // HLS stage asks for it (the R2 bucket must allow GET from this site, see docs). Every other
    // stage restores the element's own setting so the original file never depends on R2 CORS.
    if (!('hadCO' in rec)) rec.hadCO = v.getAttribute('crossorigin');
    if (step === 'native') v.crossOrigin = 'anonymous';
    else if (rec.hadCO === null) v.removeAttribute('crossorigin');
    else v.setAttribute('crossorigin', rec.hadCO);

    const replay = () => { if (rec.wantPlay && rec.mode !== 'hls.js' && v.paused) v.play().catch(() => {}); };
    listen(v, rec, 'pause', () => { rec.wantPlay = false; });
    if (step === 'native') {
      rec.mode = 'hls-native';
      setSrc(v, rec, `${rec.info.hls}&cap=${capShort()}`);
      replay();
    } else if (step === 'hlsjs') {
      rec.mode = 'hls.js';
      loadHls().then((Hls) => {
        if (rec.gen !== gen || !rec.active || rec.stage !== rec.chain.indexOf(step)) return;
        const c = conn();
        const est = c && c.downlink ? Math.round(c.downlink * 1e6 * 0.7) : 1.5e6;
        const h = new Hls({
          autoStartLoad: idlePreload() !== 'none' || !v.paused, startLevel: 0, capLevelToPlayerSize: true,
          maxBufferLength: 2, maxMaxBufferLength: 24, maxBufferSize: 8e6, backBufferLength: 8,
          abrEwmaDefaultEstimate: est, lowLatencyMode: false, enableWorker: true
        });
        rec.hls = h;
        let retriedNet = false; let retriedMedia = false;
        h.on(Hls.Events.ERROR, (_e, d) => {
          if (!d.fatal) return;
          if (d.type === Hls.ErrorTypes.NETWORK_ERROR && !retriedNet) { retriedNet = true; h.startLoad(); return; }
          if (d.type === Hls.ErrorTypes.MEDIA_ERROR && !retriedMedia) { retriedMedia = true; h.recoverMediaError(); return; }
          failNext();
        });
        h.on(Hls.Events.MANIFEST_PARSED, () => { if (rec.wantPlay && v.paused) v.play().catch(() => {}); });
        h.loadSource(`${rec.info.hls}&cap=${capShort()}`);
        h.attachMedia(v);
        // Play raises the buffer from "one segment" to a comfortable few seconds.
        listen(v, rec, 'play', () => { if (rec.hls) { rec.hls.config.maxBufferLength = 12; try { rec.hls.startLoad(-1); } catch (_) { /* ignore */ } } });
        listen(v, rec, 'pause', () => { if (rec.hls) rec.hls.config.maxBufferLength = 2; });
      }).catch(failNext);
    } else if (step && step.mp4) {
      rec.mode = 'mp4';
      setSrc(v, rec, step.mp4);
      replay();
    } else {
      rec.mode = 'orig';
      setSrc(v, rec, rec.p.orig);
      replay();
    }
  }

  /* ------------------------------------------------------------------ observers */
  const nearOpts = (margin) => ({ rootMargin: margin });
  const handle = (es) => es.forEach((e) => {
    const v = e.target; const rec = recs.get(v); if (!rec) return;
    if (e.isIntersecting) activate(v, rec, false); else deactivate(v, rec);
  });
  const nearSlide = new IntersectionObserver(handle, nearOpts('100% 0px 100% 0px'));
  const nearTile = new IntersectionObserver(handle, nearOpts('160px'));

  // Safety net: a video that scrolled out of view must not keep playing (and downloading).
  const viewport = new IntersectionObserver((es) => es.forEach((e) => {
    const v = e.target;
    if (e.intersectionRatio >= 0.2 || v.paused || v.ended) return;
    if (document.pictureInPictureElement === v || v.webkitDisplayingFullscreen) return;
    if (document.fullscreenElement && document.fullscreenElement.contains(v)) return;
    v.pause();
  }), { threshold: [0, 0.2, 0.5] });

  document.addEventListener('visibilitychange', () => {
    for (const v of all) {
      if (!v.isConnected) { all.delete(v); continue; }
      if (document.hidden && !v.paused && document.pictureInPictureElement !== v) { v.__bvHidden = true; v.pause(); }
      else if (!document.hidden && v.__bvHidden) {
        v.__bvHidden = false;
        const r = v.getBoundingClientRect();
        const vis = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0);
        if (r.height > 0 && vis / r.height > 0.5) v.play().catch(() => {});
      }
    }
  });

  // The feed code asks neighbours to "preload=auto" so swipes feel instant. For BMN videos that
  // would download videos nobody has watched, so a paused video is held to idlePreload().
  try {
    const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'preload');
    if (d && d.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'preload', {
        configurable: true, enumerable: d.enumerable, get: d.get,
        set(val) { try { if ((val === 'auto' || val === 'metadata') && recs.has(this) && this.paused) val = idlePreload(); } catch (_) { /* ignore */ } d.set.call(this, val); }
      });
    }
  } catch (_) { /* ignore */ }

  // play() must find a source already attached (a play() that is pending while a source is
  // assigned later gets aborted). A video that has not been activated yet waits a moment for the
  // processed version (one tiny API call) instead of falling back to the big original file.
  const INFO_WAIT_MS = 1500;
  const needsSyncPlay = (v) => !!(navigator.userActivation && navigator.userActivation.isActive && !v.muted);
  try {
    const origPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () {
      const v = this; const rec = recs.get(v); const args = arguments;
      if (rec) rec.wantPlay = true;
      if (!rec || rec.mode || v.getAttribute('src')) return origPlay.apply(v, args);
      if (peek(rec.p) !== undefined || needsSyncPlay(v)) { api.ensure(v); return origPlay.apply(v, args); }
      rec.wantPlay = true;
      return new Promise((resolve, reject) => {
        let done = false;
        const go = () => {
          if (done) return; done = true;
          if (!rec.active) activate(v, rec, true);
          else if (!rec.mode) begin(v, rec, peek(rec.p) || { status: 'unavailable' }, ++rec.gen);
          if (rec.mode === 'hls.js' && !v.getAttribute('src')) return resolve();   // hls.js starts playback once attached
          origPlay.apply(v, args).then(resolve, reject);
        };
        activate(v, rec, false);
        getInfo(rec.p).then(() => setTimeout(go, 0));
        setTimeout(go, INFO_WAIT_MS);
      });
    };
  } catch (_) { /* ignore */ }

  /* ------------------------------------------------------------------ DOM discovery */
  const looksBmn = (v) => /\/api\/media\/play\?/.test(v.getAttribute('src') || '');
  function scan(root) {
    for (const v of all) {
      if (v.isConnected) continue;
      const rec = recs.get(v);
      if (rec) teardown(v, rec);
      all.delete(v); nearSlide.unobserve(v); nearTile.unobserve(v); viewport.unobserve(v);
    }
    (root || document).querySelectorAll('video[src]').forEach((v) => {
      const rec = recs.get(v);
      if (rec) {
        const s = v.getAttribute('src');
        if (s && s !== rec.own && looksBmn(v)) { // element reused for a different post
          teardown(v, rec); recs.delete(v); nearSlide.unobserve(v); nearTile.unobserve(v); viewport.unobserve(v);
          register(v);
        }
      } else if (looksBmn(v)) register(v);
    });
  }
  new MutationObserver(() => scan()).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: ['src']
  });
  scan();

  /* ------------------------------------------------------------------ public API */
  const api = {
    version: 1,
    handles(v) { return recs.has(v); },
    /** Make sure a video has a source *now* (used when play() is called). */
    ensure(v) {
      const rec = recs.get(v);
      if (!rec) return false;
      rec.wantPlay = true;
      if (!rec.active) activate(v, rec, true);
      else if (!rec.mode) begin(v, rec, peek(rec.p) || { status: 'unavailable' }, ++rec.gen);   // info still pending: do not make play() wait
      return true;
    },
    activate(v) { const rec = recs.get(v) || register(v); if (rec) activate(v, rec, false); return !!rec; },
    deactivate(v) { const rec = recs.get(v); if (rec) deactivate(v, rec); },
    originalUrl(v) { const rec = recs.get(v); return rec ? rec.p.orig : (v && (v.dataset.bmnSrc || v.currentSrc || v.src)) || ''; },
    mode(v) { const rec = recs.get(v); return rec ? rec.mode : ''; },
    getMode: () => cfg.mode,
    effectiveMode,
    capShort,
    configure(o) {
      if (o && ['auto', 'low', 'high'].includes(o.mode)) cfg.mode = o.mode;
      if (o && typeof o.dataSaver === 'boolean') cfg.dataSaver = o.dataSaver;
      // Idle videos restart with the new cap when they are next activated; a playing hls.js video is
      // only ever capped DOWN immediately (it never jumps to a bigger download mid-play).
      const cap = capShort();
      for (const v of all) {
        const rec = recs.get(v);
        if (!rec || !rec.active) continue;
        if (rec.hls && rec.hls.levels) {
          let idx = -1;
          rec.hls.levels.forEach((l, i) => { if (Math.min(l.width, l.height) <= cap) idx = i; });
          rec.hls.autoLevelCapping = idx < 0 ? 0 : idx;
        } else if (v.paused && rec.mode !== 'orig') {
          rec.active = false; rec.gen++; teardown(v, rec); activate(v, rec, false);
        }
      }
    },
    keyOf(url) { const p = parse(url); return p ? p.key : null; },
    /** Tell the API an upload finished so the worker can process it. Never throws. */
    async complete(base, objectKey, accessToken) {
      try {
        if (!base || !objectKey) return null;
        const r = await fetch(`${String(base).replace(/\/+$/, '')}/api/media/complete`, {
          method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${accessToken || await token()}` },
          body: JSON.stringify({ object_key: objectKey })
        });
        return r.ok ? await r.json() : null;
      } catch (_) { return null; }
    },
    /** True when the signed-in user uploaded this video (originals can only be fetched by the uploader). */
    canDownloadOriginal(url) {
      const p = parse(url); if (!p) return false;
      const me = String((window.bmnSession && window.bmnSession.user && window.bmnSession.user.id) || '').toLowerCase();
      return !!me && p.key.split('/')[1].toLowerCase() === me;
    },
    /** Download the untouched original upload (separate from playback). */
    async downloadOriginal(url, name) {
      const p = parse(url); if (!p) throw new Error('This video has no original file to download.');
      const t = await token(); if (!t) throw new Error('Sign in to download the original.');
      const q = new URLSearchParams({ key: p.key }); if (name) q.set('name', name);
      const r = await fetch(`${p.base}/api/media/download-url?${q}`, { headers: { Authorization: `Bearer ${t}` } });
      const d = await r.json().catch(() => ({}));
      if (!r.ok || !d.url) throw new Error(d.error || 'Could not prepare the original download.');
      const a = document.createElement('a');
      a.href = d.url; a.rel = 'noopener'; a.download = d.filename || '';
      document.body.appendChild(a); a.click(); a.remove();
      return d.filename;
    }
  };
  window.BMNVideo = api;
})();
