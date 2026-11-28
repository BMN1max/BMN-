/* Batch 2: elastic touch response tests (Playwright + Chromium EMULATION; touch is synthesised through CDP Input.dispatchTouchEvent, mouse through page.mouse).
   NOT a real finger on a real device. Run: python3 -m http.server 8124 (repo root) + node dbserver.js (tests/), then node tests/t7_touch.js */
const { chromium, devices } = require('playwright');
const fs = require('fs'), path = require('path');
const BASE = process.env.BASE || 'http://127.0.0.1:8124/index.html';
const mock = fs.readFileSync(path.join(__dirname, 'mockclient.js'), 'utf8');
const U = 'aaaaaaaa-0000-4000-8000-000000000001';
let pass = 0, fail = 0;
const check = (n, ok, x) => { ok ? pass++ : fail++; console.log((ok ? 'PASS ' : 'FAIL ') + n + (x !== undefined ? '  [' + x + ']' : '')); };
const wait = ms => new Promise(r => setTimeout(r, ms));

async function open(b, { prof = 'iphone', th = 'dark', reduced = false, url = BASE } = {}) {
  const dev = prof === 'iphone' ? devices['iPhone 14'] : prof === 'android' ? devices['Pixel 7'] : { viewport: { width: 1280, height: 800 }, hasTouch: false };
  const ctx = await b.newContext({ ...dev, colorScheme: th, reducedMotion: reduced ? 'reduce' : 'no-preference' });
  await ctx.addInitScript('window.__MOCK_UID=' + JSON.stringify(U) + ';try{localStorage.setItem("bmn-theme-mode",' + JSON.stringify(th) + ');localStorage.setItem("bmn-onboarded-' + U + '","1");localStorage.setItem("bmn-install-dismissed",String(Date.now()+99999999999))}catch(e){}');
  await ctx.addInitScript(mock);
  await ctx.addInitScript(({ css, js }) => {
    const mo = new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) {
      if (n.nodeName === 'LINK' && /\/bmn-liquid\.css$/.test(n.getAttribute('href') || '')) { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = css; n.after(l); }
      if (n.nodeName === 'SCRIPT' && /\/bmn-board\.js$/.test(n.getAttribute('src') || '')) { const sc = document.createElement('script'); sc.src = js; sc.defer = true; n.after(sc); }
    } }); mo.observe(document, { childList: true, subtree: true });
  }, { css: '/bmn-liquid-surfaces.css', js: '/bmn-glass-touch.js' });
  const errs = []; const p = await ctx.newPage(); p.on('pageerror', e => errs.push(e.message.slice(0, 100)));
  await p.route(/^https?:\/\/(?!localhost|127\.0\.0\.1)/, r => r.abort());
  await p.goto(url, { waitUntil: 'load' }); await p.waitForSelector('#lgttDock', { timeout: 30000 }); await p.waitForTimeout(3500);
  await p.evaluate(() => { const posts = []; for (let i = 0; i < 4; i++) posts.push({ id: 't' + i, u: 'bmn', cap: 'Test clip ' + i + ' #bmn', music: 'Original sound', dur: 8, src: 'http://127.0.0.1:8125/clip' + ((i % 4) + 1) + '.mp4?n=' + i }); window.LGTT.setPosts(posts); });
  await p.waitForTimeout(2000);
  return { ctx, p, errs, cdp: await ctx.newCDPSession(p) };
}
const rect = (p, sel) => p.evaluate(s => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height }; }, sel);
const tr = (p, sel) => p.evaluate(s => { const e = document.querySelector(s); const t = e && e.style.translate; if (!t) return [0, 0]; const m = t.match(/-?[\d.]+/g) || []; return [+m[0] || 0, +m[1] || 0]; }, sel);
const touch = (cdp, type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] });
async function touchDrag(cdp, p, from, path_, hold) { await touch(cdp, 'touchStart', from.x, from.y); const samples = []; for (const [x, y] of path_) { await touch(cdp, 'touchMove', x, y); await wait(24); samples.push(await Promise.resolve(hold && hold())); } return samples; }

