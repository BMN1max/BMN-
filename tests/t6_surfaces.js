/* Batch 2 surface tests + screenshots (Playwright + Chromium EMULATION; not Safari, not a real device).
   Run:  python3 -m http.server 8124 --bind 127.0.0.1   (repo root)   and   node dbserver.js   (in tests/)
         BASE=http://127.0.0.1:8124/index.html node tests/t6_surfaces.js
   Optional env: SHOTS=<dir> save a screenshot per surface; TAG=<name> filename prefix; PROFILES=iphone,android,desktop; THEMES=dark,light
   Test-only fixtures: the Spotlight/owner/Platform-Intelligence responses below only give those owner/DB-driven UIs something to render
   (shapes read from bmn-spotlight.js / bmn-intelligence.js). They are never shipped and never touch a real backend.
   The feed posts come from the app's own LGTT.setPosts() with local test clips (http://127.0.0.1:8125/clipN.mp4). */
const { chromium, devices } = require('playwright');
const fs = require('fs'), path = require('path');
const BASE = process.env.BASE || 'http://127.0.0.1:8124/index.html';
const CLIPS = process.env.CLIPS || 'http://127.0.0.1:8125';
const SHOTS = process.env.SHOTS || '', TAG = process.env.TAG || 'run';
const PROFILES = (process.env.PROFILES || 'iphone').split(','), THEMES = (process.env.THEMES || 'dark,light').split(',');
const ONLY = (process.env.ONLY || '').split(',').filter(Boolean);
const mock = fs.readFileSync(path.join(__dirname, 'mockclient.js'), 'utf8');
const U = 'aaaaaaaa-0000-4000-8000-000000000001';
const DEV = { iphone: devices['iPhone 14'], android: devices['Pixel 7'], desktop: { viewport: { width: 1280, height: 800 } } };
let pass = 0, fail = 0;
const COVER = process.env.COVER === '1', hit = new Set(), all = new Set();   // COVER=1: report which selectors of bmn-liquid-surfaces.css matched nothing in any tested state
const check = (n, ok, x) => { ok ? pass++ : fail++; console.log((ok ? 'PASS ' : 'FAIL ') + n + (x !== undefined ? '  [' + x + ']' : '')); };
/* The new CSS/JS are linked from index.html by two inserted lines (see the delivery notes). To test them WITHOUT editing index.html in the repo,
   the page response is rewritten in the test browser: INJECT=0 disables it (baseline run), default is on. */
const INJECT = process.env.INJECT !== '0';
const BOARD_ROWS = (() => { const now = Date.now(), base = { author_id: U, parent_id: null, root_id: null, quote_id: null, media: [], status: 'published', edited_at: null, deleted_at: null, quote_count: 0 };
  return [Object.assign({}, base, { id: 'b1', body: 'Layout fixture: a plain text post to check type, spacing and the action row. #bmn', like_count: 12, repost_count: 3, reply_count: 2, view_count: 140, created_at: new Date(now - 36e5).toISOString() }),
          Object.assign({}, base, { id: 'b2', body: 'Second fixture post, a bit longer so the line wraps onto a second and third line and the timeline rhythm is visible in both themes.', like_count: 0, repost_count: 0, reply_count: 0, view_count: 9, created_at: new Date(now - 9e6).toISOString() })]; })();
const PIAPI = 'https://bmn-r2-api-2026.onrender.com';   // the app overwrites BMN_API_BASE_URL with this host; the route below answers /api/pi/** locally so nothing leaves the test browser

