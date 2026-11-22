const L = require('./lib'); const { check, sleep, U, api } = L;
const T = (n) => new Date(Date.now() - n * 60000).toISOString();
(async () => {
  await api('/reset');
  await api('/seed', { messages: [{ sender_id: U.B, recipient_id: U.A, content: 'regression hello', created_at: T(5) }] });
  const a = await L.newUser(U.A, { settle: 4000 });
  const view = () => a.p.evaluate(() => ({ stage: document.getElementById('lgttStage').dataset.view, msgOpen: document.getElementById('bmnMsg') && document.getElementById('bmnMsg').classList.contains('open'), inboxCls: document.getElementById('lgttStage').classList.contains('bmn-inbox-open'), chatCls: document.getElementById('lgttStage').classList.contains('bmn-chat-open'), on: (document.querySelector('#lgttDock .lgtt-dk.on') || {}).dataset && document.querySelector('#lgttDock .lgtt-dk.on').dataset.dock }));
  const dock = async (n) => { await a.p.evaluate((n) => document.querySelector('#lgttDock [data-dock="' + n + '"]').click(), n); await sleep(900); return view(); };
  let v = await dock('inbox'); check('DOCK: Inbox opens Messages and highlights Inbox', v.msgOpen && v.inboxCls && v.on === 'inbox', JSON.stringify(v));
  v = await dock('discover'); check('DOCK: Friends/Discover closes Messages and switches view', !v.msgOpen && !v.inboxCls && v.stage === 'discover' && v.on === 'discover', JSON.stringify(v));
  v = await dock('inbox'); v = await dock('profile'); check('DOCK: Profile closes Messages and switches view', !v.msgOpen && v.stage === 'profile' && v.on === 'profile', JSON.stringify(v));
  v = await dock('inbox'); v = await dock('feed'); check('DOCK: Home closes Messages and returns to feed', !v.msgOpen && v.stage === 'feed' && v.on === 'feed', JSON.stringify(v));
  await dock('inbox'); await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1000);
  v = await view(); check('CHAT: stage gets bmn-chat-open (dock hides) while chatting', v.chatCls);
  await L.tap(a.p, '#bmBack'); await sleep(700); v = await view(); check('CHAT: back to list restores dock (chat class removed)', !v.chatCls && v.msgOpen);
  await L.tap(a.p, '#bmClose'); await sleep(700); v = await view(); check('CLOSE button leaves Messages and re-highlights the current view', !v.msgOpen && !v.inboxCls && v.on === 'feed', JSON.stringify(v));
  // public entry points used elsewhere in the app
  await a.p.evaluate(() => window.LGTT.openInbox()); await sleep(900); v = await view(); check('ENTRY: LGTT.openInbox() opens Messages', v.msgOpen && v.on === 'inbox');
  await a.p.evaluate(() => window.BMNRealInbox.close()); await sleep(400);
  await a.p.evaluate(() => window.LGTT.openSelfChat()); await sleep(1500);
  check('ENTRY: LGTT.openSelfChat() opens Saved messages chat', await a.p.evaluate(() => /Saved messages/.test(document.getElementById('bmName').textContent) && document.getElementById('bmnMsg').dataset.view === 'chat'));
  await a.p.evaluate(() => window.BMNRealInbox.close(true)); await sleep(400);
  // profile "Message" button hook (any element with data-act="message" and data-u)
  await a.p.evaluate((id) => { const b = document.createElement('button'); b.dataset.act = 'message'; b.dataset.u = id; b.id = 'fakeMsgBtn'; b.textContent = 'Message'; b.style.cssText = 'position:fixed;top:0;left:0;z-index:99999'; document.body.appendChild(b); }, U.B);
  await a.p.evaluate(() => document.getElementById('fakeMsgBtn').click()); await sleep(1500);
  check('ENTRY: profile Message button opens that member chat', await a.p.evaluate(() => /Bob Test/.test(document.getElementById('bmName').textContent) && document.getElementById('bmnMsg').dataset.view === 'chat'));
  await a.p.evaluate(() => window.BMNRealInbox.close(true));
  // invalid ids
  await a.p.evaluate(() => window.BMNRealInbox.open()); await sleep(300);
  await a.p.evaluate(() => window.BMNRealInbox.openChat('not-a-uuid')); await sleep(500);
  check('ROBUSTNESS: invalid peer id refused, stays on list with a message', await a.p.evaluate(() => document.getElementById('bmnMsg').dataset.view === 'list' && /could not be opened/i.test(document.getElementById('bmNote').textContent)));
  await a.p.evaluate((id) => window.BMNRealInbox.openChat('99999999-0000-4000-8000-000000000009'), U.B); await sleep(1200);
  check('ROBUSTNESS: unknown member id refused (no broken chat)', await a.p.evaluate(() => document.getElementById('bmnMsg').dataset.view === 'list'));
  // rapid open/close does not leak timers/listeners or throw
  for (let i = 0; i < 6; i++) { await a.p.evaluate(() => { window.BMNRealInbox.open(); window.BMNRealInbox.close(); }); }
  await sleep(500);
  check('ROBUSTNESS: rapid open/close x6 leaves clean state', (await view()).inboxCls === false);
  // session expiry mid-send
  await a.p.evaluate(() => window.BMNRealInbox.open()); await a.p.evaluate((id) => window.BMNRealInbox.openChat(id), U.B); await sleep(1200);
  await a.p.evaluate(() => { const c = window.bmnSupabase; c.auth.getSession = async () => ({ data: { session: null } }); c.auth.getUser = async () => ({ data: { user: null }, error: { status: 401, message: 'JWT expired' } }); window.__authCalls = 0; window.requestCommunityAuth = () => { window.__authCalls++; }; });
  await a.p.fill('#bmInput', 'after expiry'); await L.tap(a.p, '#bmSend'); await sleep(1500);
  check('SESSION EXPIRY: message kept as failed + sign-in requested, nothing stored', await a.p.evaluate(() => !!document.querySelector('.bm-msg.failed') && window.__authCalls >= 1) && !(await api('/state')).tables.messages.some(m => m.content === 'after expiry'));
  check('no page errors in suite 5', a.errs.length === 0, JSON.stringify(a.errs));
  console.log(JSON.stringify(L.summary()));
  await L.close();
})().catch(e => { console.error('CRASH', e.message.slice(0, 900)); process.exit(1); });