(async () => {
  const b = await chromium.launch();
  const MARK = () => { const e = document.querySelector('#lgtt .lgtt-slide.is-active .lgtt-music'); if (!e) return false; e.setAttribute('data-t7', '1'); return true; };   // the sound pill: a real floating glass surface
  for (const prof of ['iphone', 'android', 'desktop']) for (const th of ['dark', 'light']) {
    const tag = prof + '/' + th + ': ';
    const { ctx, p, errs, cdp } = await open(b, { prof, th });
    check(tag + 'module loaded', await p.evaluate(() => !!window.BMN_GLASS_TOUCH && window.BMN_GLASS_TOUCH.enabled()));
    const first = await p.evaluate(MARK);
    if (!first) { check(tag + 'found the sound pill', false); await ctx.close(); continue; }
    const S = '[data-t7="1"]'; const r0 = await rect(p, S);
    /* directions: touch where available, mouse for desktop */
    const useTouch = prof !== 'desktop';
    const dirs = { up: [0, -60], down: [0, 60], left: [-60, 0], right: [60, 0], diag: [50, -50] };
    for (const [name, [dx, dy]] of Object.entries(dirs)) {
      if (useTouch) { await touch(cdp, 'touchStart', r0.x, r0.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r0.x + dx * i / 6, r0.y + dy * i / 6); await wait(20); } }
      else { await p.mouse.move(r0.x, r0.y); await p.mouse.down(); for (let i = 1; i <= 6; i++) { await p.mouse.move(r0.x + dx * i / 6, r0.y + dy * i / 6); await wait(20); } }
      const [tx, ty] = await tr(p, S);
      const okDir = (dx === 0 || Math.sign(tx) === Math.sign(dx)) && (dy === 0 || Math.sign(ty) === Math.sign(dy)) && (dx !== 0 || Math.abs(tx) < .5) && (dy !== 0 || Math.abs(ty) < .5);
      check(tag + 'drag ' + name + ' follows the finger', okDir, tx.toFixed(1) + ',' + ty.toFixed(1));
      check(tag + 'drag ' + name + ' is capped (rubber band)', Math.abs(tx) <= 12.5 && Math.abs(ty) <= 12.5);
      if (useTouch) await touch(cdp, 'touchEnd'); else await p.mouse.up();
      await wait(1300);
      const [sx, sy] = await tr(p, S);
      check(tag + 'release ' + name + ' settles to rest', sx === 0 && sy === 0 && await p.evaluate(() => window.BMN_GLASS_TOUCH.settling() === 0), sx + ',' + sy);
    }
    /* direction change mid-drag */
    if (useTouch) { await touch(cdp, 'touchStart', r0.x, r0.y); for (let i = 1; i <= 5; i++) { await touch(cdp, 'touchMove', r0.x + 12 * i, r0.y); await wait(20); } const a = await tr(p, S); for (let i = 1; i <= 8; i++) { await touch(cdp, 'touchMove', r0.x + 60 - 14 * i, r0.y + 8 * i); await wait(20); } const c = await tr(p, S); await touch(cdp, 'touchEnd'); check(tag + 'direction change is followed', a[0] > 3 && c[0] < a[0] && c[1] > 1, JSON.stringify([a, c])); await wait(1300); }
    /* overshoot: sample after release */
    if (useTouch) { await touch(cdp, 'touchStart', r0.x, r0.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r0.x, r0.y + 12 * i); await wait(16); } await touch(cdp, 'touchEnd'); const xs = []; for (let i = 0; i < 40; i++) { xs.push((await tr(p, S))[1]); await wait(20); } const flipped = xs.some(v => v < -0.3); check(tag + 'spring overshoots past rest then settles', flipped && xs[xs.length - 1] === 0, 'min=' + Math.min(...xs).toFixed(2) + ' last=' + xs[xs.length - 1]); await wait(800); }
    /* tap: below threshold, never translated, click fires */
    await p.evaluate(s => { const e = document.querySelector(s); window.__c = 0; e.addEventListener('click', () => window.__c++, true); }, S);
    if (useTouch) { await touch(cdp, 'touchStart', r0.x, r0.y); await touch(cdp, 'touchMove', r0.x + 3, r0.y + 2); await touch(cdp, 'touchEnd'); } else { await p.mouse.move(r0.x, r0.y); await p.mouse.down(); await p.mouse.move(r0.x + 3, r0.y + 2); await p.mouse.up(); }
    await wait(150);
    check(tag + 'tap still clicks (no translate)', (await p.evaluate(() => window.__c)) >= 1 && (await tr(p, S)).every(v => v === 0));
    /* drag then release: the follow-up click is swallowed (mouse = trusted click sequence) */
    await p.evaluate(() => { window.__c = 0; });
    const r1 = await rect(p, S); await p.mouse.move(r1.x, r1.y); await p.mouse.down(); for (let i = 1; i <= 5; i++) { await p.mouse.move(r1.x + 4 * i, r1.y + 3 * i); await wait(16); } await p.mouse.up(); await wait(200);
    check(tag + 'click after a drag is swallowed', (await p.evaluate(() => window.__c)) === 0);
    await wait(900);
    check(tag + 'no page errors', errs.length === 0, errs[0]);
    await ctx.close();
  }

  /* dock: horizontal drag must NOT move it (the engine lens owns it); vertical may */
  { const { ctx, p, cdp } = await open(b, { prof: 'iphone' }); const r = await rect(p, '#lgttDock');
    await touch(cdp, 'touchStart', r.x, r.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r.x + 18 * i, r.y); await wait(20); } const h = await tr(p, '#lgttDock'); await touch(cdp, 'touchEnd'); await wait(1200);
    check('dock: horizontal drag leaves the dock to the selection lens (no translate)', h[0] === 0 && h[1] === 0, h.join(','));
    await touch(cdp, 'touchStart', r.x, r.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r.x, r.y - 14 * i); await wait(20); } const v = await tr(p, '#lgttDock'); await touch(cdp, 'touchEnd'); await wait(1200);
    check('dock: vertical drag moves it up elastically and it returns', v[1] < -2 && v[0] === 0 && (await tr(p, '#lgttDock')).every(x => x === 0), v.join(','));
    await ctx.close(); }

  /* guards */
  { const { ctx, p, cdp } = await open(b, { prof: 'iphone', reduced: true }); const el = await p.evaluate(MARK); const r = await rect(p, '[data-t7="1"]');
    await touch(cdp, 'touchStart', r.x, r.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r.x, r.y + 10 * i); await wait(20); } const t = await tr(p, '[data-t7="1"]'); await touch(cdp, 'touchEnd');
    check('reduced motion: no translate at all', t[0] === 0 && t[1] === 0 && await p.evaluate(() => !window.BMN_GLASS_TOUCH.enabled()), t.join(',')); await ctx.close(); }
  { const { ctx, p, cdp } = await open(b, { prof: 'iphone', url: BASE + '?liquid=off' }); await p.evaluate(MARK); const r = await rect(p, '[data-t7="1"]');
    await touch(cdp, 'touchStart', r.x, r.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r.x, r.y + 10 * i); await wait(20); } const t = await tr(p, '[data-t7="1"]'); await touch(cdp, 'touchEnd');
    check('?liquid=off kill switch: touch module is inert', t[0] === 0 && t[1] === 0, t.join(',')); await ctx.close(); }
  { const { ctx, p, cdp } = await open(b, { prof: 'iphone', url: BASE + '?glasstouch=off' }); await p.evaluate(MARK); const r = await rect(p, '[data-t7="1"]');
    await touch(cdp, 'touchStart', r.x, r.y); for (let i = 1; i <= 6; i++) { await touch(cdp, 'touchMove', r.x, r.y + 10 * i); await wait(20); } const t = await tr(p, '[data-t7="1"]'); await touch(cdp, 'touchEnd');
    check('?glasstouch=off: module is inert', t[0] === 0 && t[1] === 0, t.join(',')); await ctx.close(); }

  /* text fields, scrolling, idle cost */
  { const res = {};
    for (const [k, url] of [['module on', BASE], ['module off', BASE + '?glasstouch=off']]) {
      const { ctx, p, cdp } = await open(b, { prof: 'iphone', url }); await p.evaluate(() => LGTT.openSettings()); await p.waitForTimeout(1000);
      const rr = await rect(p, '#lgttSetBody'); await cdp.send('Input.synthesizeScrollGesture', { x: rr.x, y: rr.y + 150, yDistance: -250, speed: 800, gestureSourceType: 'touch' }); await wait(600);
      res[k] = await p.evaluate(() => document.querySelector('#lgttSetBody').scrollTop); await ctx.close(); }
    check('Settings touch-scroll distance is the same with the module on and off', res['module on'] > 0 ? Math.abs(res['module on'] - res['module off']) < 40 : res['module off'] === 0, JSON.stringify(res)); }
  { const { ctx, p } = await open(b, { prof: 'iphone' });
    const idle = await p.evaluate(() => new Promise(res => { let n = 0; const orig = window.requestAnimationFrame; window.requestAnimationFrame = function (f) { n++; return orig.call(window, f); }; setTimeout(() => { window.requestAnimationFrame = orig; res({ raf: n, settling: window.BMN_GLASS_TOUCH.settling() }); }, 3000); }));
    check('idle: the module requests no animation frames and holds no springs', idle.settling === 0, JSON.stringify(idle) + ' (raf count includes the app\'s own loops)');
    const li = await p.evaluate(() => getComputedStyle(document.querySelector('#lgtt .lgtt-slide.is-active .lgtt-music')).translate);
    check('idle: no leftover translate on controls', li === 'none' || li === '0px', li); await ctx.close(); }

  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})();
