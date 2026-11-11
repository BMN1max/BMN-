// Applies the unified-glass changes to the SHIPPED bundle (../bmn-glass/bmn-glass.js + .css).
//
// Why this exists: bmn-glass.js bundles @zakisheriff/liquid-glass, and that package was not
// reachable when this change was made (no registry access, library source not in the repo), so
// `npm run build` could not be run. src/ holds the real change (Surfaces.tsx, entry.tsx, glass.css);
// this script performs the same change on the minified output, anchored on exact strings and
// failing loudly if any anchor is missing or ambiguous.
//
//   node patch-bundle.mjs            patch (refuses to patch twice)
//
// After a normal rebuild (npm install && npm run build) run only the library patch:
//   node patch-bundle.mjs --library-only
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const jsPath = path.join(here, '../bmn-glass/bmn-glass.js');
const cssPath = path.join(here, '../bmn-glass/bmn-glass.css');
const libraryOnly = process.argv.includes('--library-only');

let js = fs.readFileSync(jsPath, 'utf8');
let css = fs.readFileSync(cssPath, 'utf8');

function swap(label, from, to) {
  const n = js.split(from).length - 1;
  if (n !== 1) throw new Error(`[${label}] anchor found ${n} times (expected exactly 1). Bundle differs from what this patch was written for.`);
  js = js.replace(from, () => to);
  console.log('patched:', label);
}

