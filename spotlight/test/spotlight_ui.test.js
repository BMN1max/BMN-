// Spotlight front-end test: real index.html + real bmn-spotlight.js in headless Chromium, with a FAKE in-page Supabase (no network).
// The fake only mimics the RPC contract; the real SQL is tested separately by db/run_spotlight_tests.sh.
// Usage: NODE_PATH=/opt/npm-tools/node_modules node spotlight_ui.test.js [repo-root]
const { chromium } = require('playwright'); const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = path.resolve(process.argv[2] || path.join(__dirname, '..', '..'));
const FAKE = `(function(){
  const db = window.__db = { items: [], audit: [], owner: false, installed: true, now: Date.now() };
  const st = (i)=> i.status!=='published'?i.status:(i.ends_at&&Date.parse(i.ends_at)<=Date.now()?'ended':(i.starts_at&&Date.parse(i.starts_at)>Date.now()?'scheduled':'live'));
  const bad = (m)=>({data:null,error:{message:m}});
  const rpc = async (name,a)=>{ a=a||{}; window.__rpcLog=(window.__rpcLog||[]).concat(name);
    if(!db.installed && name.startsWith('bmn_spotlight')) return bad('Could not find the function public.'+name+' in the schema cache');
    if(name==='is_bmn_owner') return {data:db.owner,error:null};
    if(name==='bmn_spotlight_active'){ const items=db.items.filter(i=>i.status==='published'&&(!i.starts_at||Date.parse(i.starts_at)<=Date.now())&&(!i.ends_at||Date.parse(i.ends_at)>Date.now())&&(a.p_surface==='search'?i.show_in_search:i.show_on_profiles)).sort((x,y)=>y.priority-x.priority).slice(0,5);
      return {data:{now:new Date(db.now+ (Date.now()-window.__t0)).toISOString(),items},error:null}; }
    if(!db.owner) return bad('Only the BMN owner can manage Spotlight.');
    if(name==='bmn_spotlight_owner_list') return {data:db.items.map(i=>Object.assign({},i,{state:st(i)})),error:null};
    if(name==='bmn_spotlight_owner_save'){ const d=a.p_data; if(!d.title) return bad('Rejected'); let it=a.p_id&&db.items.find(x=>x.id===a.p_id);
      if(!it){ it={id:'id'+(db.items.length+1),status:'draft'}; db.items.push(it); db.audit.unshift({action:'created',detail:{title:d.title},at:new Date().toISOString()}); } else db.audit.unshift({action:'edited',detail:{title:d.title},at:new Date().toISOString()});
      Object.assign(it,d); return {data:Object.assign({},it,{state:st(it)}),error:null}; }
    if(name==='bmn_spotlight_owner_set_status'){ const it=db.items.find(x=>x.id===a.p_id); it.status=a.p_status; db.audit.unshift({action:'status_'+a.p_status,detail:{title:it.title},at:new Date().toISOString()}); return {data:it,error:null}; }
    if(name==='bmn_spotlight_owner_delete'){ const it=db.items.find(x=>x.id===a.p_id); db.items=db.items.filter(x=>x!==it); db.audit.unshift({action:'deleted',detail:{title:it.title},at:new Date().toISOString()}); return {data:true,error:null}; }
    if(name==='bmn_spotlight_owner_audit') return {data:db.audit,error:null};
    return {data:null,error:null}; };
  const mk=()=>{const f=function(){return p};const p=new Proxy(f,{get(t,k){if(k==='then')return(res)=>res({data:[],error:null,count:0});if(k==='data')return[];if(k==='error')return null;return(...a)=>p},apply(){return p}});return p};
  const auth={getSession:async()=>({data:{session:null},error:null}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),getUser:async()=>({data:{user:null},error:null}),signOut:async()=>({}),signInWithOAuth:async()=>({}),signInWithPassword:async()=>({data:{},error:{message:'stub'}})};
  window.__t0=Date.now();
  window.supabase={createClient:()=>({auth,from:()=>mk(),rpc,channel:()=>mk(),removeChannel(){},storage:{from:()=>mk()},functions:{invoke:async()=>({data:null,error:null})}})};})();`;
