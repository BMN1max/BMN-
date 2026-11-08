const { chromium, devices } = require('playwright');
(async()=>{
  const b = await chromium.launch();
  for (const [mode,extra] of [['off',{}],['on',{}],['on',{reducedMotion:'reduce'}],['on',{reducedMotion:'reduce',forcedColors:'none'}]]) {
    const ctx = await b.newContext({ ...devices['iPhone 14'], ...extra }); const p = await ctx.newPage(); const errs=[]; p.on('pageerror',e=>errs.push(e.message));
    await p.route(/^https?:\/\/(?!localhost)/, r=>r.abort());
    await p.goto('file://'+require('path').resolve(__dirname,'../index.html')+'?glass='+mode,{waitUntil:'load'}); await p.waitForTimeout(2500);
    const r=await p.evaluate(()=>({cls:document.documentElement.classList.contains('bmn-glass-on'),glassNodes:document.querySelectorAll('[class*="bmn-g"],.lg-glass,.lg-track').length,hosts:document.querySelectorAll('.bmn-gs-host,.bmn-gn,.bmn-gw-slot').length,dockVisible:(e=>!!e&&e.getBoundingClientRect().height>10)(document.querySelector('#lgttDock')),filters:document.querySelectorAll('svg filter feTurbulence').length}));
    console.log(mode,JSON.stringify(extra),JSON.stringify(r),'errors:',errs.length); await ctx.close();
  }
  await b.close();
})();
