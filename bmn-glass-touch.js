/* BMN Glass Touch (bmn-glass-touch.js) - elastic touch response for floating glass surfaces.
   WHAT IT DOES: when a finger / pen / mouse presses a floating glass surface (feed tabs, dock, search and compose pills, round
   icon buttons, sound pill, Inbox composer, Board nav/top controls/composer button) and drags, the surface follows the
   finger with rubber-band resistance in ANY direction (up, down, left, right, diagonal, direction changes mid-drag), and on
   release it settles back to its layout position with a small under-damped spring (one slight overshoot).
   WHAT IT DOES NOT DO: no rendering engine, no canvas/WebGL, no new refraction (that stays in the engine bundle), no backend, no
   network, no Supabase/auth. It never calls preventDefault, never captures the pointer and never sets touch-action, so scrolling,
   taps, the feed swipe, the dock's own lens drag, sliders, switches and text selection keep working exactly as before.
   HOW: only the standalone CSS `translate` property is written on the element (the engine uses `scale`, the app uses `transform`,
   so nothing clashes) and it is removed when the spring has settled. No timers and no rAF loop while idle: the loop exists only
   while something is settling. Four passive document listeners in total (no per-element listeners = no leaks on re-render).
   GUARDS: off when the user prefers reduced motion, when the performance governor is in saver mode (html.bmn-fx-2), when the
   html.bmn-lq class is absent (kill switch ?liquid=off), or with ?glasstouch=off (remembered; ?glasstouch=on re-enables).
   A drag longer than 8 px swallows the click that would follow it, so releasing after a drag never triggers the button.
   Reversible: delete the <script> tag. */
