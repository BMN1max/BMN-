const L = require('./lib'); const { check, sleep, U, api } = L;
const st = async () => (await api('/state'));
const T = (n) => new Date(Date.now() - n * 60000).toISOString();
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==', 'base64');
(async () => {
  await api('/reset');
  await api('/seed', { messages: [
    { sender_id: U.B, recipient_id: U.A, content: 'hi from bob', created_at: T(30), read_at: T(20) },
    { sender_id: U.D, recipient_id: U.A, content: 'hello from dan', created_at: T(25) } ] });
  const a = await L.newUser(U.A); const b = await L.newUser(U.B);
  await L.openInbox(a); await sleep(500);
  // ---- new message flow: people search + start chat with someone never messaged
  await L.tap(a.p, '#bmNew'); await sleep(600);
  check('NEW MESSAGE sheet opens; suggestions list real followed people (Bob)', await a.p.evaluate(() => /Bob Test/.test(document.getElementById('bmNewList').textContent)));
  await a.p.fill('#bmNewQ', 'cara'); await sleep(1200);
  check('NEW MESSAGE: search finds real profile (Cara), excludes self', await a.p.evaluate(() => /Cara Test/.test(document.getElementById('bmNewList').textContent) && !/Alice/.test(document.getElementById('bmNewList').textContent)));
  await L.tap(a.p, '#bmNewList .bm-row[data-peer="' + U.C + '"]'); await sleep(1000);
  check('NEW MESSAGE: tapping a person opens an empty conversation', await a.p.evaluate(() => document.getElementById('bmnMsg').dataset.view === 'chat' && /Cara Test/.test(document.getElementById('bmName').textContent) && /No messages yet/.test(document.getElementById('bmMsgs').textContent)));
  await a.p.fill('#bmInput', 'Hi Cara!'); await L.tap(a.p, '#bmSend'); await sleep(1200);
  check('NEW MESSAGE: first message persisted to DB', (await st()).tables.messages.some(m => m.sender_id === U.A && m.recipient_id === U.C && m.content === 'Hi Cara!'));
  await L.tap(a.p, '#bmBack'); await sleep(800);
  check('LIST: new conversation (Cara) appears at top after back', await a.p.evaluate(() => document.querySelector('#bmRows .bm-row').dataset.peer === 'cccccccc-0000-4000-8000-000000000003'));
  // ---- search conversations
  await a.p.fill('#bmSearch', 'dan'); await sleep(500);
  check('LIST SEARCH filters conversations by name', await a.p.evaluate(() => document.querySelectorAll('#bmRows .bm-row').length === 1 && /Dan/.test(document.getElementById('bmRows').textContent)));
  await a.p.fill('#bmSearch', ''); await sleep(300);
  // ---- photo send
  await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1200);
  await a.p.setInputFiles('#bmFile', { name: 'pic.png', mimeType: 'image/png', buffer: png }); await sleep(2500);
  const s = await st(); const imgMsg = s.tables.messages.find(m => /^bmn-img:/.test(m.content));
  check('PHOTO: uploaded to storage under sender folder and message stored', !!imgMsg && s.storage.some(p => p.startsWith(U.A + '/messages/')) && imgMsg.sender_id === U.A && imgMsg.recipient_id === U.B, imgMsg && imgMsg.content);
  check('PHOTO: renders as an image bubble (not raw bmn-img: text)', await a.p.evaluate(() => !!document.querySelector('.bm-msg.has-img img.bm-img[src]') && !/bmn-img:/.test(document.getElementById('bmMsgs').textContent)));
  await L.tap(a.p, '.bm-imgbtn'); await sleep(400);
  check('PHOTO: tap opens viewer; tap closes', await a.p.evaluate(() => !!document.querySelector('.bm-lightbox')) && (await L.tap(a.p, '.bm-lightbox'), await sleep(300), await a.p.evaluate(() => !document.querySelector('.bm-lightbox'))));
  await a.p.setInputFiles('#bmFile', { name: 'x.txt', mimeType: 'text/plain', buffer: Buffer.from('hi') }); await sleep(500);
  check('PHOTO: non-image rejected with a message', await a.p.evaluate(() => /choose a photo/i.test(document.getElementById('bmNote').textContent)));
  // ---- wallpaper
  await L.tap(a.p, '#bmWho'); await sleep(500);
  check('CHAT MENU lists View profile / Wallpaper / Clear', await a.p.evaluate(() => { const t = document.getElementById('bmSheet').textContent; return /View profile/.test(t) && /Chat wallpaper/.test(t) && /Clear conversation/.test(t); }));
  await L.tap(a.p, '.bm-act:nth-of-type(2)'); await sleep(500);
  await L.tap(a.p, '.bm-wp[title="Violet"]'); await sleep(400);
  check('WALLPAPER: preset applied to this chat and saved on device', await a.p.evaluate((id) => document.getElementById('bmWall').classList.contains('on') && !!localStorage.getItem('bmn-chat-wp:' + id), U.B));
  await a.p.keyboard.press('Escape').catch(() => {});
  await a.p.evaluate(() => document.querySelector('.bm-scrim') && document.querySelector('.bm-scrim').click()); await sleep(400);
  await a.p.reload({ waitUntil: 'load' }); await a.p.waitForFunction(() => window.BMNMessaging); await sleep(3000);
  await L.openInbox(a); await L.tap(a.p, '.bm-row[data-peer="' + U.B + '"]'); await sleep(1200);
  check('WALLPAPER: persists after reload', await a.p.evaluate(() => document.getElementById('bmWall').classList.contains('on')));
  await L.tap(a.p, '#bmBack'); await sleep(500); await L.tap(a.p, '.bm-row[data-peer="' + U.D + '"]'); await sleep(800);
  check('WALLPAPER: other chats unaffected', await a.p.evaluate(() => !document.getElementById('bmWall').classList.contains('on')));
  await L.tap(a.p, '#bmBack'); await sleep(500);
  // ---- clear conversation (soft delete, other side keeps theirs)
  await a.p.evaluate(() => { const r = document.querySelector('.bm-row[data-peer="bbbbbbbb-0000-4000-8000-000000000002"]'); r.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true })); }); await sleep(500);
  check('ROW MENU opens (long-press/right-click) with Clear', await a.p.evaluate(() => /Clear conversation/.test(document.getElementById('bmSheet').textContent)));
  await L.tap(a.p, '.bm-act.danger'); await sleep(500);
  check('CLEAR: asks for confirmation first, nothing deleted yet', await a.p.evaluate(() => /Clear this conversation\?/.test(document.getElementById('bmSheet').textContent)) && (await st()).tables.messages.every(m => !m.deleted_by_sender && !m.deleted_by_recipient));
  await L.tap(a.p, '[data-ok]'); await sleep(1500);
  const ms = (await st()).tables.messages.filter(m => (m.sender_id === U.B && m.recipient_id === U.A) || (m.sender_id === U.A && m.recipient_id === U.B));
  check('CLEAR: server soft-deletes for A only; rows still exist for B', ms.length > 0 && ms.every(m => (m.sender_id === U.A ? m.deleted_by_sender : m.deleted_by_recipient) && !(m.sender_id === U.A ? m.deleted_by_recipient : m.deleted_by_sender)));
  check('CLEAR: conversation disappears from A list', await a.p.evaluate(() => !document.querySelector('.bm-row[data-peer="bbbbbbbb-0000-4000-8000-000000000002"]')));
  await L.openInbox(b); await sleep(800);
  check('CLEAR: B still sees the whole conversation', await b.p.evaluate(() => !!document.querySelector('.bm-row[data-peer="aaaaaaaa-0000-4000-8000-000000000001"]')));
  // ---- self chat
  await L.tap(a.p, '#bmSelf'); await sleep(1000);
  check('SAVED MESSAGES: opens self chat, no Clear action offered (server rejects it)', await a.p.evaluate(() => /Saved messages/.test(document.getElementById('bmName').textContent)) && (await L.tap(a.p, '#bmWho'), await sleep(400), await a.p.evaluate(() => !/Clear conversation/.test(document.getElementById('bmSheet').textContent))));
  await a.p.evaluate(() => document.querySelector('.bm-scrim').click()); await sleep(300);
  await a.p.fill('#bmInput', 'note to self'); await L.tap(a.p, '#bmSend'); await sleep(1200);
  check('SAVED MESSAGES: note persisted, not counted as unread, no read tick', (await st()).tables.messages.some(m => m.sender_id === U.A && m.recipient_id === U.A && m.content === 'note to self') && await a.p.evaluate(() => !document.querySelector('.bm-msg.mine .bm-st') && window.BMNMessaging.unread() === 0));
  // ---- server inbox RPC path (optional SQL installed)
  await api('/flags', { rpcInbox: true });
  const a2 = await L.newUser(U.A); await L.openInbox(a2); await sleep(800);
  check('OPTIONAL RPC: when bmn_inbox_conversations exists the list uses it and matches', await a2.p.evaluate(() => window.BMNMessaging._state.rpcInbox === true && document.querySelectorAll('#bmRows .bm-row').length >= 2));
  await api('/flags', { rpcInbox: false });
  check('no page errors in suite 3', [a, b, a2].every(x => x.errs.length === 0), JSON.stringify([a, b, a2].map(x => x.errs)));
  console.log(JSON.stringify(L.summary()));
  await L.close();
})().catch(e => { console.error('CRASH', e.message.slice(0, 900)); process.exit(1); });
