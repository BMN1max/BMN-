const L = require('./lib'); const { check, sleep, U, api } = L;
const st = async () => (await api('/state'));
const T = (n) => new Date(Date.now() - n * 60000).toISOString();
const msgsOf = async () => (await st()).tables.messages;
const rowsText = (p) => p.evaluate(() => [...document.querySelectorAll('.bm-msg .bm-bub')].map(e => e.innerText.replace(/\s+/g, ' ').trim()));
(async () => {
  await api('/reset');
  // ---------- pagination: 150 messages, newest-first paging
  const seed = []; for (let i = 1; i <= 150; i++) seed.push({ sender_id: i % 3 ? U.B : U.A, recipient_id: i % 3 ? U.A : U.B, content: 'msg ' + i, created_at: T(1000 - i), read_at: T(1000 - i) });
  await api('/seed', { messages: seed });
  const a = await L.newUser(U.A); await L.openInbox(a); await sleep(500);
  await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1500);
  let n = await a.p.evaluate(() => document.querySelectorAll('.bm-msg').length);
  check('PAGING: opens with newest 60 messages (not oldest)', n === 60 && /msg 150/.test((await rowsText(a.p)).pop()) && /^msg 91 /.test((await rowsText(a.p))[0]), 'rendered ' + n);
  check('PAGING: stays scrolled to the newest message', await a.p.evaluate(() => { const m = document.getElementById('bmMsgs'); return m.scrollHeight - m.scrollTop - m.clientHeight < 8; }));
  await a.p.evaluate(() => { document.getElementById('bmMsgs').scrollTop = 0; }); await sleep(1500);
  n = await a.p.evaluate(() => document.querySelectorAll('.bm-msg').length);
  check('PAGING: scrolling to top loads earlier messages (120)', n === 120, 'rendered ' + n);
  const pos = await a.p.evaluate(() => { const m = document.getElementById('bmMsgs'); const first = [...document.querySelectorAll('.bm-msg')].find(e => e.querySelector('.bm-bub').firstChild.textContent === 'msg 91'); return first.getBoundingClientRect().top - m.getBoundingClientRect().top; });
  check('PAGING: scroll position anchored after prepend (msg 91 not thrown off-screen)', pos > -1200 && pos < 2500, 'msg91 top ' + Math.round(pos));
  await a.p.evaluate(() => { document.getElementById('bmMsgs').scrollTop = 0; }); await sleep(1200);
  await a.p.evaluate(() => { document.getElementById('bmMsgs').scrollTop = 0; }); await sleep(1200);
  const all = await rowsText(a.p);
  check('PAGING: all 150 loaded, unique, in order, no "load earlier" button left', all.length === 150 && new Set(all).size === 150 && /^msg 1 /.test(all[0]) && await a.p.evaluate(() => !document.querySelector('.bm-more')), 'count ' + all.length);
  check('day separators rendered (sticky)', await a.p.evaluate(() => document.querySelectorAll('.bm-day').length >= 1));

  // ---------- failed send + retry (optimistic UI)
  await api('/reset'); await api('/seed', { messages: [{ sender_id: U.B, recipient_id: U.A, content: 'hello', created_at: T(5), read_at: T(4) }] });
  const a2 = await L.newUser(U.A); await L.openInbox(a2); await L.tap(a2.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1200);
  await api('/flags', { failInsert: true });
  await a2.p.fill('#bmInput', 'will fail'); await L.tap(a2.p, '#bmSend'); await sleep(1500);
  check('FAILED SEND: bubble marked failed with retry hint, text not lost', await a2.p.evaluate(() => { const m = document.querySelector('.bm-msg.failed'); return !!m && /Not sent/.test(m.textContent) && /will fail/.test(m.textContent); }));
  check('FAILED SEND: nothing stored in DB', !(await msgsOf()).some(m => m.content === 'will fail'));
  await api('/flags', { failInsert: false });
  await L.tap(a2.p, '.bm-msg.failed'); await sleep(1500);
  let ms = await msgsOf();
  check('RETRY: tap resends, stored exactly once, failed state cleared', ms.filter(m => m.content === 'will fail').length === 1 && await a2.p.evaluate(() => !document.querySelector('.bm-msg.failed') && !document.querySelector('.bm-msg.pending')));
  // offline
  await a2.ctx.setOffline(true); await a2.p.evaluate(() => Object.defineProperty(navigator, 'onLine', { get: () => false, configurable: true }));
  await a2.p.fill('#bmInput', 'offline msg'); await L.tap(a2.p, '#bmSend'); await sleep(800);
  check('OFFLINE: message kept as failed (not silently dropped)', await a2.p.evaluate(() => !!document.querySelector('.bm-msg.failed')));
  await a2.ctx.setOffline(false); await a2.p.evaluate(() => Object.defineProperty(navigator, 'onLine', { get: () => true, configurable: true }));
  await L.tap(a2.p, '.bm-msg.failed'); await sleep(1500);
  check('OFFLINE: retry after reconnect succeeds', (await msgsOf()).filter(m => m.content === 'offline msg').length === 1);

  // ---------- content safety / kinds
  await a2.p.fill('#bmInput', '<img src=x onerror="window.__xss=1"> <b>bold</b>'); await L.tap(a2.p, '#bmSend'); await sleep(800);
  await a2.p.fill('#bmInput', 'see https://example.com/a?b=1, ok'); await L.tap(a2.p, '#bmSend'); await sleep(800);
  await a2.p.fill('#bmInput', '😀'); await L.tap(a2.p, '#bmSend'); await sleep(800);
  await api('/seed', { messages: [{ sender_id: U.B, recipient_id: U.A, content: '🎬 Shared a BMN Community post: Nice clip\nhttp://localhost:8124/#post-123', created_at: T(0) }] });
  await sleep(7000);
  const kinds = await a2.p.evaluate(() => ({ xss: window.__xss || 0, injected: document.querySelectorAll('.bm-bub img:not(.bm-img), .bm-bub b').length, link: (document.querySelector('.bm-bub a[href^="https://example.com"]') || {}).rel, linkText: (document.querySelector('.bm-bub a[href^="https://example.com"]') || {}).textContent, emoji: !!document.querySelector('.bm-msg.emoji'), share: !!document.querySelector('.bm-share') }));
  check('XSS: HTML in a message is shown as text, never executed', kinds.xss === 0 && kinds.injected === 0, JSON.stringify(kinds));
  check('LINKS: URL linkified safely (noopener, trailing comma excluded)', /noopener/.test(kinds.link || '') && kinds.linkText === 'https://example.com/a?b=1', kinds.linkText);
  check('EMOJI-only message gets large emoji style', kinds.emoji);
  check('SHARED POST card rendered for BMN share messages (arrived via polling)', kinds.share);
  const long = 'x'.repeat(5001);
  await a2.p.evaluate((l) => { const i = document.getElementById('bmInput'); i.maxLength = 99999; i.value = l; i.dispatchEvent(new Event('input')); }, long); await L.tap(a2.p, '#bmSend'); await sleep(600);
  check('LENGTH: > 5000 chars refused with a message, not sent', !(await msgsOf()).some(m => m.content.length > 5000) && await a2.p.evaluate(() => /5000/.test(document.getElementById('bmNote').textContent)));

  // ---------- polling fallback when realtime is NOT published
  const errsEarly = [a, a2].map(x => x.errs); await a.ctx.close(); await a2.ctx.close();
  await api('/reset'); await api('/flags', { rt: false });
  await api('/seed', { messages: [{ sender_id: U.B, recipient_id: U.A, content: 'first', created_at: T(5), read_at: T(4) }] });
  const a3 = await L.newUser(U.A); const b3 = await L.newUser(U.B);
  await L.openInbox(a3); await L.tap(a3.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1200);
  await L.openInbox(b3); await L.tap(b3.p, '.bm-row[data-peer="' + U.A + '"]'); await sleep(1000);
  await b3.p.fill('#bmInput', 'poll me'); await L.tap(b3.p, '#bmSend');
  const t0 = Date.now(); let got = false;
  while (Date.now() - t0 < 20000) { got = await a3.p.evaluate(() => !!document.querySelector('.bm-msg:not(.mine) .bm-bub') && [...document.querySelectorAll('.bm-bub')].some(e => /poll me/.test(e.textContent))); if (got) break; await sleep(500); }
  check('NO-REALTIME FALLBACK: new message appears via polling in open chat', got, Math.round((Date.now() - t0) / 1000) + 's');
  // list unread via polling, A back on list
  await L.tap(a3.p, '#bmBack'); await sleep(800);
  await b3.p.fill('#bmInput', 'second poll'); await L.tap(b3.p, '#bmSend'); const t1 = Date.now(); let got2 = false;
  while (Date.now() - t1 < 20000) { got2 = await a3.p.evaluate(() => /second poll/.test(document.querySelector('.bm-row')?.textContent || '')); if (got2) break; await sleep(500); }
  check('NO-REALTIME FALLBACK: conversation list preview + unread update via polling', got2, Math.round((Date.now() - t1) / 1000) + 's');
  check('NO-REALTIME FALLBACK: dock badge updates while inbox closed', await (async () => { await a3.p.evaluate(() => window.BMNMessaging.close(true)); await b3.p.fill('#bmInput', 'third'); await L.tap(b3.p, '#bmSend'); const t2 = Date.now(); while (Date.now() - t2 < 30000) { const v = await a3.p.evaluate(() => document.querySelector('#lgttInboxBadge').textContent + '|' + document.querySelector('#lgttInboxBadge').hidden); if (/^[2-9]\|false/.test(v)) return true; await sleep(1000); } console.log('DB', JSON.stringify((await st()).tables.messages.map(m => m.content + ':' + (m.read_at ? 'R' : 'U'))), JSON.stringify((await st()).log)); console.log('badge stuck at', await a3.p.evaluate(() => 'open=' + window.BMNMessaging._state.open + ' peer=' + window.BMNMessaging._state.peer + ' view=' + document.getElementById('bmnMsg').dataset.view + ' cls=' + document.getElementById('bmnMsg').className + ' ' + document.querySelector('#lgttInboxBadge').textContent + ' unread=' + window.BMNMessaging.unread() + ' ' + JSON.stringify([...window.BMNMessaging._state.convs.values()].map(c => c.unread)))); return false; })());
  check('no page errors in suite 2', [a, a2, a3, b3].every(x => x.errs.length === 0), JSON.stringify(errsEarly));
  console.log(JSON.stringify(L.summary()));
  await L.close();
})().catch(e => { console.error('CRASH', e.message.slice(0, 800)); process.exit(1); });
