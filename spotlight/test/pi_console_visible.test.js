// Regression test for a Batch 2 defect found in Batch 3: the real index.html hides every direct child of <body> except #lgtt
// (html.bmn-community-app body>:not(#lgtt){display:none!important}), which made the Intelligence console invisible. Fake Supabase, no network.
const { chromium } = require('playwright'); const fs = require('fs'), http = require('http'), path = require('path');
const ROOT = path.resolve(process.argv[2] || path.join(__dirname, '..', '..'));
const src = fs.readFileSync(path.join(__dirname, 'spotlight_ui.test.js'), 'utf8'); const FAKE = src.match(/const FAKE = `([\s\S]*?)`;\nconst srv/)[1];
const srv = http.createServer((q, r) => { let p = q.url.split('?')[0]; if (p === '/') p = '/index.html'; const f = path.join(ROOT, p); if (!fs.existsSync(f)) { r.writeHead(404); return r.end(); } r.writeHead(200, { 'content-type': p.endsWith('.js') ? 'text/javascript' : p.endsWith('.html') ? 'text/html' : 'text/css' }); fs.createReadStream(f).pipe(r); });
(async () => {
  await new Promise((r) => srv.listen(0, r)); const b = await chromium.launch(); const pg = await b.newPage({ viewport: { width: 390, height: 844 } }); const errs = []; pg.on('pageerror', (e) => errs.push(e.message));
  await pg.route(/^https?:\/\/(?!127\.0\.0\.1)/, (r) => r.abort());
  await pg.route(/cdn\.jsdelivr\.net\/npm\/@supabase|unpkg\.com\/@supabase/, (r) => r.fulfill({ contentType: 'text/javascript', body: FAKE }));
  await pg.route(/tus-js-client/, (r) => r.fulfill({ contentType: 'text/javascript', body: 'window.tus={Upload:function(){}}' }));
  await pg.addInitScript(() => { const i = setInterval(() => { if (window.__db) { clearInterval(i); window.__db.owner = true; } }, 1); });
  await pg.goto('http://127.0.0.1:' + srv.address().port + '/'); await pg.waitForTimeout(1200);
  await pg.evaluate(() => { window.bmnSession = { user: { id: 'o' } }; document.getElementById('lgttProfHead').innerHTML = '<div class="lgtt-prof-actions"></div>'; });
  await pg.waitForSelector('#bmnPiOpen', { state: 'attached', timeout: 8000 });
  await pg.evaluate(() => document.getElementById('bmnPiOpen').click()); await pg.waitForTimeout(600);
  const o = await pg.evaluate(() => { const e = document.getElementById('bmnPi'); const cs = getComputedStyle(e), r = e.getBoundingClientRect(); return { open: e.classList.contains('open'), display: cs.display, vis: cs.visibility, w: Math.round(r.width), h: Math.round(r.height), htmlClass: /bmn-community-app/.test(document.documentElement.className) }; });
  const ok = o.htmlClass && o.open && o.display === 'flex' && o.vis === 'visible' && o.w === 390 && o.h === 844;
  console.log((ok ? 'PASS' : 'FAIL') + ' | Intelligence console is visible, full-screen (flex) while html.bmn-community-app is active | ' + JSON.stringify(o) + (errs.length ? ' errors:' + errs : ''));
  await pg.screenshot({ path: path.join(__dirname, 'intelligence_console.png') }); await b.close(); srv.close(); process.exit(ok ? 0 : 1);
})();