async function open(b, prof, th, opts = {}) {
  const ctx = await b.newContext({ ...DEV[prof], colorScheme: th, deviceScaleFactor: SHOTS ? 2 : 1 });
  await ctx.addInitScript('window.__MOCK_UID=' + JSON.stringify(U) + ';window.BMN_API_BASE_URL=' + JSON.stringify(PIAPI) + ';try{localStorage.setItem("bmn-theme-mode",' + JSON.stringify(th) + ');localStorage.setItem("bmn-onboarded-' + U + '","1");localStorage.setItem("bmn-install-dismissed",String(Date.now()+99999999999))}catch(e){}');
  await ctx.addInitScript(mock);
  const errs = [];
  const p = await ctx.newPage(); p.on('requestfailed', rq => { if (process.env.DBG) console.log('RF', rq.url().slice(0, 80), rq.failure().errorText); }); p.on('pageerror', e => errs.push((e.message + ' @ ' + String(e.stack || '').split('\n').slice(1, 3).join('|')).slice(0, 300)));
  await p.route(/^https?:\/\/(?!localhost|127\.0\.0\.1)/, r => r.abort());
  if (opts.board) await p.route(/:8130\/query/, async r => {
    let b = {}; try { b = JSON.parse(r.request().postData() || '{}'); } catch (e) {}
    if (b.q && b.q.table === 'board_posts' && b.q.op === 'select') return r.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ data: BOARD_ROWS, error: null }) });
    r.continue();
  });
  if (opts.owner || opts.board) {
    await p.route(/:8130\/rpc/, async r => {
      let body = {}; try { body = JSON.parse(r.request().postData() || '{}'); } catch (e) {}
      const n = body.name, ok = d => r.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ data: d }) });
      if (n === 'board_feed' && opts.board) return ok(BOARD_ROWS.map((x, i) => ({ post_id: x.id, sort_at: x.created_at })));
      if (n && /^board_/.test(n) && opts.board) return ok([]);
      if (n === 'is_bmn_owner') return opts.owner ? ok(true) : r.continue();
      if (n === 'bmn_spotlight_active') return ok({ now: new Date().toISOString(), items: [{ id: 's1', kind: 'announcement', title: 'UI check: spotlight card', subtitle: 'Fixture for layout only', emoji: '✨', accent: 'violet', cta_label: 'Open', link_url: '/', countdown_to: new Date(Date.now() + 3 * 86400e3).toISOString(), countdown_label: 'Ends in' }, { id: 's2', kind: 'holiday', title: 'Second card (accent gold)', accent: 'gold' }] });
      if (n === 'bmn_spotlight_owner_list') return ok([{ id: 's1', title: 'UI check: spotlight card', kind: 'announcement', status: 'live', starts_at: new Date().toISOString(), ends_at: new Date(Date.now() + 864e5).toISOString() }]);
      return r.continue();
    });
    await p.route(PIAPI + '/api/pi/**', async r => {
      const u = new URL(r.request().url()), seg = u.pathname.replace('/api/pi/owner', '');
      const d = { '/overview': { flags: { analysis: true }, halted: false, cases: { awaiting_review: 3, urgent: 1 }, workers: [{ worker_id: 'w1', seen_seconds_ago: 4, jobs_succeeded: 12, jobs_failed: 0 }] }, '/health': { workers_active: 1, dead_jobs_24h: 0, oldest_queued_seconds: 0 }, '/alerts': [{ kind: 'queue_backlog', severity: 'medium', message: 'Layout fixture' }], '/events': [], '/cases': [], '/accounts': [], '/investigations': [], '/restrictions': [], '/appeals': [], '/verification': { pending: [], recent_decisions: [] } }[seg];
      const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,OPTIONS' };
      if (r.request().method() === 'OPTIONS') return r.fulfill({ status: 204, headers: cors });
      r.fulfill({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify({ data: d === undefined ? [] : d }) });
    });
  }
  if (INJECT) await ctx.addInitScript(({ css, js }) => {
    /* same position as the delivered index.html edit: right after the bmn-liquid.css <link> / bmn-board.js <script> as the parser reaches them */
    const mo = new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) {
      if (n.nodeName === 'LINK' && /\/bmn-liquid\.css$/.test(n.getAttribute('href') || '')) { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = css; n.after(l); }
      if (js && n.nodeName === 'SCRIPT' && /\/bmn-board\.js$/.test(n.getAttribute('src') || '')) { const sc = document.createElement('script'); sc.src = js; sc.defer = true; n.after(sc); }
    } });
    mo.observe(document, { childList: true, subtree: true });
  }, { css: '/bmn-liquid-surfaces.css', js: fs.existsSync(path.join(__dirname, '..', 'bmn-glass-touch.js')) ? '/bmn-glass-touch.js' : '' });
  await p.goto(BASE, { waitUntil: 'load' });
  await p.waitForSelector('#lgttDock', { timeout: 30000 }); await p.waitForTimeout(3500);
  if (opts.posts) {
    await p.evaluate((c) => { const posts = []; for (let i = 0; i < 4; i++) posts.push({ id: 't' + i, u: 'bmn', cap: 'Test clip ' + i + ' #bmn', music: 'Original sound', dur: 8, src: c + '/clip' + ((i % 4) + 1) + '.mp4?n=' + i }); window.LGTT.setPosts(posts); }, CLIPS);
    await p.waitForTimeout(2500);
  }
  return { ctx, p, errs };
}

