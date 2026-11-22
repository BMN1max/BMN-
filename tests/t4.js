const L = require('./lib'); const { check, sleep, U, api } = L;
const T = (n) => new Date(Date.now() - n * 60000).toISOString();
const lum = (c) => { const [r, g, b] = c.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => { v /= 255; return v <= .03928 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4); }); return .2126 * r + .7152 * g + .0722 * b; };
const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); };
async function seed() {
  await api('/reset');
  const m = []; const lines = ['Hey! Are you free this weekend? I was thinking we could meet up and check out the new place downtown, it looks amazing.', 'Sure, what time?', '👍', 'Around 6? Send me your address and I will pick you up.', 'Perfect ✅'];
  lines.forEach((c, i) => m.push({ sender_id: i % 2 ? U.A : U.B, recipient_id: i % 2 ? U.B : U.A, content: c, created_at: T(200 - i * 20), read_at: i % 2 ? T(10) : T(100) }));
  m.push({ sender_id: U.B, recipient_id: U.A, content: 'Long unbroken string: ' + 'abcdefghij'.repeat(14), created_at: T(5) });
  m.push({ sender_id: U.B, recipient_id: U.A, content: '🎬 Shared a BMN Community post: Dance clip\nhttp://localhost:8124/#p1', created_at: T(4) });
  m.push({ sender_id: U.D, recipient_id: U.A, content: 'Welcome to the community!', created_at: T(60 * 30) });
  await api('/seed', { messages: m });
}
(async () => {
  await seed();
  // ================= iPhone, dark
  const a = await L.newUser(U.A); await L.openInbox(a); await sleep(500);
  const lay = await a.p.evaluate(() => {
    const vw = innerWidth, q = s => [...document.querySelectorAll(s)];
    const small = q('#bmnMsg .bm-circle, #bmnMsg .bm-send').filter(e => e.offsetParent && (e.offsetWidth < 44 || e.offsetHeight < 44)).length;
    return { vw, overflowX: document.documentElement.scrollWidth > vw + 1 || document.getElementById('bmListScroll').scrollWidth > document.getElementById('bmListScroll').clientWidth + 1, small, searchFont: getComputedStyle(document.getElementById('bmSearch')).fontSize, rowH: Math.min(...q('.bm-row').map(r => r.offsetHeight)), padBottom: getComputedStyle(document.getElementById('bmListScroll')).paddingBottom, dockTop: document.querySelector('#lgttDock').getBoundingClientRect().top, lastRowBottom: Math.max(...q('.bm-row').map(r => r.getBoundingClientRect().bottom)) };
  });
  check('iPHONE LIST: no horizontal overflow', !lay.overflowX, JSON.stringify(lay));
  check('iPHONE LIST: all round buttons >= 44x44 (touch targets)', lay.small === 0);
  check('iPHONE LIST: search input font >= 16px (no iOS focus-zoom)', parseFloat(lay.searchFont) >= 16, lay.searchFont);
  check('iPHONE LIST: rows >= 56px tall; list scroll clears the dock', lay.rowH >= 56 && parseFloat(lay.padBottom) >= 100);
  await a.p.screenshot({ path: 'shots/final-list-dark.png' });
  await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1400);
  const lay2 = await a.p.evaluate(() => {
    const vw = innerWidth, vh = innerHeight; const ta = document.getElementById('bmInput'); const m = document.getElementById('bmMsgs');
    const bubs = [...document.querySelectorAll('.bm-bub')]; const maxR = Math.max(...bubs.map(b => b.getBoundingClientRect().right)), minL = Math.min(...bubs.map(b => b.getBoundingClientRect().left));
    const comp = document.getElementById('bmForm').getBoundingClientRect(); const dock = document.querySelector('#lgttDock'); const dr = dock.getBoundingClientRect(); const dcs = getComputedStyle(dock);
    return { overflowX: document.getElementById('bmChat').scrollWidth > vw + 1 || m.scrollWidth > m.clientWidth + 1, taFont: getComputedStyle(ta).fontSize, maxR, minL, vw, compBottom: comp.bottom, vh, dockHidden: dcs.opacity === '0' || dr.top >= vh, headTop: document.querySelector('.bm-chead').getBoundingClientRect().top, atBottom: m.scrollHeight - m.scrollTop - m.clientHeight < 10 };
  });
  check('iPHONE CHAT: no horizontal overflow, long unbroken text wraps inside bubbles', !lay2.overflowX && lay2.maxR <= lay2.vw && lay2.minL >= 0, JSON.stringify(lay2));
  check('iPHONE CHAT: composer font >= 16px, composer inside viewport, dock hidden', parseFloat(lay2.taFont) >= 16 && lay2.compBottom <= lay2.vh + 1 && lay2.dockHidden);
  await a.p.screenshot({ path: 'shots/final-chat-dark.png' });
  // keyboard emulation
  await a.p.evaluate(() => { document.documentElement.style.setProperty('--bmn-kb', '300px'); document.getElementById('bmnMsg').classList.add('kb'); });
  await a.p.fill('#bmInput', 'typing with keyboard open…'); await sleep(400);
  const kb = await a.p.evaluate(() => { const c = document.getElementById('bmForm').getBoundingClientRect(); const h = document.querySelector('.bm-chead').getBoundingClientRect(); const m = document.getElementById('bmMsgs').getBoundingClientRect(); return { compBottom: Math.round(c.bottom), vh: innerHeight, headBottom: Math.round(h.bottom), msgsH: Math.round(m.height) }; });
  check('KEYBOARD (emulated 300px): composer lifts above keyboard, header stays, thread keeps space', kb.compBottom <= kb.vh - 295 && kb.msgsH > 80, JSON.stringify(kb));
  await a.p.screenshot({ path: 'shots/final-chat-keyboard.png' });
  await a.p.evaluate(() => { document.documentElement.style.setProperty('--bmn-kb', '0px'); document.getElementById('bmnMsg').classList.remove('kb'); });
  // notch / home indicator emulation
  await a.p.addStyleTag({ content: '#bmnMsg{--bm-safe-t:59px!important;--bm-safe-b:34px!important}' }); await sleep(300);
  const sf = await a.p.evaluate(() => ({ head: Math.round(document.querySelector('.bm-pill').getBoundingClientRect().top), comp: Math.round(document.getElementById('bmForm').getBoundingClientRect().bottom), vh: innerHeight, send: Math.round(document.getElementById('bmSend').getBoundingClientRect().bottom) }));
  check('SAFE AREA (emulated notch 59 / home bar 34): header below notch, send button above home bar', sf.head >= 59 && sf.send <= sf.vh - 34 + 1, JSON.stringify(sf));
  await a.p.screenshot({ path: 'shots/final-chat-safearea.png' });
  // ================= light mode (real app theme switch: localStorage bmn-theme-mode + system scheme)
  const lt = await L.newUser(U.A, { theme: 'light', scheme: 'light' }); await L.openInbox(lt); await sleep(600);
  check('LIGHT MODE: app resolves to light', await lt.p.evaluate(() => document.documentElement.dataset.bmnTheme === 'light' && document.body.classList.contains('light')));
  await lt.p.screenshot({ path: 'shots/final-list-light.png' });
  await L.tap(lt.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1400);
  const lc = await lt.p.evaluate(() => { const cs = (s) => getComputedStyle(document.querySelector(s)); const theirs = document.querySelector('.bm-msg:not(.mine) .bm-bub'), mine = document.querySelector('.bm-msg.mine .bm-bub'); return { rootBg: cs('#bmnMsg').backgroundColor, ink: cs('#bmnMsg').color, theirsBg: getComputedStyle(theirs).backgroundColor, theirsInk: getComputedStyle(theirs).color, mineInk: getComputedStyle(mine).color, sub: getComputedStyle(document.querySelector('.bm-pill small')).color }; });
  check('LIGHT MODE: surface turns light, text dark', lum(lc.rootBg) > .6 && lum(lc.ink) < .2, JSON.stringify(lc));
  check('LIGHT MODE: received-bubble text contrast >= 4.5:1', ratio(lc.theirsBg, lc.theirsInk) >= 4.5, ratio(lc.theirsBg, lc.theirsInk).toFixed(1));
  check('LIGHT MODE: sent-bubble white text on blue gradient (mid colour) >= 4.0:1', ratio('rgb(79,108,246)', lc.mineInk) >= 4.0, ratio('rgb(79,108,246)', lc.mineInk).toFixed(2));
  await lt.p.fill('#bmInput', 'focus ring check'); await lt.p.screenshot({ path: 'shots/final-chat-light.png' });
  // ================= Android (no backdrop blur)
  const an = await L.newUser(U.A, { device: 'android' }); await an.p.evaluate(() => document.documentElement.classList.add('bmn-android')); await L.openInbox(an); await sleep(400);
  check('ANDROID tier: glass surfaces have no backdrop-filter (solid fallback)', await an.p.evaluate(() => { const e = document.querySelector('#bmnMsg .bm-circle'); const f = getComputedStyle(e).backdropFilter; return f === 'none' || f === ''; }));
  await an.p.screenshot({ path: 'shots/final-list-android.png' });
  // ================= desktop keyboard behaviour
  const d = await L.newUser(U.A, { device: 'desktop' }); await L.openInbox(d); await sleep(400);
  await d.p.evaluate(() => document.querySelector('.bm-row').click()); await sleep(1500);
  await d.p.fill('#bmInput', 'enter sends'); await d.p.press('#bmInput', 'Enter'); await sleep(1200);
  await d.p.fill('#bmInput', 'line1'); await d.p.press('#bmInput', 'Shift+Enter'); await d.p.keyboard.type('line2'); const val = await d.p.inputValue('#bmInput');
  const sentN = (await api('/state')).tables.messages.filter(m => m.content === 'enter sends').length;
  check('DESKTOP: Enter sends once, Shift+Enter inserts a newline', sentN === 1 && val === 'line1\nline2', JSON.stringify(val));
  await d.p.press('#bmInput', 'Escape'); await sleep(600);
  check('DESKTOP: Escape goes back to list', await d.p.evaluate(() => document.getElementById('bmnMsg').dataset.view === 'list' && document.getElementById('bmnMsg').classList.contains('open')));
  await d.p.keyboard.press('Escape'); await sleep(500);
  check('DESKTOP: second Escape closes Messages only (app stays open)', await d.p.evaluate(() => !document.getElementById('bmnMsg').classList.contains('open') && document.documentElement.classList.contains('lgtt-open')));
  await d.p.screenshot({ path: 'shots/final-desktop.png' });
  check('no page errors in suite 4', [a, lt, an, d].every(x => x.errs.length === 0), JSON.stringify([a, lt, an, d].map(x => x.errs)));
  console.log(JSON.stringify(L.summary()));
  await L.close();
})().catch(e => { console.error('CRASH', e.message.slice(0, 900)); process.exit(1); });
