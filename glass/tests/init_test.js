// Init / device-gate checks. usage: node init_test.js   (run from glass/tests, needs playwright)
const { chromium, devices } = require('playwright'); const path = require('path'); const fs = require('fs');
const site = path.resolve(__dirname, '../../index.html');
let pass = 0, fail = 0; const ok = (n, c, x = '') => { (c ? pass++ : fail++); console.log((c ? 'PASS ' : 'FAIL ') + n + (x ? '  — ' + x : '')); };
(async () => {
  const b = await chromium.launch();
  // ---- Android profile: the engine must not even be requested ----
  { const ctx = await b.newContext({ ...devices['Pixel 7'] }); const p = await ctx.newPage(); const reqs = [], errs = [];
    p.on('request', r => reqs.push(r.url())); p.on('pageerror', e => errs.push(e.message));
    await p.route(/^https?:\/\/(?!localhost)/, r => r.abort());
    await p.goto('file://' + site, { waitUntil: 'load' }); await p.waitForTimeout(3000);
    const s = await p.evaluate(() => ({ tier: window.__bmnGlassTier, glass: !!window.BMNGlass, hosts: document.querySelectorAll('[data-bmn-glass-host]').length, lg: document.querySelectorAll('.lg-glass, [data-liquid-glass-defs]').length, cls: document.documentElement.classList.contains('bmn-glass-lite'), on: document.documentElement.classList.contains('bmn-glass-on') }));
    ok('android: tier is lite, lite class set', s.tier === 'lite' && s.cls && !s.on, JSON.stringify(s));
    ok('android: engine bundle never requested', !reqs.some(u => /bmn-glass\.js/.test(u)) && !reqs.some(u => /bmn-glass\.css/.test(u)), reqs.filter(u => /bmn-glass/.test(u)).map(u => path.basename(u)).join(','));
    ok('android: lite stylesheet loaded', reqs.some(u => /bmn-glass-lite\.css/.test(u)));
    ok('android: no BMNGlass object, no React roots, no engine nodes', !s.glass && s.hosts === 0 && s.lg === 0);
    ok('android: no page errors', errs.length === 0, errs.join(' | '));
    const forced = await ctx.newPage(); await forced.route(/^https?:\/\/(?!localhost)/, r => r.abort());
    await forced.goto('file://' + site + '?glass=full', { waitUntil: 'load' }); await forced.waitForTimeout(2500);
    ok('android: ?glass=full forces the engine (test switch)', await forced.evaluate(() => !!window.BMNGlass && document.documentElement.classList.contains('bmn-glass-on')));
    await ctx.close(); }
  // ---- iOS profile ----
  { const ctx = await b.newContext({ ...devices['iPhone 14'] }); const p = await ctx.newPage(); const errs = [];
    p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
    await p.route(/^https?:\/\/(?!localhost)/, r => r.abort());
    await p.goto('file://' + site, { waitUntil: 'load' }); await p.waitForTimeout(3500);
    const a = await p.evaluate(() => ({ tier: window.__bmnGlassTier, cls: [...document.documentElement.classList].filter(c => /glass/.test(c)), hosts: document.querySelectorAll('[data-bmn-glass-host]').length, scripts: document.querySelectorAll('script[src*="bmn-glass"]').length, inst: window.BMNGlass }));
    ok('ios: tier ios, engine on', a.tier === 'ios' && a.cls.includes('bmn-glass-ios') && a.cls.includes('bmn-glass-on'), a.cls.join(' '));
    // second copy of the bundle (cached + fresh, SW swap, double tag) must not start a second layer
    await p.evaluate(() => new Promise(res => { const s = document.createElement('script'); s.src = 'bmn-glass/bmn-glass.js?dup=1'; s.onload = res; s.onerror = res; document.body.appendChild(s); })); await p.waitForTimeout(1500);
    const d = await p.evaluate(() => ({ hosts: document.querySelectorAll('[data-bmn-glass-host]').length, same: true }));
    ok('ios: loading the bundle twice does not mount a second layer', d.hosts === a.hosts, a.hosts + ' -> ' + d.hosts);
    // page hidden pauses glass animation
    await p.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); document.dispatchEvent(new Event('visibilitychange')); });
    ok('ios: hidden page sets bmn-page-hidden', await p.evaluate(() => document.documentElement.classList.contains('bmn-page-hidden')));
    await p.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange')); });
    ok('ios: visible page clears bmn-page-hidden', await p.evaluate(() => !document.documentElement.classList.contains('bmn-page-hidden')));
    // listeners: kill switch tears everything down
    await p.evaluate(() => window.BMNGlass.disable()); await p.waitForTimeout(600);
    const k = await p.evaluate(() => ({ hosts: document.querySelectorAll('[data-bmn-glass-host]').length, ctl: document.querySelectorAll('.bmn-ctl').length, off: document.documentElement.classList.contains('bmn-glass-off'), on: document.documentElement.classList.contains('bmn-glass-on') }));
    ok('ios: BMNGlass.disable() unmounts every root and decoration', k.hosts === 0 && k.ctl === 0 && k.off && !k.on, JSON.stringify(k));
    ok('ios: no page or console errors', errs.length === 0, errs.slice(0, 3).join(' | '));
    await ctx.close(); }
  // ---- desktop profile ----
  { const ctx = await b.newContext({ viewport: { width: 1280, height: 800 } }); const p = await ctx.newPage(); const errs = [];
    p.on('pageerror', e => errs.push(e.message));
    await p.route(/^https?:\/\/(?!localhost)/, r => r.abort());
    await p.goto('file://' + site, { waitUntil: 'load' }); await p.waitForTimeout(3000);
    const c = await p.evaluate(() => ({ tier: window.__bmnGlassTier, cls: document.documentElement.classList.contains('bmn-glass-desktop') && document.documentElement.classList.contains('bmn-glass-on') }));
    ok('desktop: tier desktop, engine on', c.tier === 'desktop' && c.cls, JSON.stringify(c)); ok('desktop: no page errors', errs.length === 0, errs.join(' | ')); await ctx.close(); }
  // ---- loader ----
  { const ctx = await b.newContext({ ...devices['iPhone 14'], deviceScaleFactor: 2 }); const p = await ctx.newPage();
    await p.route(/^https?:\/\/(?!localhost)/, r => r.abort());
    await p.goto('file://' + site, { waitUntil: 'commit' }); await p.waitForSelector('#bmnSplash', { state: 'attached' }); await p.waitForTimeout(250);
    const L = await p.evaluate(() => { const s = document.getElementById('bmnSplash'); if (!s) return null; const l = s.querySelector('.sp-logo'); const cs = getComputedStyle(l); return { splashes: document.querySelectorAll('#bmnSplash').length, anim: cs.animationName, bf: cs.backdropFilter, starting: document.documentElement.classList.contains('bmn-starting') }; });
    ok('loader: the single existing #bmnSplash is used and animates with transform/opacity only (no backdrop-filter)', L && L.splashes === 1 && /bmnGlassBreathe/.test(L.anim) && (L.bf === 'none' || !L.bf), JSON.stringify(L));
    if (process.env.SHOT) await p.screenshot({ path: process.env.SHOT });
    await ctx.close();
    const rm = await b.newContext({ ...devices['iPhone 14'], reducedMotion: 'reduce' }); const q = await rm.newPage(); await q.route(/^https?:\/\/(?!localhost)/, r => r.abort());
    await q.goto('file://' + site, { waitUntil: 'commit' }); await q.waitForSelector('#bmnSplash', { state: 'attached' }); await q.waitForTimeout(150);
    const R = await q.evaluate(() => { const l = document.querySelector('#bmnSplash .sp-logo'); const cs = getComputedStyle(l); return { anim: cs.animationName, sheen: getComputedStyle(l, '::before').display }; });
    ok('loader: reduced motion removes all loader animation', R.anim === 'none' && R.sheen === 'none', JSON.stringify(R)); await rm.close(); }
  await b.close(); console.log(`== ${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})();