const S = {
  async feed_media(p) { return await p.evaluate(() => !!document.querySelector('.lgtt-slide.is-active .lgtt-prog')); },
  async comments(p) { await p.evaluate(() => document.querySelector('.lgtt-slide.is-active [data-act="comment"]').click()); await p.waitForTimeout(1200); return await p.evaluate(() => document.getElementById('lgttComments').getAttribute('aria-hidden') === 'false'); },
  async share(p) { await p.evaluate(() => document.querySelector('.lgtt-slide.is-active [data-act="share"]').click()); await p.waitForTimeout(1200); return await p.evaluate(() => document.getElementById('lgttShare').getAttribute('aria-hidden') === 'false'); },
  async settings_account(p) { return await setTab(p, 'account'); },
  async settings_privacy(p) { return await setTab(p, 'privacy'); },
  async settings_alerts(p) { return await setTab(p, 'notif'); },
  async board(p) { await p.evaluate(() => window.BMNBoard.open()); await p.waitForTimeout(2000); return await p.evaluate(() => document.body.classList.contains('bmn-board-open')); },
  async board_notifs(p) { await p.evaluate(() => window.BMNBoard.open()); await p.waitForTimeout(1500); const ok = await p.evaluate(() => { const b = document.querySelector('[data-view="notifs"],[data-nav="notifs"],[data-v="notifs"]'); if (b) { b.click(); return true; } return false; }); await p.waitForTimeout(1500); return ok; },
  async spotlight(p) { await p.evaluate(() => LGTT.setView('profile')); await p.waitForTimeout(3500); return await p.evaluate(() => !!document.querySelector('#bmnSpotProfile .bmn-sp')); },
  async spotlight_mgr(p) { await p.evaluate(() => LGTT.setView('profile')); await p.waitForSelector('#bmnSpotOpen', { timeout: 12000 }); await p.evaluate(() => document.getElementById('bmnSpotOpen').click()); await p.waitForTimeout(1800); return await p.evaluate(() => document.getElementById('bmnSpMgr').classList.contains('open')); },
  async pi(p) { await p.evaluate(() => LGTT.setView('profile')); await p.waitForTimeout(1500); await p.waitForSelector('#bmnPiOpen', { timeout: 12000 }); await p.evaluate(() => document.getElementById('bmnPiOpen').click()); await p.waitForTimeout(2000); return await p.evaluate(() => document.getElementById('bmnPi').classList.contains('open')); },
};
async function setTab(p, tab) { await p.evaluate(() => LGTT.openSettings()); await p.waitForTimeout(900); const ok = await p.evaluate(t => { const b = document.querySelector('#lgttSetTabs [data-stab="' + t + '"]'); if (b) { b.click(); return true; } return false; }, tab); await p.waitForTimeout(1000); return ok; }
const NEEDS = { board: { board: 1 }, board_notifs: { board: 1 }, feed_media: { posts: 1 }, comments: { posts: 1 }, share: { posts: 1 }, spotlight: { owner: 1 }, spotlight_mgr: { owner: 1 }, pi: { owner: 1 } };

(async () => {
  const b = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
  if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });
  for (const prof of PROFILES) for (const th of THEMES) for (const name of Object.keys(S)) {
    if (ONLY.length && !ONLY.includes(name)) continue;
    const u = await open(b, prof, th, NEEDS[name] || {});
    let ok = false, err = '';
    try { ok = await S[name](u.p); if (SHOTS) await u.p.screenshot({ path: path.join(SHOTS, `${TAG}_${prof}_${th}_${name}.png`) }); } catch (e) { err = String(e.message).slice(0, 90); }
    if (COVER) { try { const r = await u.p.evaluate(() => { const out = { all: [], hit: [] }; for (const sh of document.styleSheets) { if (!/bmn-liquid-surfaces\.css/.test(sh.href || '')) continue; const walk = rules => { for (const r of rules) { if (r.selectorText) { for (let sel of r.selectorText.split(/,(?![^(]*\))/)) { sel = sel.trim().replace(/::?(hover|active|focus-visible|focus|before|after|-webkit-[a-z-]+)/g, ''); out.all.push(sel); try { if (document.querySelector(sel)) out.hit.push(sel); } catch (e) {} } } else if (r.cssRules) walk(r.cssRules); } }; walk(sh.cssRules); } return out; }); r.all.forEach(x => all.add(x)); r.hit.forEach(x => hit.add(x)); } catch (e) {} }
    if (name === 'pi' && ok) { try {
      const c = await u.p.evaluate(() => { const b = document.querySelector('#bmnPi .pi-body'); const mk = cls => { const e = document.createElement('span'); e.className = cls; e.textContent = 'x'; b.appendChild(e); return getComputedStyle(e).backgroundColor; };
        const btn = document.createElement('button'); btn.className = 'pi-btn danger'; btn.textContent = 'x'; b.appendChild(btn); return { high: mk('pi-pill high'), med: mk('pi-pill medium'), low: mk('pi-pill low'), neutral: mk('pi-pill'), danger: getComputedStyle(btn).backgroundColor }; });
      const rgb = x => (x.match(/[\d.]+/g) || []).map(Number);
      check(`${prof}/${th}/pi: severity pills keep red / amber / green`, rgb(c.high)[0] > rgb(c.high)[2] + 60 && rgb(c.med)[0] > rgb(c.med)[2] + 60 && rgb(c.low)[1] > rgb(c.low)[0] + 40, JSON.stringify([c.high, c.med, c.low]));
      check(`${prof}/${th}/pi: danger button stays red`, rgb(c.danger)[0] > rgb(c.danger)[2] + 60, c.danger);
    } catch (e) { check(`${prof}/${th}/pi: severity probe`, false, String(e.message).slice(0, 80)); } }
    check(`${prof}/${th}/${name}: opens`, ok, err || undefined);
    check(`${prof}/${th}/${name}: no page errors`, u.errs.length === 0, u.errs[0]);
    await u.ctx.close();
  }
  if (COVER) { const miss = [...all].filter(x => !hit.has(x)); console.log('\nSELECTORS WITH NO MATCH IN ANY TESTED STATE (' + miss.length + ' of ' + all.size + '):\n' + miss.join('\n')); }
  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})();