if (js.includes('BsW=new Set')) {
  console.log('bundle already contains the unified surface layer; nothing to do for JS.');
} else {
  // 1. Library quality heuristic. Was: <=4 cores OR <=4 GB means "low", which switches the surface
  //    refraction OFF (html[data-lg-quality=low] [data-lg-refract=surface]). That caught most mid-range
  //    phones and every 4-core device. Now only genuinely weak hardware starts low; the library's own
  //    frame-time governor still drops to low if real frames are slow.
  swap(
    'quality heuristic',
    'typeof t.deviceMemory=="number"&&t.deviceMemory<=4||typeof t.hardwareConcurrency=="number"&&t.hardwareConcurrency<=4?"low":"high"',
    'typeof t.deviceMemory=="number"&&t.deviceMemory<=2||typeof t.hardwareConcurrency=="number"&&t.hardwareConcurrency<=2?"low":"high"',
  );

  if (!libraryOnly) {
    // 1b. Input bridge fed on its own output: the search selector also matched the <input> GlassInput
    //     renders, so every DOM change wrapped the glass field in another glass field (158 nested on load).
    swap('input bridge recursion', 'for(let e of Re(t)){if(e.dataset.bmnIn)continue;e.dataset.bmnIn="1"', 'for(let e of Re(t)){if(e.dataset.bmnIn||e.closest(".bmn-gi-host"))continue;e.dataset.bmnIn="1"');

    // 2. Surfaces: new families, tone, one persistent root, reconcile on change.
    const start = js.indexOf('Hy=[{selector:"#lgtt .lgtt-btn.lgtt-round"');
    const endMarker = 'e.length&&He(t,(0,Ya.jsx)(Ry,{items:e}),"bmn-surfaces")}';
    const end = js.indexOf(endMarker);
    if (start < 0 || end < start) throw new Error('[surfaces] anchors not found');
    const old = js.slice(start, end + endMarker.length);
    if (old.length > 1500) throw new Error('[surfaces] unexpectedly large region');
    const next =
      'Hy=[' +
      '{selector:"#lgtt .lgtt-btn.lgtt-round",shape:{kind:"surface",bezel:12,thickness:22,strength:1.15,ior:1.5},press:{},tag:"button",tone:"auto"},' +
      '{selector:".bmn-quick-actions button",shape:{kind:"surface",bezel:14,thickness:22,strength:1.15,ior:1.5},press:{},tag:"quick",tone:"dark"},' +
      '{selector:".bmn-speed-hold",shape:{kind:"surface",bezel:16,thickness:24,strength:1,ior:1.5},press:!1,tag:"speed",tone:"dark"},' +
      '{selector:"#lgtt aside.lgtt-sheet",shape:{kind:"surface",bezel:24,thickness:30,strength:.8},press:!1,tag:"sheet",tone:"auto"},' +
      '{selector:"#lgtt .lgtt-modal-card",shape:{kind:"surface",bezel:20,thickness:26,strength:.9},press:!1,tag:"card",tone:"auto"}],' +
      'BsS={items:[],active:new Set,next:0,listeners:new Set,mounted:!1},' +
      'BsT=t=>{let e=getComputedStyle(t).color.match(/[0-9.]+/g)||[],l=(.2126*+e[0]+.7152*+e[1]+.0722*+e[2])/255;return l>.6?"dark":"light"},' +
      'BsW=new Set,BsO=null,BsV=t=>{if(BsW.add(t),!BsO){let e=0;BsO=new MutationObserver(()=>{e||(e=requestAnimationFrame(()=>{e=0,BsW.forEach(l=>l())}))}),BsO.observe(document.body,{attributes:!0,attributeFilter:["class"]}),BsO.observe(document.documentElement,{attributes:!0,attributeFilter:["data-bmn-theme"]});let l=document.getElementById("lgttStage");l&&BsO.observe(l,{attributes:!0,attributeFilter:["data-view","class"]})}return()=>{BsW.delete(t)}},' +
      'Ny=({el:t,family:e})=>{let[l]=no.useState(()=>({current:t}));return no.useEffect(()=>{t.classList.add("lg-glass","bmn-surface"),t.dataset.bmnMaterial=e.tag;let n=()=>{};if(e.tone==="dark")t.dataset.bmnTone="dark";else{let a=()=>{let s=BsT(t);t.dataset.bmnTone!==s&&(t.dataset.bmnTone=s)};a();let o=BsV(a),i=e.tag==="sheet"||e.tag==="card"?new MutationObserver(a):null;i?.observe(t,{attributes:!0,attributeFilter:["class"]}),n=()=>{o(),i?.disconnect()}}return()=>{n(),t.classList.remove("lg-glass","bmn-surface"),delete t.dataset.bmnMaterial,delete t.dataset.bmnTone}},[t,e]),Kt(l,e.shape,!0),ml(l,e.press===!1?{disabled:!0}:e.press||{}),null},' +
      'Ry=()=>{let[,t]=no.useState(0);return no.useEffect(()=>{let e=()=>t(l=>l+1);return BsS.listeners.add(e),()=>{BsS.listeners.delete(e)}},[]),(0,Ya.jsx)(Ya.Fragment,{children:BsS.items.map(({id:e,el:l,family:n})=>(0,Ya.jsx)(Ny,{el:l,family:n},e))})};' +
      'function Xp(t){let e=!1;BsS.items=BsS.items.filter(l=>l.el.isConnected?!0:(BsS.active.delete(l.el),e=!0,!1));' +
      'for(let l of Hy)for(let n of Re(l.selector))BsS.active.has(n)||(BsS.active.add(n),BsS.items.push({id:++BsS.next,el:n,family:l}),e=!0);' +
      'BsS.mounted?e&&BsS.listeners.forEach(l=>l()):(BsS.mounted=!0,He(t,(0,Ya.jsx)(Ry,{}),"bmn-surfaces"))}';
    js = js.slice(0, start) + next + js.slice(end + endMarker.length);
    console.log('patched: surfaces (families, tone, persistent root, reconcile)');

    // 3. Entry: re-bridge surfaces when #lgtt changes, and when Quick Glass nodes appear anywhere.
    swap(
      'entry observer',
      'new MutationObserver(()=>{n||(n=requestAnimationFrame(()=>{n=0,eo(),af(),uf()}))}).observe(l,{childList:!0,subtree:!0})}),qp()',
      'new MutationObserver(()=>{n||(n=requestAnimationFrame(()=>{n=0,eo(),af(),uf(),Xp(l)}))}).observe(l,{childList:!0,subtree:!0});' +
        'let BsQ=".bmn-quick-actions, .bmn-speed-hold",BsR=0;new MutationObserver(r=>{if(BsR)return;r.some(i=>Array.from(i.addedNodes).some(o=>o.nodeType===1&&(o.matches(BsQ)||!!o.querySelector(BsQ))))&&(BsR=requestAnimationFrame(()=>{BsR=0,Xp(l)}))}).observe(document.body,{childList:!0,subtree:!0})}),qp()',
    );
  }
  fs.writeFileSync(jsPath, js);
}

if (!libraryOnly) {
  if (css.includes('Unified material: the Dock')) {
    console.log('bundle CSS already contains the unified material; nothing to do for CSS.');
  } else {
    const src = fs.readFileSync(path.join(here, 'src/glass.css'), 'utf8');
    const i = src.indexOf('/* ======================================================================\n * Unified material');
    if (i < 0) throw new Error('[css] unified material block not found in src/glass.css');
    fs.writeFileSync(cssPath, css.replace(/\s*$/, '\n') + src.slice(i));
    console.log('patched: bmn-glass.css (unified material appended)');
  }
}
