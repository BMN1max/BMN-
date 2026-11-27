/* BMN performance baseline harness (measurement only; NOT part of the site, no runtime effect).
   Emulates 3 profiles (Desktop 1280x800 cpu x1, Pixel 7 cpu x4, iPhone 14 cpu x2) in headless Chromium with the repo's stand-in Supabase client
   (tests/mockclient.js), blocks every non-local network request, then records: time to dock, boot long tasks, idle main-thread busy %,
   style recalcs/s, timers/observers/listeners/backdrop-filter counts. It is an EMULATION: no real GPU, no real device, frame rates are not meaningful.
   Run:  python3 -m http.server 8124 --bind 127.0.0.1   (from the repo root; use 127.0.0.1 - instr.js attributes call sites by that host)
         node tests/perf/baseline.js      env: BASE (page URL), QS (e.g. ?perf=full pins the governor), OUT (json file), RUNS (default 3), WARM (ms before idle window; 45000 = steady state)
   Needs `playwright`. Compare two trees by serving each on its own port and running with the same env. */
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const T = path.join(__dirname, '..') + path.sep; // tests/
const mock = fs.readFileSync(T+'mockclient.js','utf8');
const instr = fs.readFileSync(path.join(__dirname,'instr.js'),'utf8');
const U='aaaaaaaa-0000-4000-8000-000000000001';
const PROFILES = {
  desktop:{dev:{viewport:{width:1280,height:800}},cpu:1},
  android:{dev:devices['Pixel 7'],cpu:4},
  iphone:{dev:devices['iPhone 14'],cpu:2},
};
const BASE = process.env.BASE || 'http://127.0.0.1:8124/index.html';
const QS = process.env.QS || '';
const OUT = process.env.OUT || 'baseline.json';
const RUNS = +(process.env.RUNS||3);
const IDLE = 6000;
const m = async (cdp)=>{ const {metrics}=await cdp.send('Performance.getMetrics'); const o={}; metrics.forEach(x=>o[x.name]=x.value); return o; };
(async()=>{
  const b = await chromium.launch();
  const all = {};
  for (const [name,cfg] of Object.entries(PROFILES)) {
    all[name]=[];
    for (let r=0;r<RUNS;r++){
      const ctx = await b.newContext({...cfg.dev});
      await ctx.addInitScript('window.__MOCK_UID='+JSON.stringify(U)+';try{localStorage.setItem("bmn-onboarded-'+U+'","1");localStorage.setItem("bmn-install-dismissed",String(Date.now()+99999999999))}catch(e){}');
      await ctx.addInitScript(instr);
      await ctx.addInitScript(mock);
      const p = await ctx.newPage(); const errs=[]; let reqs=0, bytes=0, media=0;
      p.on('pageerror', e=>errs.push(e.message.slice(0,100)+' @ '+String(e.stack).split('\n').slice(1,3).join(' | ').replace(/https?:\/\/[^/]+\//g,'')));
      p.on('request', q=>{ reqs++; if(q.resourceType()==='media') media++; });
      await p.route(/^https?:\/\/(?!localhost|127\.0\.0\.1)/, rt=>rt.abort());
      const cdp = await ctx.newCDPSession(p); await cdp.send('Performance.enable');
      if (cfg.cpu>1) await cdp.send('Emulation.setCPUThrottlingRate',{rate:cfg.cpu});
      const t0=Date.now();
      await p.goto(BASE+QS,{waitUntil:'load'});
      await p.waitForFunction(()=>document.querySelector('#lgttDock'),{timeout:30000}).catch(()=>{});
      const tDock = Date.now()-t0;
      const boot = await m(cdp);
      const bootLong = await p.evaluate(()=>window.__R.long.slice());
      await p.waitForTimeout(+(process.env.WARM||1500));
      // idle window
      const rBefore = await p.evaluate(()=>JSON.parse(JSON.stringify({raf:window.__R.raf,rafTotal:window.__R.rafTotal,fires:window.__R.timers.map(t=>t.fires),mo:window.__R.mo.map(x=>x.fires),add:window.__R.lis.add})));
      const m1 = await m(cdp);
      await p.waitForTimeout(IDLE);
      const m2 = await m(cdp);
      const rAfter = await p.evaluate(()=>JSON.parse(JSON.stringify({raf:window.__R.raf,rafTotal:window.__R.rafTotal,fires:window.__R.timers.map(t=>t.fires),mo:window.__R.mo.map(x=>x.fires),add:window.__R.lis.add})));
      const state = await p.evaluate(()=>{
        const R=window.__R;
        let bf=0, bfVis=0, lg=0;
        document.querySelectorAll('*').forEach(e=>{ const cs=getComputedStyle(e); const f=cs.backdropFilter||cs.webkitBackdropFilter; if(f&&f!=='none'){ bf++; const r=e.getBoundingClientRect(); if(r.width>0&&r.height>0&&cs.visibility!=='hidden'&&cs.display!=='none'&&r.bottom>0&&r.top<innerHeight&&r.right>0&&r.left<innerWidth) bfVis++; } if(e.classList.contains('lg-glass')) lg++; });
        const v=[...document.querySelectorAll('video')].map(x=>({src:!!x.getAttribute('src'),paused:x.paused,rs:x.readyState,pre:x.preload}));
        return { nodes:document.getElementsByTagName('*').length, bfAll:bf, bfVisible:bfVis, lgGlass:lg, canvases:document.querySelectorAll('canvas').length, videos:v,
          timersTotal:R.timers.length, timersAlive:R.timers.filter(t=>t.alive).length, timeouts:R.timeouts, io:R.io, ro:R.ro, moCount:R.mo.length,
          moBodyHtmlSubtree:R.mo.filter(x=>x.targets.some(t=>/^(html|body|document)\+subtree/.test(t))).length,
          listeners:R.lis, channels:R.ch.map(c=>({n:c.n,removed:c.removed})), cls:+R.cls.toFixed(4), longAll:R.long.slice(), perf:document.documentElement.getAttribute('data-bmn-perf') }; });
      const d=(k)=>m2[k]-m1[k];
      const secs=(m2.Timestamp-m1.Timestamp);
      const rafDelta = rAfter.rafTotal-rBefore.rafTotal;
      const rafSites = Object.entries(rAfter.raf).map(([k,v])=>[k,v-(rBefore.raf[k]||0)]).filter(x=>x[1]>0).sort((a,b)=>b[1]-a[1]).slice(0,6);
      const firesDelta = state && await p.evaluate(()=>window.__R.timers.map((t,i)=>({d:t.d,site:t.site,alive:t.alive,fires:t.fires})));
      const timerRates = firesDelta.map((t,i)=>({d:t.d,site:t.site,alive:t.alive,fires6s:t.fires-(rBefore.fires[i]||0)})).filter(t=>t.fires6s>0);
      const moFires = await p.evaluate(()=>window.__R.mo.map(x=>({site:x.site,targets:x.targets.join(','),fires:x.fires})));
      const moDelta = moFires.map((x,i)=>({...x,fires6s:x.fires-(rBefore.mo[i]||0)})).filter(x=>x.fires6s>0);
      const res = { tDockMs:tDock, errs, reqs, mediaReqs:media,
        boot:{ scriptS:+boot.ScriptDuration.toFixed(3), taskS:+boot.TaskDuration.toFixed(3), recalc:boot.RecalcStyleCount, layout:boot.LayoutCount, heapMB:+(boot.JSHeapUsedSize/1e6).toFixed(1), nodes:boot.Nodes, longTasksMs:bootLong, longSumMs:bootLong.reduce((a,b)=>a+b,0) },
        idle:{ secs:+secs.toFixed(2), busyPct:+(100*d('TaskDuration')/secs).toFixed(2), scriptPct:+(100*d('ScriptDuration')/secs).toFixed(2), recalcPerS:+(d('RecalcStyleCount')/secs).toFixed(1), layoutPerS:+(d('LayoutCount')/secs).toFixed(1), rafPerS:+(rafDelta/secs).toFixed(1), rafSites, timerRates, moDelta },
        state };
      all[name].push(res);
      console.log(name, 'run', r+1, 'busy%', res.idle.busyPct, 'raf/s', res.idle.rafPerS, 'recalc/s', res.idle.recalcPerS, 'errs', errs.length);
      await ctx.close();
    }
  }
  fs.writeFileSync(OUT, JSON.stringify(all,null,1));
  await b.close();
})();
