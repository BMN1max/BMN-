// Dock interaction suite. usage: node dock_test.js on|off [touch|mouse]
const { chromium, devices } = require('playwright');
const mode = process.argv[2] || 'on';
const input = process.argv[3] || 'touch';
const ORDER = ['feed','discover','create','inbox','profile'];
let pass=0, fail=0; const results=[];
const ok=(name,cond,extra='')=>{ (cond?pass++:fail++); results.push((cond?'PASS ':'FAIL ')+name+(extra?'  — '+extra:'')); };
(async()=>{
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPhone 14'] });
  const p = await ctx.newPage();
  const cdp = await ctx.newCDPSession(p);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  await p.route(/^https?:\/\/(?!localhost)/, r=>r.abort());
  await p.goto('file://'+require('path').resolve(__dirname,'../../index.html')+'?glass='+mode,{waitUntil:'load'});
  const t0 = Date.now();
  await p.waitForFunction(()=>{const e=document.querySelector('#lgttDock .bmn-gn .lg-track__item')||document.querySelector('#lgttDock .lgtt-dk');return e&&e.getBoundingClientRect().width>10},null,{timeout:15000});
  await p.waitForTimeout(600);
  const glass = await p.evaluate(()=>document.documentElement.classList.contains('bmn-glass-on'));
  ok('engine state matches ?glass='+mode, glass===(mode==='on'));
  const center = (name)=>p.evaluate(({name,order,glass})=>{
    const i=order.indexOf(name);
    const e = glass ? document.querySelector('#lgttDock .bmn-gn > .lg-track > [data-lg-item="'+i+'"]') : document.querySelector('#lgttDock [data-dock="'+name+'"]');
    const r=e.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2};
  },{name,order:ORDER,glass});
  const touch = (type,x,y)=>cdp.send('Input.dispatchTouchEvent',{type,touchPoints:type==='touchEnd'?[]:[{x,y,id:1}]});
  const tap = async(name)=>{const c=await center(name); if(input==='touch'){await touch('touchStart',c.x,c.y);await p.waitForTimeout(40);await touch('touchEnd');} else {await p.mouse.click(c.x,c.y)} await p.waitForTimeout(450)};
  const drag = async(f,t,hold=0)=>{const a=await center(f),c=await center(t);
    if(input==='touch'){await touch('touchStart',a.x,a.y);for(let i=1;i<=14;i++){await touch('touchMove',a.x+(c.x-a.x)*i/14,a.y);await p.waitForTimeout(16)}if(hold)await p.waitForTimeout(hold);await touch('touchEnd')}
    else{await p.mouse.move(a.x,a.y);await p.mouse.down();for(let i=1;i<=14;i++){await p.mouse.move(a.x+(c.x-a.x)*i/14,a.y);await p.waitForTimeout(16)}if(hold)await p.waitForTimeout(hold);await p.mouse.up()}
    await p.waitForTimeout(600)};
  const st = ()=>p.evaluate(()=>{const h=document.getElementById('bmnSheetHost');const lens=document.querySelector('.bmn-gn > .lg-track > .lg-track__select, .bmn-gn .lg-track__lens');
    return {sheet:!!(h&&h.dataset.open==='1'),active:[...document.querySelectorAll('#lgttDock .lgtt-dk.on')].map(b=>b.dataset.dock).join(),
      sel:[...document.querySelectorAll('#lgttDock .bmn-gn > .lg-track > .lg-track__item')].findIndex(e=>e.getAttribute('aria-selected')==='true'),
      blocker:(()=>{const e=document.elementFromPoint(195,300);return e?e.className.toString().slice(0,30):null})()}});
  const dismiss = async()=>{ // dismiss by tapping the scrim like a user would
    await p.waitForTimeout(450); await p.mouse.click(195,60); await p.waitForTimeout(350); };
  const toastSeen = ()=>p.evaluate(()=>!!document.querySelector('.lgtt-toast'));

  let s;
  // 1 tap navigation
  await tap('discover'); s=await st(); ok('tap Friends -> discover active', s.active==='discover' && !s.sheet, JSON.stringify(s));
  if(glass) ok('glass lens follows (selected index 1)', s.sel===1, 'sel='+s.sel);
  await tap('feed'); s=await st(); ok('tap Home -> feed active', s.active==='feed' && !s.sheet);
  // 2 gated tap -> sheet (existing behaviour preserved), dismiss, nothing blocks
  await tap('inbox'); s=await st(); ok('tap Inbox as guest still opens existing sign-in sheet', s.sheet===true, JSON.stringify(s));
  if(glass) ok('lens returns to real active tab (Home) while guest is gated', s.sel===0, 'sel='+s.sel);
  await dismiss(); s=await st(); ok('sheet dismisses via scrim tap', s.sheet===false, JSON.stringify(s));
  ok('no invisible overlay after dismiss (point hits app, not sheet host)', !/bmn-sh/.test(s.blocker||''), s.blocker);
  await tap('discover'); s=await st(); ok('tap after dismiss still navigates', s.active==='discover' && !s.sheet);
  await tap('feed');
  // 3 drag to gated tab: no sheet
  await drag('feed','inbox'); s=await st();
  ok('DRAG Home->Inbox (guest) does NOT open a sheet', s.sheet===false, JSON.stringify(s));
  ok('lens/active stays on Home after refused drag', s.active==='feed' && (!glass||s.sel===0), JSON.stringify(s));
  ok('refused drag explains itself (toast)', await toastSeen());
  // 4 drag then tap
  await tap('discover'); s=await st(); ok('drag -> tap works (Friends)', s.active==='discover' && !s.sheet, JSON.stringify(s));
  // 5 drag to ungated
  await drag('discover','feed'); s=await st(); ok('drag Friends->Home navigates Home', s.active==='feed' && !s.sheet, JSON.stringify(s));
  await drag('feed','discover'); s=await st(); ok('drag Home->Friends navigates Friends', s.active==='discover' && !s.sheet, JSON.stringify(s));
  // 6 drag across and back, ends on same tab
  await drag('discover','profile'); s=await st(); ok('DRAG Friends->Profile (guest) no sheet', s.sheet===false && s.active==='discover', JSON.stringify(s));
  await drag('discover','create'); s=await st(); ok('DRAG Friends->Create (guest) no sheet', s.sheet===false && s.active==='discover', JSON.stringify(s));
  // 7 repeated taps
  for(let i=0;i<6;i++){await tap(i%2?'feed':'discover')} s=await st(); ok('6 rapid alternating taps end consistent (last tap = Home)', s.active==='feed' && !s.sheet && (!glass||s.sel===0), JSON.stringify(s));
  // 8 tap Create as guest -> existing sign-in sheet; lens returns
  await tap('create'); s=await st(); ok('tap Create as guest opens existing sign-in sheet', s.sheet===true, JSON.stringify(s)); if(glass) ok('lens springs back to the real tab after Create (Home)', s.sel===0, 'sel='+s.sel);
  await dismiss(); s=await st(); ok('dismiss again', !s.sheet, JSON.stringify(s));
  // 9 vertical gesture over dock must not navigate or open sheet
  { const c=await center('feed'); if(input==='touch'){await touch('touchStart',c.x,c.y);for(let i=1;i<=10;i++){await touch('touchMove',c.x,c.y-i*12);await p.waitForTimeout(16)}await touch('touchEnd')} else {await p.mouse.move(c.x,c.y);await p.mouse.down();for(let i=1;i<=10;i++){await p.mouse.move(c.x,c.y-i*12);await p.waitForTimeout(16)}await p.mouse.up()}
    await p.waitForTimeout(500); s=await st(); ok('vertical swipe on dock: no sheet', s.sheet===false, JSON.stringify(s)); }
  // 10 (timer test runs on a fresh page below)
  ok('no uncaught JS errors', errs.length===0, errs.slice(0,3).join(' | '));
  // ---- fresh page: the automatic install offer is a timer; it must wait for an idle user ----
  {
    const p2 = await ctx.newPage(); const cdp2 = await ctx.newCDPSession(p2);
    await p2.route(/^https?:\/\/(?!localhost)/, r=>r.abort());
    await p2.goto('file://'+require('path').resolve(__dirname,'../../index.html')+'?glass='+mode,{waitUntil:'load'});
    await p2.waitForFunction(()=>{const e=document.querySelector('#lgttDock .bmn-gn .lg-track__item')||document.querySelector('#lgttDock .lgtt-dk');return e&&e.getBoundingClientRect().width>10},null,{timeout:15000});
    const c = await p2.evaluate((glass)=>{const e=glass?document.querySelector('#lgttDock .bmn-gn > .lg-track > [data-lg-item="1"]'):document.querySelector('#lgttDock [data-dock="discover"]');const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}},glass);
    const open=()=>p2.evaluate(()=>{const h=document.getElementById('bmnSheetHost');return !!(h&&h.dataset.open==='1')});
    await cdp2.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:c.x,y:c.y,id:1}]});   // finger down BEFORE the 5s offer
    await p2.waitForTimeout(8500);                                                                         // held across the deadline
    ok('install offer does NOT open while a finger is down (held 8.5s across the 5s timer)', (await open())===false);
    await cdp2.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    await p2.waitForTimeout(1200); ok('install offer waits after release (<2.5s since touch)', (await open())===false);
    await p2.waitForTimeout(4500); ok('install offer appears once the user is idle', (await open())===true);
    await p2.waitForTimeout(450); await p2.mouse.click(195,60); await p2.waitForTimeout(400); ok('offer dismissed by scrim tap; no blocking overlay', (await open())===false && !(await p2.evaluate(()=>/bmn-sh/.test((document.elementFromPoint(195,300)||{className:''}).className.toString()))));
    await p2.close();
  }
  console.log('ENGINE', mode.toUpperCase(), 'INPUT', input); results.forEach(r=>console.log(r)); console.log(`== ${pass} passed, ${fail} failed`);
  await b.close(); process.exit(fail?1:0);
})();
