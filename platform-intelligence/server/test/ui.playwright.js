'use strict';
// Headless-browser test of bmn-intelligence.js against a MOCKED API (no real backend). Run: NODE_PATH=<dir with playwright> node test/ui.playwright.js <path to bmn-intelligence.js>
const { chromium } = require('playwright');
const fs = require('node:fs'); const path = require('node:path');
const SRC = fs.readFileSync(path.resolve(process.argv[2] || '../../../bmn-intelligence.js'), 'utf8');
let pass = 0, fail = 0; const ok = (c, m) => { if (c) { pass++; console.log('PASS', m); } else { fail++; console.log('FAIL', m); } };
const XSS = '<img src=x onerror="window.__xss=1">';
const DATA = {
  '/overview': { jobs: {}, cases: { awaiting_review: 2, urgent: 1 }, flags: { moderation_analysis: false }, halted: false, appeals: { pending: 0 }, workers: [], accounts: { high_risk: 1 }, verification: { pending: 1 }, alerts_open: 1, enforcement_available: false },
  '/health': { workers_active: 0, dead_jobs_24h: 0, oldest_queued_seconds: 0 },
  '/cases': [{ id: '11111111-1111-1111-1111-111111111111', primary_category: 'spam_scams', subject_type: 'post', priority: 1, risk_score: 0.96, preview: XSS, subject_username: 'bad', opened_at: new Date().toISOString(), source: 'automated' }],
  '/accounts': [{ username: 'u1', risk_level: 'high', explanation: XSS, reason_codes: ['mass_follow'], assessed_at: new Date().toISOString() }],
  '/investigations': [{ id: '22222222-2222-2222-2222-222222222222', username: 'u1', severity: 'high', summary: 's' }],
  '/restrictions': [{ id: '33333333-3333-3333-3333-333333333333', username: 'u1', mode: 'shadow', restriction_type: 'limit_follows', reason_code: 'mass_follow', expires_at: new Date().toISOString() }],
  '/verification': { pending: [{ request_id: '44444444-4444-4444-4444-444444444444', username: 'v1', request_reason: XSS, evaluation: { outcome: 'needs_human_review', checks: [{ check: 'profile_complete', result: 'fail' }] } }], recent_decisions: [] },
  '/alerts': [{ id: 1, kind: 'jobs_dead', severity: 'medium', message: 'x', last_seen_at: new Date().toISOString(), occurrences: 2 }], '/events': [{ id: 5, event_type: 'mass_follow', username: 'u1', severity: 'high', occurred_at: new Date().toISOString() }],
  '/appeals': [{ id: '55555555-5555-5555-5555-555555555555', username: 'a1', status: 'pending', statement: 'please review', action: { action_type: 'warn' }, created_at: new Date().toISOString() }],
  '/audit': [{ action: 'feature_flag_changed', occurred_at: new Date().toISOString(), actor_type: 'owner', target_type: 'feature_flag', target_id: 'x', reason: 'r' }],
  '/policy': { flags: [{ key: 'moderation_analysis', enabled: false, description: 'd' }, { key: 'auto_verification', enabled: true, description: 'd' }], policies: [{ category: 'spam_scams', enabled: false, version: 1, max_auto_action: 'none' }], rule_sets: [] }
};
(async () => {
  const browser = await chromium.launch(); const calls = []; const dialogs = [];
  async function run(isOwner) {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }); const page = await ctx.newPage(); const errors = [];
    page.on('pageerror', (e) => errors.push(e.message)); page.on('dialog', async (d) => { dialogs.push(d.message()); await d.accept(d.type() === 'prompt' ? 'test note' : undefined); });
    await page.route('http://api.test/**', async (route) => {
      const req = route.request(); const u = new URL(req.url()); calls.push({ method: req.method(), path: u.pathname, auth: req.headers().authorization, dev: req.headers()['x-bmn-device'], body: req.postData() });
      if (u.pathname === '/api/pi/session') return route.fulfill({ status: 204 });
      const p = u.pathname.replace('/api/pi/owner', '');
      if (req.method() === 'POST') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, data: {} }) });
      return route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ ok: true, data: DATA[p] }) });
    });
    await page.route('http://app.test/', (r) => r.fulfill({ contentType: 'text/html', body: '<!doctype html><meta name=viewport content="width=device-width"><body><div id="lgttProfHead"><div class="lgtt-prof-actions"></div></div></body>' }));
    await page.goto('http://app.test/');
    await page.evaluate((o) => { window.BMN_API_BASE_URL = 'http://api.test'; window.bmnSession = { user: { id: o ? 'owner-1' : 'user-2' }, access_token: 'tok' };
      window.bmnSupabase = { auth: { getSession: async () => ({ data: { session: { access_token: 'tok-fresh' } } }) }, rpc: async () => ({ data: o, error: null }) }; }, isOwner);
    await page.addScriptTag({ content: SRC }); await page.waitForTimeout(1800);
    return { page, ctx, errors };
  }

  // ---- non-owner
  let { page, ctx, errors } = await run(false);
  ok(await page.locator('#bmnPiOpen').count() === 0, 'non-owner: no Intelligence button');
  ok(calls.some((c) => c.path === '/api/pi/session' && c.auth === 'Bearer tok-fresh' && /^d[0-9a-f]{36}$/.test(c.dev || '')), 'beacon sent with fresh token and random device id');
  ok(!calls.some((c) => c.path.startsWith('/api/pi/owner')), 'non-owner: no owner API call made');
  const before = calls.length; await page.waitForTimeout(3500); ok(calls.filter((c) => c.path === '/api/pi/session').length === 1, 'beacon is throttled (once per 30 min)');
  ok(errors.length === 0, 'non-owner: no page errors ' + errors.join('|')); await ctx.close();

  // ---- owner
  calls.length = 0; dialogs.length = 0; ({ page, ctx, errors } = await run(true));
  ok(await page.locator('#bmnPiOpen').count() === 1, 'owner: Intelligence button appears');
  await page.tap('#bmnPiOpen'); await page.waitForSelector('#bmnPi.open'); await page.waitForFunction(() => document.querySelector('#bmnPiBody').textContent.includes('cases waiting'), null, { timeout: 4000 }).catch(() => {});
  ok((await page.textContent('#bmnPiBody')).includes('cases waiting'), 'overview renders'); ok((await page.textContent('#bmnPiBody')).includes('shadow'), 'overview states shadow mode / OFF');
  for (const [tab, needle] of [['cases', 'spam scams'], ['accounts', 'Active temporary restrictions'], ['verification', 'Waiting for you'], ['alerts', 'System alerts'], ['appeals', 'please review'], ['audit', 'feature flag changed'], ['controls', 'Feature switches']]) {
    await page.tap(`[data-pi-tab="${tab}"]`); await page.waitForFunction((n) => document.querySelector('#bmnPiBody').textContent.includes(n), needle, { timeout: 4000 }).then(() => ok(true, 'tab ' + tab + ' renders'), () => ok(false, 'tab ' + tab + ' renders'));
  }
  ok(!(await page.evaluate(() => window.__xss)), 'untrusted text from the API is escaped (no XSS)');
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'no horizontal overflow at 390px width');
  ok(calls.filter((c) => c.path.startsWith('/api/pi/owner')).every((c) => c.auth === 'Bearer tok-fresh'), 'every owner call carries the bearer token');
  // actions
  await page.tap('[data-pi-tab="cases"]'); await page.waitForSelector('[data-pi-case]'); calls.length = 0;
  await page.tap('[data-pi-case][data-r="no_violation"]'); await page.waitForTimeout(500);
  const post = calls.find((c) => c.method === 'POST'); ok(post && post.path.endsWith('/resolve') && JSON.parse(post.body).resolution === 'no_violation' && JSON.parse(post.body).note === 'test note', 'resolve sends resolution + required note');
  await page.tap('[data-pi-tab="controls"]'); await page.waitForSelector('[data-pi-flag]'); calls.length = 0;
  await page.tap('[data-pi-flag="moderation_analysis"]'); await page.waitForTimeout(500);
  const fl = calls.find((c) => c.method === 'POST'); ok(fl && fl.path.endsWith('/flags/moderation_analysis') && JSON.parse(fl.body).enabled === true && JSON.parse(fl.body).reason === 'test note', 'flag switch asks to confirm and sends reason');
  ok(dialogs.some((d) => /audit log/.test(d)), 'flag change warns it is audited');
  await page.tap('[data-pi-tab="verification"]'); await page.waitForSelector('[data-pi-ver]'); calls.length = 0;
  await page.tap('[data-pi-ver][data-d="rejected"]'); await page.waitForTimeout(500);
  ok(calls.some((c) => c.method === 'POST' && c.path.endsWith('/decide') && JSON.parse(c.body).decision === 'rejected'), 'owner can reject manually (human decision)');
  ok(!(await page.evaluate(() => /ban|delete account|revoke/i.test(document.querySelector('#bmnPi').innerText.replace(/cannot ban or delete accounts[^.]*\./i, '').replace(/never rejects or revokes/i, '')))), 'console offers no ban / delete / revoke control');
  await page.tap('[data-pi-tab="cases"]'); await page.waitForSelector('[data-pi-case]'); await page.screenshot({ path: process.env.SHOT || '/tmp/pi-console.png' });
  await page.keyboard.press('Escape'); ok(!(await page.locator('#bmnPi.open').count()), 'Escape closes the console');
  ok(errors.length === 0, 'owner: no page errors ' + errors.join('|'));
  await ctx.close(); await browser.close();
  console.log(`UI TOTAL=${pass + fail} PASSED=${pass} FAILED=${fail}`); process.exit(fail ? 1 : 0);
})();