(function () {
  'use strict';
  if (window.BMN_GLASS_TOUCH) return;
  var root = document.documentElement, KEY = 'bmn-glass-touch';
  var ls = { g: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, s: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} } };
  var q = /[?&]glasstouch=(on|off)(&|$)/.exec(location.search); if (q) ls.s(KEY, q[1]);
  var enabled = ls.g(KEY) !== 'off';

  /* Targets. axes: which axes the surface may move on ('xy' | 'y' | 'x'). The dock keeps horizontal drags for its own selection
     lens, so it only answers on the vertical axis. maxPx caps the travel. Surfaces with their own drag logic (sheets, sliders,
     switches, the progress bar, text fields) are deliberately absent. */
  var TARGETS = [
    { sel: '#lgtt .lgtt-tabs', axes: 'y', max: 12 },
    { sel: '#lgttDock', axes: 'y', max: 10 },
    { sel: '#lgtt .lgtt-btn.lgtt-pill', axes: 'xy', max: 12 },
    { sel: '#lgtt .lgtt-music', axes: 'xy', max: 12 },
    { sel: '#lgtt .lgtt-compose-pill, #lgtt .lgtt-search', axes: 'xy', max: 10 },
    { sel: '#bmnRealInbox .bmn-ri-composer-shell, #bmnRealInbox .bmn-ri-search', axes: 'xy', max: 10 },
    { sel: '#bmnBoard .bd-nav', axes: 'xy', max: 12 },
    { sel: '#bmnBoard .bd-top .bd-ib, #bmnBoard .bd-fab', axes: 'xy', max: 12 }
  ];
  var JOINED = TARGETS.map(function (t) { return t.sel; }).join(',');
  /* never start from these (they own their own pointer behaviour) */
  /* Surfaces the engine already animates with its own press physics (round icon buttons, Quick Glass: `usePress` writes inline
     scale + translate on them) are never touched here, so two writers never fight over one property. Any element that already
     carries an inline `translate` we did not write is skipped for the same reason. */
  var ENGINE_OWNED = '[data-bmn-material="button"],[data-bmn-material="quick"],.bmn-quick-actions button';
  var SKIP = 'input,textarea,select,[contenteditable="true"],[data-nodrag],.lgtt-prog,.lgtt-switch,.lg-switch,.lg-slider,input[type=range],[role=slider],[role=switch]';

  var drag = null;                  // the one active pointer drag
  var springs = [];                 // elements settling back
  var raf = 0, lastT = 0, swallowUntil = 0, swallowEl = null;
  var K = 230, C = 13.5;            // spring: ~0.44 damping ratio = one gentle overshoot, settles in ~0.7 s

  function active() {
    if (!enabled || !root.classList.contains('bmn-lq') || root.classList.contains('bmn-fx-2')) return false;
    try { if (matchMedia('(prefers-reduced-motion: reduce)').matches) return false; } catch (e) {}
    return true;
  }
  function cfgFor(el) { for (var i = 0; i < TARGETS.length; i++) { try { if (el.matches(TARGETS[i].sel)) return TARGETS[i]; } catch (e) {} } return null; }
  /* rubber band: follows the finger at first, saturates at `max` */
  function rubber(d, max) { var a = Math.abs(d); return (d < 0 ? -1 : 1) * max * (1 - Math.exp(-a / (max * 1.7))); }
  function write(s) { s.el.style.translate = (s.x.toFixed(2)) + 'px ' + (s.y.toFixed(2)) + 'px'; }
  function clear(s) { try { s.el.style.removeProperty('translate'); } catch (e) {} }

  function onDown(e) {
    if (drag || !active()) return;
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    var t = e.target; if (!(t instanceof Element)) return;
    if (t.closest(SKIP)) return;
    var el = t.closest(JOINED); if (!el || el.matches(ENGINE_OWNED) || el.closest(ENGINE_OWNED)) return;
    var cfg = cfgFor(el); if (!cfg) return;
    /* a surface still settling from a previous touch is taken over by the new drag (it may re-seat by a few px at the first move) */
    var prev = null; for (var i = 0; i < springs.length; i++) if (springs[i].el === el) { prev = springs[i]; springs.splice(i, 1); break; }
    if (!prev && el.style.translate) return;                                   // someone else owns this element's translate right now
    drag = { id: e.pointerId, el: el, cfg: cfg, sx: e.clientX, sy: e.clientY, x: prev ? prev.x : 0, y: prev ? prev.y : 0, vx: 0, vy: 0, lx: e.clientX, ly: e.clientY, lt: e.timeStamp, moved: false, ox: prev ? prev.x : 0, oy: prev ? prev.y : 0 };
  }
  function onMove(e) {
    var d = drag; if (!d || e.pointerId !== d.id) return;
    if (e.pointerType === 'mouse' && !(e.buttons & 1)) { return onUp(e); }
    var dx = e.clientX - d.sx, dy = e.clientY - d.sy;
    var ax = d.cfg.axes.indexOf('x') >= 0, ay = d.cfg.axes.indexOf('y') >= 0;
    /* 8 px along an AXIS THIS SURFACE ANSWERS = drag; below that it is still a tap. A horizontal drag on the dock/tabs is the
       engine's own selection-lens drag, so it never counts as a drag here and its click is never swallowed. */
    if (!d.moved) { if ((ax ? dx * dx : 0) + (ay ? dy * dy : 0) < 64) return; d.moved = true; }
    var nx = ax ? rubber(dx, d.cfg.max) : 0, ny = ay ? rubber(dy, d.cfg.max) : 0;
    var dt = Math.max(1, e.timeStamp - d.lt);
    d.vx = (nx - d.x) / dt * 1000; d.vy = (ny - d.y) / dt * 1000; d.lt = e.timeStamp;
    d.x = nx; d.y = ny; write(d);
  }
  function onUp(e) {
    var d = drag; if (!d || (e && e.pointerId !== d.id)) return;
    drag = null;
    if (!d.moved) return;                                                          // a tap: nothing was ever written
    swallowEl = d.el; swallowUntil = performance.now() + 400;                     // the click that follows a drag must not fire the button
    d.vx = Math.max(-600, Math.min(600, d.vx)); d.vy = Math.max(-600, Math.min(600, d.vy));
    springs.push(d); if (!raf) { lastT = 0; raf = requestAnimationFrame(step); }
  }
  function step(t) {
    raf = 0;
    if (document.hidden) { for (var h = 0; h < springs.length; h++) clear(springs[h]); springs.length = 0; return; }
    var elapsed = lastT ? Math.min(0.12, (t - lastT) / 1000) : 0.016; lastT = t;      // real elapsed time (capped), so a slow frame rate settles in the same wall-clock time
    var n = Math.max(1, Math.ceil(elapsed / 0.008)), dt = elapsed / n;                  // sub-steps of <= 8 ms keep the integrator stable and smooth
    for (var i = springs.length - 1; i >= 0; i--) {
      var s = springs[i];
      if (!s.el.isConnected) { springs.splice(i, 1); continue; }
      for (var k = 0; k < n; k++) { s.vx += (-K * s.x - C * s.vx) * dt; s.vy += (-K * s.y - C * s.vy) * dt; s.x += s.vx * dt; s.y += s.vy * dt; }
      if (Math.abs(s.x) < .12 && Math.abs(s.y) < .12 && Math.abs(s.vx) < 3 && Math.abs(s.vy) < 3) { clear(s); springs.splice(i, 1); }
      else write(s);
    }
    if (springs.length) raf = requestAnimationFrame(step);
  }
  function onClick(e) {
    if (!swallowEl) return;
    if (performance.now() > swallowUntil) { swallowEl = null; return; }
    /* only the browser's own (trusted) click is swallowed; the engine's bridged .click() calls are untrusted and untouched */
    if (e.isTrusted && e.target instanceof Node && swallowEl.contains(e.target)) { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); swallowEl = null; }
  }
  function onCancel(e) { onUp(e); }

  document.addEventListener('pointerdown', onDown, { capture: true, passive: true });
  document.addEventListener('pointermove', onMove, { capture: true, passive: true });
  document.addEventListener('pointerup', onUp, { capture: true, passive: true });
  document.addEventListener('pointercancel', onCancel, { capture: true, passive: true });
  document.addEventListener('click', onClick, true);                                // not passive: it must be able to stop the click
  document.addEventListener('visibilitychange', function () { if (document.hidden) { drag = null; for (var i = 0; i < springs.length; i++) clear(springs[i]); springs.length = 0; } });

  window.BMN_GLASS_TOUCH = {
    version: 1,
    enabled: function () { return enabled && active(); },
    enable: function () { enabled = true; ls.s(KEY, 'on'); }, disable: function () { enabled = false; ls.s(KEY, 'off'); },
    settling: function () { return springs.length; }, dragging: function () { return !!(drag && drag.moved); },
    targets: function () { return TARGETS.map(function (t) { return t.sel; }); }
  };
})();