const srv = http.createServer((req, res) => { let p = decodeURIComponent(req.url.split('?')[0]); if (p === '/') p = '/index.html'; const f = path.join(ROOT, p);
  if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end(); }
  const t = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json' }[path.extname(f)] || 'application/octet-stream'; res.writeHead(200, { 'content-type': t }); fs.createReadStream(f).pipe(res); });
const results = []; const rec = (n, ok, d) => { results.push({ n, ok: !!ok, d }); console.log((ok ? 'PASS' : 'FAIL') + ' | ' + n + (ok ? '' : ' | ' + d)); };
(async () => {
  await new Promise((r) => srv.listen(0, r)); const base = 'http://127.0.0.1:' + srv.address().port; const browser = await chromium.launch();
  async function newPage(setup, vp) {
    const ctx = await browser.newContext({ viewport: vp || { width: 390, height: 844 }, deviceScaleFactor: 1 }); const page = await ctx.newPage(); const errors = [];
    page.on('pageerror', (e) => errors.push(e.message.slice(0, 160)));
    await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (r) => r.abort());   // registered FIRST: Playwright tries later routes first
    await page.route(/cdn\.jsdelivr\.net\/npm\/@supabase|unpkg\.com\/@supabase/, (r) => r.fulfill({ contentType: 'text/javascript', body: FAKE }));
    await page.route(/tus-js-client/, (r) => r.fulfill({ contentType: 'text/javascript', body: 'window.tus={Upload:function(){}}' }));
    await page.addInitScript(setup || (() => {})); page.__errors = errors; page.__ctx = ctx; return page;
  }
  const future = (ms) => new Date(Date.now() + ms).toISOString();
  const showDiscover = (page) => page.evaluate(() => { const v = document.querySelector('.lgtt-v-discover'); if (v) v.hidden = false; });

  // ---------- A. migration not applied: nothing appears, no errors
  let p = await newPage(() => { Object.defineProperty(window, '__pre', { value: 1 }); const i = setInterval(() => { if (window.__db) { window.__db.installed = false; clearInterval(i); } }, 1); });
  await p.goto(base + '/', { waitUntil: 'load' }); await p.waitForTimeout(2500);
  rec('A1 database migration not applied -> no Spotlight UI and no page errors', (await p.locator('#bmnSpotSearch,#bmnSpotProfile').count()) === 0 && p.__errors.length === 0, p.__errors.join(';'));
  await p.__ctx.close();

  // ---------- B. published items show; unsafe link, drafts, scheduled items do not
  p = await newPage(() => { const i = setInterval(() => { if (window.__db) { clearInterval(i);
    const f = (ms) => new Date(Date.now() + ms).toISOString();
    window.__db.items = [
      { id: 'a1', kind: 'holiday', title: 'Test holiday <b>bold</b>', subtitle: 'Sub <i>x</i>', accent: 'red', emoji: '🎉', link_url: 'https://example.com/x', cta_label: 'Open', countdown_to: f(3 * 86400000), countdown_label: 'Starts in', status: 'published', show_in_search: true, show_on_profiles: true, priority: 9 },
      { id: 'a2', kind: 'announcement', title: 'Info only', status: 'published', show_in_search: true, show_on_profiles: false, priority: 1 },
      { id: 'a3', kind: 'campaign', title: 'Evil link', link_url: 'javascript:alert(1)', cta_label: 'Go', status: 'published', show_in_search: true, show_on_profiles: false, priority: 0 },
      { id: 'a4', kind: 'seasonal', title: 'Internal path', link_url: '/discover', cta_label: 'Go', status: 'published', show_in_search: true, show_on_profiles: false, priority: -1 },
      { id: 'a5', kind: 'seasonal', title: 'Draft hidden', status: 'draft', show_in_search: true, priority: 99 }];
    window.__xss = 0; window.alert = () => { window.__xss++; }; } }, 1); });
  await p.goto(base + '/', { waitUntil: 'load' }); await p.waitForSelector('#bmnSpotSearch', { timeout: 8000, state: 'attached' }).catch(() => {});
  const titles = await p.$$eval('#bmnSpotSearch .bmn-sp-t', (els) => els.map((e) => e.textContent));
  rec('B1 published items appear on Discover, sorted by priority, drafts excluded', JSON.stringify(titles) === JSON.stringify(['Test holiday <b>bold</b>', 'Info only', 'Evil link', 'Internal path']), JSON.stringify(titles));
  rec('B2 HTML in titles is shown as text, not executed', (await p.locator('#bmnSpotSearch b').count()) === 0 && (await p.locator('#bmnSpotSearch i').count()) === 0);
  const hrefs = await p.$$eval('#bmnSpotSearch a.bmn-sp', (els) => els.map((e) => [e.getAttribute('href'), e.getAttribute('target'), e.getAttribute('rel')]));
  rec('B3 https link opens in a new tab with noopener; internal path stays in-app; javascript: link is NOT a link', hrefs.length === 2 && hrefs[0][0] === 'https://example.com/x' && hrefs[0][1] === '_blank' && /noopener/.test(hrefs[0][2]) && hrefs[1][0] === '/discover' && !hrefs[1][1], JSON.stringify(hrefs));
  rec('B4 an item without a link is information only (not a button / link)', (await p.locator('#bmnSpotSearch div.bmn-sp[role=note]').count()) === 2);
  const cd1 = await p.locator('[data-sp-cd] span').first().textContent(); await p.waitForTimeout(2200); const cd2 = await p.locator('[data-sp-cd] span').first().textContent();
  rec('B5 countdown shows days+time and ticks', /^2d 23:5\d:\d\d$|^3d 00:00:\d\d$/.test(cd1) && cd1 !== cd2, cd1 + ' -> ' + cd2);
  rec('B6 the profile surface shows only items opted in for profiles', await p.evaluate(async () => { await window.__bmnSpotlight._refresh(); return window.__bmnSpotlight._feed.profile.map((x) => x.id).join() === 'a1'; }));
  rec('B7 no JS errors on the page', p.__errors.length === 0, p.__errors.join(';'));
  await showDiscover(p); await p.waitForTimeout(200);
  const box = await p.locator('#bmnSpotSearch').boundingBox(); rec('B8 on a 390px phone the card stack fits the screen width (no horizontal overflow)', box && box.x >= 0 && box.x + box.width <= 390 && (await p.evaluate(() => document.documentElement.scrollWidth <= 390)), JSON.stringify(box));
  await p.screenshot({ path: path.join(__dirname, 'spotlight_discover.png') });
  // zero items -> container removed
  rec('B9 when the feed becomes empty the card disappears', await p.evaluate(async () => { window.__db.items.forEach((i) => (i.status = 'paused')); await window.__bmnSpotlight._refresh(); return !document.getElementById('bmnSpotSearch'); }));
  await p.__ctx.close();

  // ---------- C. non-owner never sees the manager button
  p = await newPage(() => { const i = setInterval(() => { if (window.__db) { clearInterval(i); window.__db.owner = false; } }, 1); });
  await p.goto(base + '/', { waitUntil: 'load' }); await p.waitForTimeout(800);
  await p.evaluate(() => { window.bmnSession = { user: { id: 'u-normal' } }; const h = document.getElementById('lgttProfHead'); h.innerHTML = '<div class="lgtt-prof-actions"></div>'; }); await p.waitForTimeout(3500);
  rec('C1 a normal signed-in user gets NO Spotlight manager button', (await p.locator('#bmnSpotOpen').count()) === 0);
  rec('C2 window.bmnOpenSpotlight does nothing for a non-owner', await p.evaluate(() => { window.bmnOpenSpotlight(); return !document.getElementById('bmnSpMgr') || !document.getElementById('bmnSpMgr').classList.contains('open'); }));
  await p.__ctx.close();

  // ---------- D. owner manager: full flow
  p = await newPage(() => { const i = setInterval(() => { if (window.__db) { clearInterval(i); window.__db.owner = true; } }, 1); });
  await p.goto(base + '/', { waitUntil: 'load' }); await p.waitForTimeout(800);
  await p.evaluate(() => { window.bmnSession = { user: { id: 'u-owner' } }; document.getElementById('lgttProfHead').innerHTML = '<div class="lgtt-prof-actions"></div>'; });
  await p.waitForSelector('#bmnSpotOpen', { timeout: 8000 }).catch(() => {});
  rec('D1 the owner sees the Spotlight button on the profile', (await p.locator('#bmnSpotOpen').count()) === 1);
  await p.evaluate(() => { const v = document.querySelector('.lgtt-v-profile'); if (v) v.hidden = false; });   // the profile tab is not navigated in this harness
  await p.evaluate(() => document.getElementById('bmnSpotOpen').click()); await p.waitForSelector('#bmnSpMgr.open');   // programmatic click: the harness shows the profile view without its normal scrim state
  rec('D2 the manager opens and an empty database shows the honest empty state (no sample content)', /No Spotlight items yet/.test(await p.locator('#bmnSpBody').innerText()));
  await p.click('[data-sp=new]'); await p.fill('#spTitle', 'Weekend premiere'); await p.fill('#spSub', 'Watch together'); await p.fill('#spEmoji', '🎬'); await p.selectOption('#spKind', 'entertainment');
  await p.fill('#spLink', 'javascript:alert(1)'); await p.click('#spSave'); await p.waitForTimeout(200);
  rec('D3 an unsafe link is refused by the form before anything is sent', /must start with https/.test(await p.locator('#bmnSpBody').innerText()) && (await p.evaluate(() => window.__db.items.length)) === 0);
  await p.fill('#spLink', 'https://example.com/premiere'); await p.fill('#spCta', 'Details');
  const prev = await p.locator('#bmnSpPrev .bmn-sp-t').textContent(); await p.fill('#spStart', '2030-01-01T10:00'); await p.fill('#spEnd', '2029-01-01T10:00'); await p.click('#spSave'); await p.waitForTimeout(200);
  rec('D4 live preview mirrors the form; end-before-start is refused', prev === 'Weekend premiere' && /end must be after/.test(await p.locator('#bmnSpBody').innerText()));
  await p.fill('#spStart', ''); await p.fill('#spEnd', ''); await p.click('#spSave'); await p.waitForSelector('.sp-row');
  rec('D5 save creates a DRAFT and says so', /draft/i.test(await p.locator('#bmnSpBody').innerText()) && (await p.evaluate(() => window.__db.items[0].status)) === 'draft');
  rec('D6 a draft is not public', await p.evaluate(async () => { await window.__bmnSpotlight._refresh(); return window.__bmnSpotlight._feed.search.length === 0 && !document.getElementById('bmnSpotSearch'); }));
  await p.click('[data-sp=status][data-s=published]'); await p.waitForSelector('.sp-st.st-live');
  rec('D7 Publish makes it live and it appears on Discover immediately', (await p.locator('#bmnSpotSearch .bmn-sp-t').first().textContent()) === 'Weekend premiere');
  await p.click('[data-sp=status][data-s=paused]'); await p.waitForSelector('.sp-st.st-paused'); 
  rec('D8 Pause removes it from Discover immediately', (await p.locator('#bmnSpotSearch').count()) === 0);
  await p.click('[data-sp=edit]'); await p.fill('#spTitle', 'Weekend premiere (edited)'); await p.click('#spSave'); await p.waitForSelector('.sp-row');
  rec('D9 edit saves and keeps the paused state', /edited/.test(await p.locator('.sp-row b').first().textContent()) && (await p.evaluate(() => window.__db.items[0].status)) === 'paused');
  await p.click('[data-sp=audit]'); await p.waitForSelector('.sp-row');
  const au = await p.locator('#bmnSpBody').innerText(); rec('D10 the audit log lists created / edited / status changes', /created/i.test(au) && /edited/i.test(au) && /status published/i.test(au) && /status paused/i.test(au), au.slice(0, 200));
  await p.click('[data-sp=back]'); await p.waitForSelector('[data-sp=delete]');
  p.once('dialog', (d) => d.dismiss()); await p.click('[data-sp=delete]'); await p.waitForTimeout(150);
  rec('D11 cancelling the delete confirmation deletes nothing', (await p.evaluate(() => window.__db.items.length)) === 1);
  p.once('dialog', (d) => d.accept()); await p.click('[data-sp=delete]'); await p.waitForTimeout(400);
  rec('D12 confirming deletes it', (await p.evaluate(() => window.__db.items.length)) === 0 && /Deleted/.test(await p.locator('#bmnSpBody').innerText()));
  await p.screenshot({ path: path.join(__dirname, 'spotlight_manager.png') });
  await p.keyboard.press('Escape'); await p.waitForTimeout(150); const o13 = await p.evaluate(() => ({ open: document.getElementById('bmnSpMgr').classList.contains('open'), ov: document.documentElement.style.overflow })); rec('D13 Escape closes the manager and restores page scrolling', !o13.open && o13.ov === '', JSON.stringify(o13));
  rec('D14 no JS errors during the owner flow', p.__errors.length === 0, p.__errors.join(';'));
  await p.__ctx.close();

  await browser.close(); srv.close();
  const f = results.filter((r) => !r.ok).length; console.log('TOTAL=' + results.length + ' PASSED=' + (results.length - f) + ' FAILED=' + f); process.exit(f ? 1 : 0);
})();
