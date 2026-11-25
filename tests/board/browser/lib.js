const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const BASE = process.env.BASE || 'http://localhost:8124';
const API = 'http://localhost:8130';
const mock = fs.readFileSync(path.join(__dirname, 'mockclient.js'), 'utf8');
const U = { A: 'aaaaaaaa-0000-4000-8000-000000000001', B: 'bbbbbbbb-0000-4000-8000-000000000002', C: 'cccccccc-0000-4000-8000-000000000003', D: 'dddddddd-0000-4000-8000-000000000004' };
const api = async (p, body) => (await fetch(API + p, { method: 'POST', body: JSON.stringify(body || {}) })).json();
let browser;
async function launch() { browser = browser || await chromium.launch(); return browser; }
async function newUser(uid, opts = {}) {
  const b = await launch();
  const dev = opts.device === 'desktop' ? { viewport: { width: 1280, height: 800 } } : opts.device === 'android' ? devices['Pixel 7'] : devices['iPhone 14'];
  const ctx = await b.newContext({ ...dev, colorScheme: opts.scheme || 'dark', permissions: [] });
  await ctx.addInitScript('window.__MOCK_UID=' + JSON.stringify(uid || null) + ';' + (opts.theme ? 'try{localStorage.setItem("bmn-theme-mode",' + JSON.stringify(opts.theme) + ')}catch(e){}' : ''));
  await ctx.addInitScript('try{["aaaaaaaa-0000-4000-8000-000000000001","bbbbbbbb-0000-4000-8000-000000000002","cccccccc-0000-4000-8000-000000000003","dddddddd-0000-4000-8000-000000000004"].forEach(function(i){localStorage.setItem("bmn-onboarded-"+i,"1")});localStorage.setItem("bmn-install-dismissed",String(Date.now()+99999999999))}catch(e){}');
  await ctx.addInitScript(mock);
  const p = await ctx.newPage(); const errs = []; const cons = [];
  p.on('pageerror', e => errs.push(e.message + ' @ ' + String(e.stack).split('\n').slice(1, 3).join(' | '))); p.on('console', m => { if (m.type() === 'error') cons.push(m.text()); });
  await p.route(/^https?:\/\/(?!localhost|127\.0\.0\.1)/, r => r.abort());
  await p.goto(BASE + '/index.html', { waitUntil: 'load' });
  await p.waitForFunction((need) => (!need || window.BMNMessaging) && document.querySelector('#lgttDock'), !process.env.BASE, { timeout: 30000 });
  await p.waitForTimeout(opts.settle || 2500);
  return { ctx, p, errs, cons, uid };
}
const openInbox = async (u) => { await u.p.evaluate(() => document.querySelector('#lgttDock [data-dock="inbox"]').click()); await u.p.waitForSelector('#bmnMsg.open', { timeout: 5000 }); await u.p.waitForTimeout(500); };
async function tap(p, sel) {
  try { await p.click(sel, { timeout: 4000 }); }
  catch (e) { const info = await p.evaluate((sel) => { const r = document.querySelector(sel); if (!r) return 'no element'; const b = r.getBoundingClientRect(); const e = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2); const path = []; let n = e; while (n && path.length < 5) { path.push(n.tagName + '#' + n.id + '.' + String(n.className).slice(0, 50) + '[aria-hidden=' + n.getAttribute('aria-hidden') + ']'); n = n.parentElement; } return path.join(' < '); }, sel); console.log('TAP BLOCKED', sel, '->', info, '| host:', await p.evaluate(()=>{const h=document.getElementById('bmnSheetHost');return h&&h.innerText.slice(0,120)})); throw e; }
}
let pass = 0, fail = 0; const results = [];
function check(name, ok, extra) { (ok ? pass++ : fail++); results.push({ name, ok: !!ok, extra }); console.log((ok ? 'PASS ' : 'FAIL ') + name + (extra !== undefined ? '  [' + extra + ']' : '')); }
const sleep = ms => new Promise(r => setTimeout(r, ms));
module.exports = { tap, launch, newUser, openInbox, api, U, check, sleep, results, BASE, summary: () => ({ pass, fail }), close: async () => browser && browser.close() };
