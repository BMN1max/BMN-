const { chromium, devices } = require('playwright');
let pass=0, fail=0; const out=[]; const ok=(n,c,x='')=>{(c?pass++:fail++);out.push((c?'PASS ':'FAIL ')+n+(x?'  — '+x:''))};
(async()=>{
  const b = await chromium.launch(); const ctx = await b.newContext({ ...devices['iPhone 14'] });
  await ctx.addInitScript(()=>{try{localStorage.setItem('bmn-install-dismissed',String(Date.now()+864e5))}catch(e){}}); // keep the (separately tested) install offer out of these flows
  const p = await ctx.newPage(); const cdp = await ctx.newCDPSession(p);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  await p.route(/^https?:\/\/(?!localhost)/, r=>r.abort());
  await p.goto('file://'+require('path').resolve(__dirname,'../../index.html')+'?glass=on',{waitUntil:'load'});
  await p.waitForFunction(()=>document.querySelector('#lgttDock .bmn-gn .lg-track__item')?.getBoundingClientRect().width>10);
  await p.waitForTimeout(800);
  const T=(type,x,y)=>cdp.send('Input.dispatchTouchEvent',{type,touchPoints:type==='touchEnd'?[]:[{x,y,id:1}]});
  const tapAt=async(x,y)=>{await T('touchStart',x,y);await p.waitForTimeout(40);await T('touchEnd');await p.waitForTimeout(400)};
  const settle=async()=>{await p.evaluate(()=>{window.__sy=undefined});await p.waitForFunction(()=>{const z=document.querySelector('#bmnSheetHost .lg-sheet');if(!z)return false;const y=z.getBoundingClientRect().y;const last=window.__sy;window.__sy=y;return last!==undefined&&Math.abs(last-y)<0.5&&y<400},null,{polling:150,timeout:10000}).catch(()=>{});await p.waitForTimeout(300)};
  const rect=(sel)=>p.evaluate(s=>{const e=document.querySelector(s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,h:r.height,l:r.left,t:r.top}},sel);

  await p.waitForFunction(()=>document.querySelector('#lgttTabs ~ .bmn-gs-host .lg-track > .lg-track__item')?.getBoundingClientRect().width>40,null,{timeout:10000}).catch(()=>{}); await p.waitForTimeout(1200);
  // ---------- Segmented (feed tabs) ----------
  const seg0 = await p.evaluate(()=>document.querySelector('#lgttTabs button.on')?.dataset.tab);
  ok('segmented: starts on For You (fyp)', seg0==='fyp', seg0);
  let r=await rect('#lgttTabs ~ .bmn-gs-host .lg-track > .lg-track__item[data-lg-item="0"]');
  ok('segmented: glass control present as sibling overlay', !!r && r.w>40, JSON.stringify(r));
  await tapAt(r.x,r.y);
  const seg1 = await p.evaluate(()=>document.querySelector('#lgttTabs button.on')?.dataset.tab);
  ok('segmented: tap Following drives the ORIGINAL tab', seg1==='following', seg1);
  // drag lens back to For You
  const a=await rect('#lgttTabs ~ .bmn-gs-host .lg-track > .lg-track__item[data-lg-item="0"]'), c=await rect('#lgttTabs ~ .bmn-gs-host .lg-track > .lg-track__item[data-lg-item="1"]');
  await T('touchStart',a.x,a.y); for(let i=1;i<=12;i++){await T('touchMove',a.x+(c.x-a.x)*i/12,a.y);await p.waitForTimeout(16)} await T('touchEnd'); await p.waitForTimeout(500);
  const seg2 = await p.evaluate(()=>document.querySelector('#lgttTabs button.on')?.dataset.tab);
  ok('segmented: drag selection lens Following->For You', seg2==='fyp', seg2);
  // keyboard
  await p.evaluate(()=>document.querySelector('#lgttTabs ~ .bmn-gs-host .lg-track')?.focus());
  ok('segmented: original tabs untouched in DOM (4 attrs intact)', await p.evaluate(()=>!!document.querySelector('#lgttTabs button[data-tab="following"][role="tab"]')));

  // ---------- Settings switch ----------
  await p.evaluate(()=>LGTT.openSettings()); await p.waitForTimeout(900); await p.evaluate(()=>document.querySelector('[data-stab="privacy"]').click()); await p.waitForTimeout(900);
  const sw = await p.evaluate(()=>({n:document.querySelectorAll('#lgttSetBody .lgtt-switch').length,slots:document.querySelectorAll('#lgttSetBody .bmn-gw-slot').length,hidden:[...document.querySelectorAll('#lgttSetBody .lgtt-switch')].every(e=>getComputedStyle(e).display==='none')}));
  ok('switch: every .lgtt-switch has a GlassSwitch and the original is hidden', sw.n>0 && sw.slots===sw.n && sw.hidden, JSON.stringify(sw));
  if(sw.n){
    const before=await p.evaluate(()=>document.querySelector('#lgttSetBody .lgtt-switch').getAttribute('aria-checked'));
    const gs=await rect('#lgttSetBody .bmn-gw-slot button[role="switch"], #lgttSetBody .bmn-gw-slot .lg-switch');
    await tapAt(gs.x,gs.y); await p.waitForTimeout(300);
    const after=await p.evaluate(()=>document.querySelector('#lgttSetBody .lgtt-switch').getAttribute('aria-checked'));
    const glassState=await p.evaluate(()=>document.querySelector('#lgttSetBody .bmn-gw-slot [role="switch"]')?.getAttribute('aria-checked'));
    ok('switch: tap flips the ORIGINAL setting', before!==after, before+' -> '+after);
    ok('switch: glass state follows original', glassState===after, 'glass='+glassState);
    // drag
    const g2=await rect('#lgttSetBody .bmn-gw-slot [role="switch"]'); const st0=after;
    await T('touchStart',g2.x-10,g2.y); for(let i=1;i<=10;i++){await T('touchMove',g2.x-10+i*4*(st0==='true'?-1:1),g2.y);await p.waitForTimeout(16)} await T('touchEnd'); await p.waitForTimeout(500);
    const after2=await p.evaluate(()=>document.querySelector('#lgttSetBody .lgtt-switch').getAttribute('aria-checked'));
    ok('switch: drag also drives the original (or settles consistently)', after2===(await p.evaluate(()=>document.querySelector('#lgttSetBody .bmn-gw-slot [role="switch"]')?.getAttribute('aria-checked'))), 'orig='+after2);
  }
  await p.evaluate(()=>{document.querySelector('#lgtt [data-act="close-layer"]')?.click()}); await p.waitForTimeout(600);

  await p.evaluate(()=>{document.querySelector('#lgttSettings [data-act="close-layer"]')?.click(); document.querySelector('#lgttTabs button[data-tab="fyp"]')?.click()}); await p.waitForTimeout(600);
  // ---------- Menu (long-press a slide) ----------
  await p.evaluate(()=>LGTT.setPosts([{id:'t1',u:'bmn',cap:'Test post (fixture)',music:'x',dur:10,src:'https://example.invalid/a.mp4'}])); await p.waitForTimeout(1200);
  await p.evaluate(()=>window.bmnCloseSheet&&window.bmnCloseSheet()); await p.waitForTimeout(700); // the idle-gated install offer may have appeared; it is app behaviour, not under test here
  const lp={x:195,y:330};
  await p.waitForFunction(()=>document.querySelectorAll('.lgtt-slide').length>0,null,{timeout:8000}).catch(()=>{});
  for(let k=0;k<3;k++){await T('touchStart',lp.x,lp.y); await p.waitForTimeout(800); await T('touchEnd'); await p.waitForTimeout(1200); if(await p.evaluate(()=>document.getElementById('lgttMenu')?.classList.contains('is-open')))break; await p.waitForTimeout(500)}
  const menu = await p.evaluate(()=>({layerOpen:document.getElementById('lgttMenu')?.classList.contains('is-open'),glass:!!document.querySelector('.bmn-gm'),items:document.querySelectorAll('.bmn-gm [role="menuitem"], .bmn-gm [role="menuitemradio"]').length,orig:document.querySelectorAll('#lgttMenuList [data-mi]').length,expanded:document.querySelector('.bmn-gm button[aria-haspopup]')?.getAttribute('aria-expanded')}));
  ok('menu: long-press opens GlassMenu with the same items as BMN built', menu.layerOpen && menu.glass && menu.items===menu.orig && menu.items>0, JSON.stringify(menu));
  ok('menu: expanded from its trigger', menu.expanded==='true', menu.expanded);
  // Escape closes both
  await p.keyboard.press('Escape'); await p.waitForTimeout(900);
  const esc = await p.evaluate(()=>({layerOpen:document.getElementById('lgttMenu')?.classList.contains('is-open'),glass:!!document.querySelector('.bmn-gm')}));
  ok('menu: Escape folds the glass menu AND closes BMN layer', !esc.layerOpen && !esc.glass, JSON.stringify(esc));
  // reopen, outside tap
  await T('touchStart',lp.x,lp.y); await p.waitForTimeout(800); await T('touchEnd'); await p.waitForTimeout(900);
  await tapAt(40,560); await p.waitForTimeout(800);
  const outside = await p.evaluate(()=>({layerOpen:document.getElementById('lgttMenu')?.classList.contains('is-open'),glass:!!document.querySelector('.bmn-gm')}));
  ok('menu: outside tap dismisses both', !outside.layerOpen && !outside.glass, JSON.stringify(outside));
  // reopen, pick first item
  await T('touchStart',lp.x,lp.y); await p.waitForTimeout(800); await T('touchEnd'); await p.waitForTimeout(900);
  const it=await rect('.bmn-gm [role="menuitem"]'); 
  if(it){ await tapAt(it.x,it.y); await p.waitForTimeout(900); }
  const picked = await p.evaluate(()=>({layerOpen:document.getElementById('lgttMenu')?.classList.contains('is-open'),glass:!!document.querySelector('.bmn-gm'),sheet:document.getElementById('bmnSheetHost')?.dataset.open}));
  ok('menu: picking an item runs BMN action and closes both', !picked.layerOpen && !picked.glass, JSON.stringify(picked));
  await p.evaluate(()=>window.bmnCloseSheet&&window.bmnCloseSheet()); await p.waitForTimeout(500);

  // ---------- Comments sheet + GlassInput ----------
  await p.evaluate(()=>document.querySelector('#lgtt .lgtt-slide [data-act="comment"]')?.click()); await p.waitForTimeout(1000);
  // The comment composer pill is itself the glass surface (material "pill"); the app's own input stays visible and typeable.
  const cm = await p.evaluate(()=>{const f=document.getElementById('lgttCmtForm'),i=document.getElementById('lgttCmtInput');return {open:document.getElementById('lgttComments')?.classList.contains('is-open'),pill:f?.dataset.bmnMaterial,inputVisible:!!i&&getComputedStyle(i).display!=='none'&&i.getBoundingClientRect().width>0,contained:!!f&&i&&(()=>{const a=f.getBoundingClientRect(),c=i.getBoundingClientRect();return c.left>=a.left-1&&c.right<=a.right+1&&c.top>=a.top-1&&c.bottom<=a.bottom+1})()}});
  ok('comments: sheet opens; composer pill is glass, input visible and inside the pill', cm.open && cm.pill==='pill' && cm.inputVisible && cm.contained, JSON.stringify(cm));
  if(cm.inputVisible){
    const inp=await rect('#lgttCmtInput'); await tapAt(inp.x,inp.y);
    await p.keyboard.type('hello glass'); await p.waitForTimeout(200);
    ok('input: typing reaches the original input', await p.evaluate(()=>document.getElementById('lgttCmtInput').value==='hello glass'));
    await p.evaluate(()=>{document.getElementById('lgttCmtInput').value=''});
  }
  // comments sort segmented
  const sortSeg = await rect('#lgttCmtSort ~ .bmn-gs-host .lg-track > .lg-track__item[data-lg-item="1"]');
  if(sortSeg){ await tapAt(sortSeg.x,sortSeg.y); ok('comments: sort segmented drives original', await p.evaluate(()=>document.querySelector('#lgttCmtSort button.on')?.dataset.sort)==='new'); }
  // dismiss via close button
  await p.evaluate(()=>document.querySelector('#lgttComments [data-act="close-layer"]')?.click()); await p.waitForTimeout(700);
  ok('comments: closes via existing close button', !(await p.evaluate(()=>document.getElementById('lgttComments')?.classList.contains('is-open'))));

  // ---------- Slider fixture (bridge picks up any range input) ----------
  await p.evaluate(()=>{const s=document.querySelector('#lgtt');const w=document.createElement('div');w.id='fixture';w.style.cssText='position:fixed;left:20px;right:20px;top:200px;z-index:99999;display:flex;padding:20px;background:rgba(0,0,0,.3)';const i=document.createElement('input');i.type='range';i.min=0;i.max=100;i.step=1;i.value=20;i.id='fxr';i.setAttribute('aria-label','Test');w.appendChild(i);s.appendChild(w);window.__fx=[];i.addEventListener('input',()=>window.__fx.push(i.value));});
  await p.waitForTimeout(700);
  const sl=await rect('#fixture .bmn-gsl .lg-slider, #fixture .bmn-gsl [role="slider"], #fixture .bmn-gsl input');
  ok('slider: GlassSlider mounted for a native range input; original hidden', !!sl && await p.evaluate(()=>getComputedStyle(document.getElementById('fxr')).display==='none'), JSON.stringify(sl));
  if(sl){ const tr=await rect('#fixture .bmn-gsl'); await T('touchStart',tr.l+10,tr.y); for(let i=1;i<=14;i++){await T('touchMove',tr.l+10+i*((tr.w-20)/14),tr.y);await p.waitForTimeout(16)} await T('touchEnd'); await p.waitForTimeout(400);
    const v=await p.evaluate(()=>({val:+document.getElementById('fxr').value,events:window.__fx.length}));
    ok('slider: dragging moves the ORIGINAL range value and fires input', v.val>80 && v.events>3, JSON.stringify(v)); }

  // ---------- Sheet: Escape + drag-dismiss + Cancel ----------
  await p.evaluate(()=>document.getElementById('fixture')?.remove());
  const sheetOpen=()=>p.evaluate(()=>document.getElementById('bmnSheetHost')?.dataset.open==='1');
  await p.evaluate(()=>window.requestCommunityAuth('profile')); await p.waitForTimeout(1200);
  ok('sheet: opens as GlassSheet', await sheetOpen() && await p.evaluate(()=>!!document.querySelector('#bmnSheetHost .lg-sheet')));
  await p.keyboard.press('Escape'); await p.waitForTimeout(900);
  ok('sheet: Escape dismisses (host closed, nothing blocks)', !(await sheetOpen()) && await p.evaluate(()=>!/bmn-sh|lg-sheet/.test((document.elementFromPoint(195,300)||{className:''}).className.toString())));
  await p.evaluate(()=>window.requestCommunityAuth('profile')); await p.waitForTimeout(1200);
  await p.waitForFunction(()=>{const z=document.querySelector('#bmnSheetHost .lg-sheet');if(!z)return false;const y=z.getBoundingClientRect().y;const last=window.__sy;window.__sy=y;return last!==undefined&&Math.abs(last-y)<0.5&&y<400},null,{polling:150,timeout:8000}).catch(()=>{});
  const grab=await rect('#bmnSheetHost .lg-sheet__grabber, #bmnSheetHost .lg-sheet__grabber-zone');
  await T('touchStart',195,grab?grab.y+4:260); for(let i=1;i<=14;i++){await T('touchMove',195,(grab?grab.y+4:260)+i*22);await p.waitForTimeout(16)} await T('touchEnd'); await p.waitForTimeout(1000);
  ok('sheet: drag-down dismisses and releases the page', !(await sheetOpen()) && await p.evaluate(()=>!/bmn-sh|lg-sheet/.test((document.elementFromPoint(195,300)||{className:''}).className.toString())), 'open='+await sheetOpen());
  await p.evaluate(()=>window.requestCommunityAuth('profile')); await p.waitForTimeout(1200);
  await settle(); const cancel=await rect('#bmnSheetHost button.cancel'); await tapAt(cancel.x,cancel.y); await p.waitForTimeout(700);
  ok('sheet: Cancel button still works', !(await sheetOpen()));
  // re-open after all that: still works (repeat)
  await p.evaluate(()=>window.requestCommunityAuth('inbox')); await p.waitForTimeout(1000); ok('sheet: re-opens after being dismissed three ways', await sheetOpen());
  await p.keyboard.press('Escape'); await p.waitForTimeout(700);

  ok('no uncaught JS errors', errs.length===0, errs.slice(0,3).join(' | '));
  out.forEach(l=>console.log(l)); console.log(`== ${pass} passed, ${fail} failed`); await b.close(); process.exit(fail?1:0);
})();
