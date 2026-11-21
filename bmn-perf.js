/* BMN Performance Governor (Batch 3).
   Purpose: keep BMN smooth on devices that cannot sustain the full Liquid Glass look, WITHOUT permanently removing the visual identity.
   - Level 0 = full BMN look (default on capable devices).
   - Level 1 = decorative per-frame effects stop (animated canvas background, video refraction of the dock, lens canvas).
   - Level 2 = additionally, backdrop blur is replaced by a solid translucent fill ("saver").
   How the level is chosen: Mode "auto" (default) watches real frame times on THIS device and steps down only when the page stays below ~35 fps;
   the step-down is remembered for 24 h so the next launch does not stutter first. Mode "saver" forces level 2, mode "full" forces level 0.
   Switch mode with ?perf=saver | ?perf=full | ?perf=auto in the address, or BMN_PERF.setMode('saver') in the console. No data leaves the device.
   This file only reads timing; it does not touch accounts, posts, media or the network. Reversible: delete the <script> tag. */
(function () {
  'use strict';
  if (window.BMN_PERF) return;
  var root = document.documentElement, LV_KEY = 'bmn-perf-level', MODE_KEY = 'bmn-perf-mode', TTL = 24 * 3600 * 1000;
  var ls = { g: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, s: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }, d: function (k) { try { localStorage.removeItem(k); } catch (e) {} } };
  var ua = navigator.userAgent || '', android = /Android/i.test(ua);
  var lowEnd = android && ((navigator.deviceMemory && navigator.deviceMemory <= 3) || (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4));
  var reduced = false; try { reduced = matchMedia('(prefers-reduced-motion: reduce)').matches || matchMedia('(prefers-reduced-transparency: reduce)').matches; } catch (e) {}

  var q = /[?&]perf=(auto|full|saver)(&|$)/.exec(location.search); if (q) ls.s(MODE_KEY, q[1]);
  var mode = ls.g(MODE_KEY); if (mode !== 'full' && mode !== 'saver') mode = 'auto';
  var level = 0;
  if (mode === 'saver') level = 2;
  else if (mode === 'auto') {
    try { var p = JSON.parse(ls.g(LV_KEY) || 'null'); if (p && typeof p.l === 'number' && Date.now() - p.t < TTL) level = Math.min(2, Math.max(0, p.l)); } catch (e) {}
    if (!level && (lowEnd || reduced)) level = 1;
  }

  var css = document.createElement('style'); css.id = 'bmn-perf-css';
  css.textContent =
    'html.bmn-fx-1 #bmn-liquid-canvas,html.bmn-fx-1 canvas.bmn-rf,html.bmn-fx-1 canvas.bmn-lens-cv{display:none!important}' +
    'html.bmn-fx-2 body *:not(video):not(canvas):not(img),html.bmn-fx-2 body{-webkit-backdrop-filter:none!important;backdrop-filter:none!important}' +
    'html.bmn-fx-2 #lgtt .lgtt-glass,html.bmn-fx-2 #lgtt .lgtt-glass-strong,html.bmn-fx-2 #lgtt .lgtt-dock,html.bmn-fx-2 #lgtt .lgtt-tabs,html.bmn-fx-2 #lgtt .lgtt-sheet,html.bmn-fx-2 #lgtt .lgtt-over,html.bmn-fx-2 .app-dock,html.bmn-fx-2 #bmnPi{background-color:rgba(18,20,30,.82)!important}' +
    'html.bmn-fx-2[data-bmn-theme="light"] #lgtt .lgtt-glass,html.bmn-fx-2[data-bmn-theme="light"] #lgtt .lgtt-glass-strong,html.bmn-fx-2[data-bmn-theme="light"] #lgtt .lgtt-dock,html.bmn-fx-2[data-bmn-theme="light"] #lgtt .lgtt-tabs,html.bmn-fx-2[data-bmn-theme="light"] #lgtt .lgtt-sheet,html.bmn-fx-2[data-bmn-theme="light"] .app-dock{background-color:rgba(255,255,255,.88)!important}';
  (document.head || root).appendChild(css);

  var listeners = [], scrollUntil = 0;
  function emit() { try { window.dispatchEvent(new CustomEvent('bmn-perf-level', { detail: { level: level, mode: mode } })); } catch (e) {} }
  function pauseBackground() { var n = 0; (function t() { if (window.BMNBackground && BMNBackground.pause) { try { level >= 1 ? BMNBackground.pause() : BMNBackground.resume(); } catch (e) {} } else if (n++ < 40) setTimeout(t, 250); })(); }
  function apply() { root.classList.toggle('bmn-fx-1', level >= 1); root.classList.toggle('bmn-fx-2', level >= 2); root.setAttribute('data-bmn-perf', String(level)); pauseBackground(); emit(); }
  function setLevel(l, why) { l = Math.max(0, Math.min(2, l)); if (l === level) return; level = l; if (mode === 'auto') ls.s(LV_KEY, JSON.stringify({ l: l, t: Date.now(), why: why || '' })); apply(); }
  apply();

  // scrolling flag: any scroller (capture) -> heavy per-frame effects skip while the finger is moving the feed
  window.addEventListener('scroll', function () { scrollUntil = Date.now() + 180; }, { capture: true, passive: true });

  // frame monitor (auto mode only). Duty-cycled so the monitor itself costs almost nothing: one 3 s window of frame times, then it sleeps.
  // Two bad windows in a row (p75 frame > 28 ms, i.e. under ~35 fps) = one step down. Ignores hidden tabs and the first 8 s after launch.
  var samples = [], last = 0, born = Date.now(), bad = 0, settle = 0, windowsRun = 0, sampling = false, timer = 0, stats = { windows: 0, lastP75: null, lastFps: null };
  function pct(a, p) { var b = a.slice().sort(function (x, y) { return x - y; }); return b[Math.min(b.length - 1, Math.floor(b.length * p))]; }
  function frame(t) {
    if (!sampling) return;
    if (mode !== 'auto' || level >= 2) { sampling = false; return; }
    requestAnimationFrame(frame);
    if (document.hidden) { last = 0; return; }
    if (last) { var d = t - last; if (d < 500) samples.push(d); }
    last = t;
    if (samples.length >= 90) {
      sampling = false; var p75 = pct(samples, .75); samples = []; last = 0; stats.windows++; stats.lastP75 = +p75.toFixed(1); stats.lastFps = +(1000 / p75).toFixed(1);
      if (Date.now() - born >= 8000) {
        if (settle > 0) settle--;
        else if (p75 > 28) { if (++bad >= 2) { bad = 0; settle = 1; setLevel(level + 1, 'p75=' + p75.toFixed(0) + 'ms'); } } else bad = 0;
      }
      schedule();
    }
  }
  frame.__perf = true;
  function begin() { if (mode !== 'auto' || level >= 2 || sampling) return; sampling = true; last = 0; samples = []; requestAnimationFrame(frame); }
  function schedule() { clearTimeout(timer); if (mode !== 'auto' || level >= 2) return; windowsRun++; timer = setTimeout(begin, windowsRun < 10 ? 6000 : 45000); }
  document.addEventListener('visibilitychange', function () { last = 0; samples = []; });
  timer = setTimeout(begin, 2000);

  window.BMN_PERF = {
    level: function () { return level; }, mode: function () { return mode; },
    skipHeavy: function () { return level >= 1; },          // decorative per-frame canvas work
    scrolling: function () { return Date.now() < scrollUntil; },
    setMode: function (m) { if (m !== 'auto' && m !== 'full' && m !== 'saver') return false; mode = m; ls.s(MODE_KEY, m); ls.d(LV_KEY); level = m === 'saver' ? 2 : 0; if (m === 'auto' && (lowEnd || reduced)) level = 1; apply(); samples = []; bad = 0; born = Date.now(); windowsRun = 0; schedule(); return true; },
    stats: function () { return { level: level, mode: mode, lowEnd: !!lowEnd, reducedPrefs: reduced, windows: stats.windows, lastP75: stats.lastP75, lastFps: stats.lastFps }; }
  };
})();
