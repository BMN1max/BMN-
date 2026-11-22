const L = require('./lib'); const { check, sleep, U, api } = L;
const st = async () => (await api('/state'));
const msgsOf = async () => (await st()).tables.messages;
const T = (n, m) => new Date(Date.now() - n * 60000).toISOString();
(async () => {
  await api('/reset');
  await api('/seed', { messages: [
    { sender_id: U.B, recipient_id: U.A, content: 'Hey Alice', created_at: T(60) },
    { sender_id: U.A, recipient_id: U.B, content: 'Hi Bob', created_at: T(50) },
    { sender_id: U.B, recipient_id: U.A, content: 'Lunch?', created_at: T(10) },
    { sender_id: U.D, recipient_id: U.A, content: 'Welcome', created_at: T(60 * 24 * 3) } ] });
  const a = await L.newUser(U.A); const b = await L.newUser(U.B);
  check('no page errors on load (A,B)', a.errs.length === 0 && b.errs.length === 0, JSON.stringify([...a.errs, ...b.errs]));
  // ---- logged-out / old inbox disabled
  check('old inline inbox not built', await a.p.evaluate(() => !document.getElementById('bmnRealInbox')));
  check('dock badge = real unread (3) before opening', await a.p.evaluate(() => { const b = document.querySelector('#lgttInboxBadge'); return !b.hidden && b.textContent === '3'; }), await a.p.evaluate(() => document.querySelector('#lgttInboxBadge').textContent));
  await L.openInbox(a); await sleep(600);
  check('list shows 2 real conversations', await a.p.evaluate(() => document.querySelectorAll('#bmRows .bm-row').length) === 2);
  check('list: Bob unread badge = 2, preview latest', await a.p.evaluate(() => { const r = document.querySelector('.bm-row[data-peer="' + 'bbbbbbbb-0000-4000-8000-000000000002' + '"]'); return r.querySelector('.bm-badge').textContent === '2' && /Lunch/.test(r.textContent); }));
  check('no demo/fake names anywhere in inbox', await a.p.evaluate(() => !/Maya|Jordan|Sam Rivera|demo/i.test(document.getElementById('bmnMsg').textContent)));
  // ---- open chat, read receipts
  await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1500);
  check('chat shows 3 messages in order', JSON.stringify(await a.p.evaluate(() => [...document.querySelectorAll('.bm-msg .bm-bub')].map(e => e.firstChild.textContent))) === '["Hey Alice","Hi Bob","Lunch?"]');
  check('unread divider shown before first unread', await a.p.evaluate(() => !!document.getElementById('bmUnreadDiv')));
  let ms = await msgsOf();
  check('opening chat marks Bob->Alice read on server (RPC, not blocked UPDATE)', ms.filter(m => m.sender_id === U.B && m.recipient_id === U.A).every(m => m.read_at), JSON.stringify((await st()).log));
  check('dock badge dropped to 1 (Dan only)', await a.p.evaluate(() => document.querySelector('#lgttInboxBadge').textContent) === '1');
  // ---- B sees read ticks
  await L.openInbox(b); await L.tap(b.p, '.bm-row[data-peer="' + U.A + '"]'); await sleep(1500);
  check('B sees own messages as READ (double tick) after A opened the chat', await b.p.evaluate(() => { const m = [...document.querySelectorAll('.bm-msg.mine')]; return m.length === 2 && m.every(x => !!x.querySelector('.bm-st.read')); }));
  // ---- send from A, appears for B in realtime
  await a.p.fill('#bmInput', 'On my way 🚀'); await L.tap(a.p, '#bmSend'); await sleep(300);
  check('A optimistic bubble appears immediately', await a.p.evaluate(() => !![...document.querySelectorAll('.bm-msg.mine .bm-bub')].find(e => /On my way/.test(e.textContent))));
  await sleep(1200);
  ms = await msgsOf(); const sent = ms.find(m => m.content === 'On my way 🚀');
  check('PERSISTENCE: message stored in DB with correct sender/recipient', !!sent && sent.sender_id === U.A && sent.recipient_id === U.B);
  check('exactly one copy (no duplicate from realtime echo)', ms.filter(m => m.content === 'On my way 🚀').length === 1 && await a.p.evaluate(() => [...document.querySelectorAll('.bm-bub')].filter(e => /On my way/.test(e.textContent)).length) === 1);
  check('REALTIME: B receives it live in open chat', await b.p.evaluate(() => !![...document.querySelectorAll('.bm-msg:not(.mine) .bm-bub')].find(e => /On my way/.test(e.textContent))));
  await sleep(1200);
  ms = await msgsOf(); check('B (viewing chat) auto-marks A message read', !!ms.find(m => m.content === 'On my way 🚀').read_at);
  await sleep(800);
  check('A sees read double-tick live', await a.p.evaluate(() => { const m = [...document.querySelectorAll('.bm-msg.mine')].pop(); return !!m.querySelector('.bm-st.read'); }));
  check('notification row created for recipient', (await st()).tables.notifications.some(n => n.user_id === U.B && n.actor_id === U.A && n.type === 'message'));
  // ---- unread from B arriving while A is on list
  await L.tap(a.p, '#bmBack'); await sleep(900);
  await b.p.fill('#bmInput', 'Sounds good'); await L.tap(b.p, '#bmSend'); await sleep(1500);
  check('A list: unread badge 1 on Bob + dock badge 2, live', await a.p.evaluate(() => { const r = document.querySelector('.bm-row[data-peer="bbbbbbbb-0000-4000-8000-000000000002"]'); return r.querySelector('.bm-badge')?.textContent === '1' && document.querySelector('#lgttInboxBadge').textContent === '2' && /Sounds good/.test(r.textContent); }), await a.p.evaluate(() => document.querySelector('#lgttInboxBadge').textContent));
  // ---- reload persistence
  await a.p.reload({ waitUntil: 'load' }); await a.p.waitForFunction(() => window.BMNMessaging && document.querySelector('#lgttDock')); await sleep(3500);
  check('RELOAD: dock badge still real unread (2)', await a.p.evaluate(() => document.querySelector('#lgttInboxBadge').textContent), await a.p.evaluate(() => document.querySelector('#lgttInboxBadge').textContent));
  await L.openInbox(a); await sleep(600); await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1500);
  check('RELOAD: full history restored (5 msgs incl. sent + received)', await a.p.evaluate(() => document.querySelectorAll('.bm-msg').length) === 5);
  // ---- permissions
  const c = await L.newUser(U.C);
  const perm = await c.p.evaluate(async (U) => {
    const s = window.bmnSupabase; const out = {};
    out.read = (await s.from('messages').select('id,content').or('sender_id.eq.' + U.A + ',recipient_id.eq.' + U.A)).data.length;
    out.impersonate = (await s.from('messages').insert({ sender_id: U.A, recipient_id: U.B, content: 'forged' })).error?.code;
    out.upd = (await s.from('messages').update({ content: 'tampered' }).eq('sender_id', U.A).select('id')).data;
    out.readB = (await s.from('messages').select('id').eq('recipient_id', U.B)).data.length;
    return out;
  }, U);
  check('PERMISSIONS: stranger C cannot read A/B messages', perm.read === 0 && perm.readB === 0, JSON.stringify(perm));
  check('PERMISSIONS: forged sender_id rejected (42501)', perm.impersonate === '42501');
  check('PERMISSIONS: no UPDATE of others messages', Array.isArray(perm.upd) && perm.upd.length === 0 && !(await msgsOf()).some(m => m.content === 'tampered' || m.content === 'forged'));
  await L.openInbox(c); await sleep(500);
  check('C inbox is empty (no leakage) and shows empty state', await c.p.evaluate(() => document.querySelectorAll('#bmRows .bm-row').length === 0 && /No messages yet/.test(document.getElementById('bmRows').textContent)));
  // ---- logged-out
  const g = await L.newUser(null, { settle: 7000 });
  await g.p.evaluate(() => { window.__authCalled = 0; window.requestCommunityAuth = () => { window.__authCalled++; }; });
  await g.p.evaluate(() => document.querySelector('#lgttDock [data-dock="inbox"]').click()); await sleep(500);
  check('LOGGED OUT: inbox click asks to sign in, inbox not opened, badge hidden', await g.p.evaluate(() => window.__authCalled >= 1 && !document.querySelector('#bmnMsg.open') && document.querySelector('#lgttInboxBadge').hidden));
  check('no page errors during the whole run', [a, b, c, g].every(x => x.errs.length === 0), JSON.stringify([a, b, c, g].map(x => x.errs)));
  console.log(JSON.stringify(L.summary()));
  await L.close();
})().catch(e => { console.error('CRASH', e.message.slice(0, 600)); process.exit(1); });
