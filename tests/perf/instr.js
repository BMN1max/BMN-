/* BMN perf instrumentation. Injected by tests/perf/baseline.js via addInitScript BEFORE page scripts; wraps timers, rAF, listeners, observers, supabase channels. Measurement only; never loaded by the site. */
(function(){
  if (window.__R) return;
  const R = window.__R = { timers:[], timeouts:0, raf:{}, rafTotal:0, lis:{add:0,rem:0}, mo:[], io:0, ro:0, ch:[], long:[], cls:0, fires:{} };
  const site = () => { const lim=Error.stackTraceLimit; Error.stackTraceLimit=40; const s=(new Error()).stack.split('\n'); Error.stackTraceLimit=lim; for (let i=1;i<s.length;i++){ if(/127\.0\.0\.1/.test(s[i])) return s[i].trim().replace(/^at /,'').replace(/https?:\/\/[^/]+\//,'').slice(0,120); } return 'native/anon'; };
  const SI = window.setInterval, ST = window.setTimeout;
  window.setInterval = function(fn, d, ...a){ const e={d:d, site:site(), fires:0, alive:true}; R.timers.push(e);
    const w = typeof fn==='function' ? function(){ e.fires++; return fn.apply(this, arguments); } : fn;
    const id = SI.call(this, w, d, ...a); e.id=id; return id; };
  const CI = window.clearInterval; window.clearInterval = function(id){ R.timers.forEach(t=>{ if(t.id===id) t.alive=false; }); return CI.call(this,id); };
  window.setTimeout = function(fn, d, ...a){ R.timeouts++; return ST.call(this, fn, d, ...a); };
  const RAF = window.requestAnimationFrame;
  window.requestAnimationFrame = function(cb){ const k=site(); R.rafTotal++; R.raf[k]=(R.raf[k]||0)+1; return RAF.call(this, cb); };
  const AEL = EventTarget.prototype.addEventListener, REL = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener = function(){ R.lis.add++; return AEL.apply(this, arguments); };
  EventTarget.prototype.removeEventListener = function(){ R.lis.rem++; return REL.apply(this, arguments); };
  const MO = window.MutationObserver;
  window.MutationObserver = class extends MO { constructor(cb){ const e={site:site(), fires:0, targets:[]}; R.mo.push(e); super(function(){ e.fires++; return cb.apply(this, arguments); }); this.__e=e; }
    observe(t,o){ this.__e.targets.push((t===document.documentElement?'html':t===document.body?'body':t===document?'document':(t.id?('#'+t.id):(t.tagName||'?')))+(o&&o.subtree?'+subtree':'')); return super.observe(t,o); } };
  const IO = window.IntersectionObserver; window.IntersectionObserver = class extends IO { constructor(){ R.io++; super(...arguments); } };
  const RO = window.ResizeObserver; if (RO) window.ResizeObserver = class extends RO { constructor(){ R.ro++; super(...arguments); } };
  try { new PerformanceObserver(l=>l.getEntries().forEach(e=>R.long.push(Math.round(e.duration)))).observe({type:'longtask',buffered:true}); } catch(e){}
  try { new PerformanceObserver(l=>l.getEntries().forEach(e=>{ if(!e.hadRecentInput) R.cls+=e.value; })).observe({type:'layout-shift',buffered:true}); } catch(e){}
  // wrap supabase client channel() to record realtime subscriptions
  let sup; Object.defineProperty(window,'supabase',{configurable:true,get(){return sup},set(v){ sup=v; if(v&&v.createClient){ const cc=v.createClient; v.createClient=function(){ const c=cc.apply(this,arguments); if(c&&c.channel&&!c.__w){ c.__w=1; const ch=c.channel.bind(c), rm=c.removeChannel.bind(c); c.channel=function(n){ R.ch.push({n:n,site:site(),t:Math.round(performance.now()),removed:false}); return ch(n); }; c.removeChannel=function(x){ R.ch.forEach(e=>{ if(x&&x.name===e.n) e.removed=true; }); return rm(x); }; } return c; }; } }});
})();
