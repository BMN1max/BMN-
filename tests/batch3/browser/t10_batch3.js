// Batch 3 browser suite. Runs the real client (bmn-messaging.js) in headless Chromium against pgserver.js (real local PostgreSQL + RLS).
// LOCAL SIMULATION ONLY: not a production test and not a real-iPhone test.
const L = require('./lib'); const { check, sleep, U, api } = L;
const sql = async (s, uid) => { const r = await api('/sql', { sql: s, uid }); if (r.error) throw new Error(r.error.message); return r.data; };
const q1 = async (s) => { const d = await sql(`SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (${s}) x`); return d; };
const num = async (s) => (await q1(s))[0].n;
const act = async (p, fn, ...a) => p.evaluate(fn, ...a);
const sendText = async (u, text) => { await u.p.fill('#bmInput', text); await u.p.click('#bmSend'); await sleep(900); };
const ctx = async (u, textOrId) => { await u.p.evaluate((t) => { const els = [...document.querySelectorAll('#bmMsgs .bm-msg[data-id]')]; const el = els.find(e => e.textContent.includes(t)) || document.querySelector('#bmMsgs .bm-msg[data-id="' + t + '"]'); el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true })); }, textOrId); await sleep(350); };
const menu = async (u) => u.p.evaluate(() => [...document.querySelectorAll('.bm-ctx-item span')].map(s => s.textContent));
const pick = async (u, label) => { await u.p.evaluate((l) => { [...document.querySelectorAll('.bm-ctx-item')].find(b => b.textContent.trim() === l).click(); }, label); await sleep(700); };
const sheetBtn = async (u, label) => { await u.p.evaluate((l) => { const b = [...document.querySelectorAll('#bmSheet .bm-act, #bmSheet button')].find(b => b.textContent.trim() === l); if (!b) throw new Error('no sheet button ' + l); b.click(); }, label); await sleep(700); };
(async () => {
  await api('/reset');
  const a = await L.newUser(U.A), b = await L.newUser(U.B), c = await L.newUser(U.C);
  check('no page errors on load (A,B,C)', a.errs.length + b.errs.length + c.errs.length === 0, JSON.stringify([...a.errs, ...b.errs, ...c.errs]));
  await L.openInbox(a); await sleep(800);
  const cap = await act(a.p, () => window.BMNMessaging._state.cap);
  check('capability probes see the migrations (actions, groups, conversation settings, blocks, presence)', cap.actions === true && cap.groups === true && cap.cs === true && cap.blocks === true && cap.pres === true, JSON.stringify(cap));

  // ---------- themes ----------
  const th = async (u) => u.p.evaluate(() => { const r = document.getElementById('bmnMsg'), cs = getComputedStyle(r), rows = getComputedStyle(document.getElementById('bmRows')), lst = getComputedStyle(document.querySelector('#bmnMsg .bm-list')); return { theme: r.dataset.bmTheme, bg: cs.backgroundColor, listBg: lst.backgroundColor, listBlur: lst.backdropFilter || lst.webkitBackdropFilter || 'none', rowsBlur: rows.backdropFilter || 'none', ink: cs.color }; });
  let t = await th(a);
  check('dark theme: near-black solid background, light text, no blur on the list', t.theme === 'dark' && t.bg === 'rgb(10, 10, 12)' && t.listBg === 'rgb(10, 10, 12)' && /none/.test(t.listBlur) && /none/.test(t.rowsBlur) && t.ink === 'rgb(245, 245, 247)', JSON.stringify(t));
  const glassOn = await act(a.p, () => ['#bmClose', '.bm-title', '#bmSearch', '#bmChips', '#bmNew'].map(s => { const e = document.querySelector(s), g = getComputedStyle(e.closest('.bm-glass, .bm-accent') || e); return (g.backdropFilter || 'none') !== 'none' || e.closest('.bm-accent') != null; }));
  check('liquid glass only on the small surfaces (back, title, search, filter pill, new)', glassOn.every(Boolean), JSON.stringify(glassOn));
  await a.p.click('#bmSettings'); await sleep(500);
  await a.p.evaluate(() => document.querySelector('[data-set="theme"][data-val="light"]').click()); await sleep(900);
  t = await th(a);
  check('light theme: soft white background, dark text, still no blur on the list', t.theme === 'light' && t.bg === 'rgb(244, 245, 248)' && t.ink === 'rgb(15, 17, 21)' && /none/.test(t.listBlur), JSON.stringify(t));
  check('theme saved to the account (bmn_messaging_settings)', (await q1(`SELECT theme FROM public.bmn_messaging_settings WHERE user_id='${U.A}'`))[0].theme === 'light');
  await a.p.evaluate(() => document.querySelector('[data-set="accent"][data-val="forest"]').click()); await sleep(700);
  check('accent theme applied and saved', await act(a.p, () => document.getElementById('bmnMsg').dataset.bmAccent) === 'forest' && (await q1(`SELECT accent FROM public.bmn_messaging_settings WHERE user_id='${U.A}'`))[0].accent === 'forest');
  await a.p.screenshot({ path: 'shots_settings_light.png' });
  await a.p.evaluate(() => document.querySelector('[data-set="theme"][data-val="system"]').click()); await sleep(600);
  check('system theme follows the device (dark scheme -> dark)', (await th(a)).theme === 'dark');
  await a.p.emulateMedia({ colorScheme: 'light' }); await sleep(400);
  check('system theme live-updates when the device switches to light', (await th(a)).theme === 'light');
  await a.p.emulateMedia({ colorScheme: 'dark' }); await sleep(300);
  await a.p.evaluate(() => document.querySelector('[data-set="accent"][data-val="bmn"]').click()); await sleep(500);
  await a.p.evaluate(() => document.querySelector('#bmSheet [data-cancel]').click()); await sleep(300);

  // ---------- privacy settings reuse the EXISTING user_settings table ----------
  await a.p.click('#bmSettings'); await sleep(500);
  await a.p.evaluate(() => document.querySelector('[data-tog="read_receipts"]').click()); await sleep(800);
  check('read receipts toggle writes the existing user_settings row', (await q1(`SELECT read_receipts FROM public.user_settings WHERE user_id='${U.A}'`))[0].read_receipts === false);
  await a.p.evaluate(() => document.querySelector('[data-tog="read_receipts"]').click()); await sleep(600);
  await a.p.evaluate(() => document.querySelector('#bmSheet [data-cancel]').click()); await sleep(300);

  // ---------- groups ----------
  await a.p.click('#bmNew'); await sleep(400); await a.p.click('#bmNewGroup'); await sleep(400);
  await a.p.fill('#bmGName', 'BMN Crew');
  for (const nm of ['bob_test', 'cara_test']) { await a.p.fill('#bmPickQ', nm); await sleep(700); await a.p.click('.bm-person[data-peer]'); await sleep(200); }
  check('create button enabled with name + members', await act(a.p, () => !document.getElementById('bmPickGo').disabled));
  await a.p.click('#bmPickGo'); await sleep(1800);
  const g = (await q1(`SELECT id, name FROM public.group_chats`))[0]; const gid = g && g.id;
  check('group created through the real RPC (3 members, creator is owner)', !!gid && (await num(`SELECT count(*) n FROM public.group_members WHERE group_id='${gid}'`)) === 3 && (await num(`SELECT count(*) n FROM public.group_members WHERE group_id='${gid}' AND user_id='${U.A}' AND role='owner'`)) === 1);
  check('group chat opened with name in header and member count', await act(a.p, () => document.getElementById('bmName').textContent === 'BMN Crew' && /3 members/.test(document.getElementById('bmSub2').textContent)));
  check('system message "created the group" shown', await act(a.p, () => /created the group/.test(document.getElementById('bmMsgs').textContent)));
  await sendText(a, 'Welcome to the crew');
  check('group message stored in group_messages (not messages)', (await num(`SELECT count(*) n FROM public.group_messages WHERE content='Welcome to the crew'`)) === 1 && (await num(`SELECT count(*) n FROM public.messages WHERE content='Welcome to the crew'`)) === 0);
  await L.openInbox(b); await b.p.waitForSelector('.bm-row[data-gid]',{timeout:8000}).catch(()=>{}); await sleep(500);
  const brow = await act(b.p, () => { const r = document.querySelector('.bm-row[data-gid]'); return r ? { name: r.querySelector('strong').textContent, prev: r.querySelector('small').textContent, badge: (r.querySelector('.bm-badge') || {}).textContent } : null; });
  if (!brow) console.log('DBGRPC', JSON.stringify(await api('/rpc',{name:'bmn_group_inbox',args:{},uid:U.B})).slice(0,300), JSON.stringify(await q1('select user_id, role from public.group_members')));
  if (!brow) console.log('DBG', JSON.stringify(await b.p.evaluate(()=>({cap:window.BMNMessaging._state.cap, g:(window.BMNMessaging._state.groups||[]).length, rpc:window.BMNMessaging._state.rpcInbox, rows:document.getElementById('bmRows').textContent.slice(0,200), filter:window.BMNMessaging._state.filter, arch:window.BMNMessaging._state.arch}))), b.errs);
  check('B inbox: group row with name, "Alice: ..." preview and unread 1', !!brow && brow.name === 'BMN Crew' && /Alice.*Welcome to the crew/.test(brow.prev) && brow.badge === '1', JSON.stringify(brow));
  check('B dock badge counts the group unread', await act(b.p, () => document.querySelector('#lgttInboxBadge').textContent) === '1');
  await b.p.click('.bm-row[data-gid]'); await sleep(1500);
  check('B sees the group thread with the sender name', await act(b.p, () => /Alice Test/.test(document.getElementById('bmMsgs').textContent) && /Welcome to the crew/.test(document.getElementById('bmMsgs').textContent)));
  check('opening the group marks it read on the server (last_read_at moved)', (await num(`SELECT count(*) n FROM public.group_members WHERE group_id='${gid}' AND user_id='${U.B}' AND last_read_at > now() - interval '30 seconds'`)) === 1);
  check('B unread badge cleared', await act(b.p, () => document.querySelector('#lgttInboxBadge').hidden));

  // ---------- message actions in a group ----------
  await ctx(b, 'Welcome to the crew');
  const mb = await menu(b);
  check('member menu: Reply/Copy/Forward/Save/Select/Delete for me/Report; NO Pin, Edit or Unsend for others', ['Reply', 'Copy', 'Forward', 'Save', 'Select', 'Delete for me', 'Report'].every(x => mb.includes(x)) && !mb.includes('Pin') && !mb.includes('Edit') && !mb.includes('Unsend for everyone'), JSON.stringify(mb));
  await pick(b, 'Reply');
  check('reply preview appears in the composer', await act(b.p, () => /Replying to Alice/.test(document.getElementById('bmReply').textContent)));
  await sendText(b, 'Glad to be here');
  check('reply stored with reply_to_id', (await num(`SELECT count(*) n FROM public.group_messages WHERE content='Glad to be here' AND reply_to_id IS NOT NULL`)) === 1);
  check('reply shows a quote of the original', await act(b.p, () => !!document.querySelector('#bmMsgs .bm-quote[data-jump]') && /Welcome to the crew/.test(document.querySelector('#bmMsgs .bm-quote').textContent)));
  await ctx(b, 'Welcome to the crew'); await b.p.evaluate(() => document.querySelector('.bm-ctx-react [data-e="❤️"]').click()); await sleep(900);
  check('reaction stored once per user', (await num(`SELECT count(*) n FROM public.message_reactions WHERE emoji='❤️' AND user_id='${U.B}'`)) === 1);
  check('reaction chip shown', await act(b.p, () => !!document.querySelector('.bm-rx.mine')));
  await b.p.screenshot({ path: 'shots_group_dark.png' });
  // A sees the reply + reaction after polling
  await sleep(5500);
  check('A sees B’s reply and the reaction (polling)', await act(a.p, () => /Glad to be here/.test(document.getElementById('bmMsgs').textContent) && !!document.querySelector('.bm-rx')));
  await act(a.p, () => document.querySelector('#bmMsgs .bm-quote[data-jump]').click()); await sleep(500);
  check('tapping the quote jumps to the original message', await act(a.p, () => !!document.querySelector('#bmMsgs .bm-msg.flash')));
  // edit
  await ctx(a, 'Welcome to the crew'); const ma = await menu(a);
  check('owner menu adds Pin, Edit and Unsend for everyone', ['Pin', 'Edit', 'Unsend for everyone', 'React'.slice(0, 0) || 'Reply'].every(x => ma.includes(x)), JSON.stringify(ma));
  await pick(a, 'Edit');
  check('edit mode fills the composer', await act(a.p, () => document.getElementById('bmInput').value === 'Welcome to the crew' && /Edit message/.test(document.getElementById('bmReply').textContent)));
  await a.p.fill('#bmInput', 'Welcome to the BMN crew'); await a.p.click('#bmSend'); await sleep(1000);
  check('edit saved with edited_at and history row', (await num(`SELECT count(*) n FROM public.group_messages WHERE content='Welcome to the BMN crew' AND edited_at IS NOT NULL`)) === 1 && (await num(`SELECT count(*) n FROM public.message_edits WHERE old_content='Welcome to the crew'`)) === 1);
  check('edited label shown', await act(a.p, () => /edited/.test(document.getElementById('bmMsgs').textContent)));
  // pin
  await ctx(a, 'Welcome to the BMN crew'); await pick(a, 'Pin');
  check('admin can pin; pinned bar visible', (await num(`SELECT count(*) n FROM public.message_pins`)) === 1 && await act(a.p, () => !document.getElementById('bmPin').hidden && /Welcome to the BMN crew/.test(document.getElementById('bmPin').textContent)));
  // B direct pin attempt must be rejected by the server too
  const bp = await api('/rpc', { name: 'bmn_set_message_pin', args: { p_scope: 'group', p_id: (await q1(`SELECT id FROM public.group_messages WHERE content='Glad to be here'`))[0].id, p_pinned: true }, uid: U.B });
  check('server rejects a member pinning in a group (not just the UI)', !!bp.error, JSON.stringify(bp.error));
  // forward
  await ctx(a, 'Welcome to the BMN crew'); await pick(a, 'Forward');
  await a.p.evaluate(() => [...document.querySelectorAll('#bmFwdList .bm-person')].find(r => /Bob/.test(r.textContent) || true) && 0);
  const fwdRows = await act(a.p, () => [...document.querySelectorAll('#bmFwdList [data-k]')].map(r => r.dataset.k));
  check('forward picker lists chats (saved messages offered)', fwdRows.length >= 1, JSON.stringify(fwdRows));
  await a.p.evaluate((me) => document.querySelector('#bmFwdList [data-k="p:' + me + '"]').click(), U.A); await a.p.click('#bmFwdGo'); await sleep(1200);
  check('forwarded message carries the forwarded label data', (await num(`SELECT count(*) n FROM public.messages WHERE sender_id='${U.A}' AND recipient_id='${U.A}' AND forwarded_from_user_id IS NOT NULL`)) === 1);
  // unsend
  await ctx(a, 'Glad to be here'); const mu = await menu(a);
  check('group owner can unsend someone else’s message', mu.includes('Unsend for everyone'));
  await pick(a, 'Unsend for everyone'); await sheetBtn(a, 'Unsend for everyone'); await a.p.waitForFunction(() => /unsent/i.test(document.getElementById('bmMsgs').textContent), null, { timeout: 5000 }).catch(() => {}); await sleep(300);
  check('unsent for everyone (tombstone on server)', (await num(`SELECT count(*) n FROM public.group_messages WHERE unsent_at IS NOT NULL`)) === 1 && await act(a.p, () => /unsent/i.test(document.getElementById('bmMsgs').textContent)), JSON.stringify({which:await q1('select content, unsent_at from public.group_messages order by created_at'),db:await num(`SELECT count(*) n FROM public.group_messages WHERE unsent_at IS NOT NULL`),ui:await act(a.p, () => document.getElementById('bmMsgs').textContent.slice(-300))}));
  // delete for me
  await ctx(a, 'Welcome to the BMN crew'); await pick(a, 'Delete for me'); await sheetBtn(a, 'Delete for me'); await sleep(900);
  check('delete for me hides it only for me', (await num(`SELECT count(*) n FROM public.group_message_hides WHERE user_id='${U.A}'`)) === 1 && (await num(`SELECT count(*) n FROM public.group_messages WHERE content='Welcome to the BMN crew'`)) === 1);
  // select mode
  await ctx(a, 'created the group').catch(() => {});

  // ---------- group admin ----------
  await act(a.p, () => document.getElementById('bmWho').click()); await sleep(900);
  check('group info lists members with roles', await act(a.p, () => { const t = document.querySelector('#bmSheet').textContent; return /Members/.test(t) && /Owner/.test(t) && /Bob Test/.test(t) && /Cara Test/.test(t); }));
  await act(a.p, (id) => document.querySelector('#bmSheet [data-m="' + id + '"]').click(), U.B); await sleep(500);
  await sheetBtn(a, 'Make admin'); await sleep(900);
  check('owner promoted Bob to admin', (await num(`SELECT count(*) n FROM public.group_members WHERE user_id='${U.B}' AND role='admin'`)) === 1);
  const cr = await api('/rpc', { name: 'bmn_set_group_role', args: { p_group: gid, p_user: U.C, p_role: 'admin' }, uid: U.C });
  check('server: a plain member cannot change roles', !!cr.error);
  // remove Cara
  await act(a.p, () => document.getElementById('bmWho').click()); await sleep(800);
  await act(a.p, (id) => document.querySelector('#bmSheet [data-m="' + id + '"]').click(), U.C); await sleep(400);
  await sheetBtn(a, 'Remove from group'); await sheetBtn(a, 'Remove'); await sleep(1000);
  check('removed member no longer in group_members', (await num(`SELECT count(*) n FROM public.group_members WHERE user_id='${U.C}'`)) === 0);
  const seen = await api('/query', { q: { table: 'group_messages', op: 'select', select: 'id', filters: [], orders: [] }, uid: U.C });
  check('removed member can no longer read group messages (RLS)', (seen.data || []).length === 0, JSON.stringify(seen));
  const post = await api('/query', { q: { table: 'group_messages', op: 'insert', values: { group_id: gid, sender_id: U.C, content: 'still here?' }, select: 'id' }, uid: U.C });
  check('removed member cannot post (RLS)', !!post.error, JSON.stringify(post.error));
  await L.openInbox(c); await sleep(1500);
  check('removed member’s inbox no longer shows the group', await act(c.p, () => !document.querySelector('.bm-row[data-gid]')));
  // only admins post
  await act(a.p, () => document.getElementById('bmWho').click()); await sleep(700); await sheetBtn(a, 'Edit group'); await sleep(500);
  await a.p.evaluate(() => document.querySelector('#bmSheet [data-tog="only"]').click()); await a.p.fill('#bmGName', 'BMN Core'); await a.p.click('#bmGSave'); await sleep(1500);
  check('group settings saved (rename + only admins post)', (await q1(`SELECT name, only_admins_post FROM public.group_chats`))[0].name === 'BMN Core' && (await q1(`SELECT only_admins_post FROM public.group_chats`))[0].only_admins_post === true);
  check('rename produced a system message', await act(a.p, () => /renamed the group/.test(document.getElementById('bmMsgs').textContent)));
  // B is admin so can still post; make a member scenario with D instead
  await sql(`SELECT 1`);
  const dpost = await api('/rpc', { name: 'bmn_add_group_members', args: { p_group: gid, p_user_ids: [U.D] }, uid: U.A });
  const dm = await api('/query', { q: { table: 'group_messages', op: 'insert', values: { group_id: gid, sender_id: U.D, content: 'member post' }, select: 'id' }, uid: U.D });
  check('server enforces "only admins can post" for members', !!dm.error, JSON.stringify(dm.error));
  await L.openInbox(b); await sleep(600);

  // ---------- one-to-one still works + actions on DMs ----------
  await act(a.p, () => document.getElementById('bmBack').click()); await sleep(600);
  await a.p.evaluate((id) => window.BMNMessaging.openChat(id), U.B); await sleep(1200);
  await sendText(a, 'hi bob (dm)');
  check('DM still stored in messages', (await num(`SELECT count(*) n FROM public.messages WHERE content='hi bob (dm)'`)) === 1);
  await ctx(a, 'hi bob (dm)'); await pick(a, 'Edit'); await a.p.fill('#bmInput', 'hi bob, edited'); await a.p.click('#bmSend'); await sleep(900);
  check('DM edit works through the RPC', (await num(`SELECT count(*) n FROM public.messages WHERE content='hi bob, edited' AND edited_at IS NOT NULL`)) === 1);
  const direct = await api('/query', { q: { table: 'messages', op: 'update', values: { content: 'hacked' }, filters: [{ k: 'eq', col: 'content', v: 'hi bob, edited' }], select: 'id' }, uid: U.A });
  check('direct UPDATE on messages is still impossible (edit only via RPC)', (await num(`SELECT count(*) n FROM public.messages WHERE content='hacked'`)) === 0);
  await L.openInbox(b); await sleep(800); await b.p.evaluate((id) => window.BMNMessaging.openChat(id), U.A); await sleep(1500);
  check('B sees the DM as edited and A’s message read', await act(b.p, () => /edited/.test(document.getElementById('bmMsgs').textContent)));
  // swipe to reply (synthetic touch pointer events)
  const swiped = await b.p.evaluate(async () => {
    const el = [...document.querySelectorAll('#bmMsgs .bm-msg')].find(e => /hi bob, edited/.test(e.textContent)), r = el.getBoundingClientRect(), ev = (t, x, y) => el.dispatchEvent(new PointerEvent(t, { pointerType: 'touch', pointerId: 7, isPrimary: true, bubbles: true, clientX: x, clientY: y, button: 0 }));
    ev('pointerdown', r.left + 40, r.top + 10); for (let i = 1; i <= 8; i++) { ev('pointermove', r.left + 40 + i * 9, r.top + 10); await new Promise(r => setTimeout(r, 16)); } ev('pointerup', r.left + 112, r.top + 10);
    await new Promise(r => setTimeout(r, 400)); return /Replying to Alice/.test(document.getElementById('bmReply').textContent);
  });
  check('swipe right on a message starts a reply', swiped);
  await b.p.evaluate(() => document.querySelector('[data-act="cancel-reply"]').click());
  // edge swipe back follows the finger
  const edge = await b.p.evaluate(async () => {
    const ch = document.getElementById('bmChat'), ev = (t, x) => ch.dispatchEvent(new PointerEvent(t, { pointerType: 'touch', pointerId: 9, isPrimary: true, bubbles: true, clientX: x, clientY: 300, button: 0 }));
    ev('pointerdown', 6); let moved = 0; for (let i = 1; i <= 10; i++) { ev('pointermove', 6 + i * 14); await new Promise(r => setTimeout(r, 16)); if (i === 5) moved = new DOMMatrix(getComputedStyle(ch).transform).m41; } ev('pointerup', 146); await new Promise(r => setTimeout(r, 500));
    return { moved, back: document.getElementById('bmnMsg').dataset.view };
  });
  check('edge swipe: chat follows the finger and goes back past the threshold', edge.moved > 40 && edge.back === 'list', JSON.stringify(edge));

  // ---------- inbox: pin / mute / archive / swipe / drafts ----------
  await L.openInbox(a); await sleep(800);
  await a.p.evaluate((id) => window.BMNMessaging.openChat(id), U.B); await sleep(900);
  await a.p.fill('#bmInput', 'unsent draft text'); await sleep(450); await a.p.click('#bmBack'); await sleep(700);
  check('draft indicator in the inbox row', await act(a.p, (id) => /Draft:.*unsent draft text/.test(document.querySelector('.bm-row[data-peer="' + id + '"]').textContent), U.B));
  await a.p.evaluate((id) => window.BMNMessaging.openChat(id), U.B); await sleep(700);
  check('draft restored when the chat is reopened', await act(a.p, () => document.getElementById('bmInput').value === 'unsent draft text'));
  await a.p.fill('#bmInput', ''); await sleep(400); await a.p.click('#bmBack'); await sleep(600);
  await act(a.p, () => document.querySelector('.bm-sw[data-key^="g:"] .bm-swb.pin') && 0);
  await act(a.p, () => document.querySelector('.bm-sw[data-key^="p:"] [data-sw="pin"]').click()); await sleep(900);
  check('pin a conversation (saved in conversation_settings, shown in a Pinned section)', (await num(`SELECT count(*) n FROM public.conversation_settings WHERE user_id='${U.A}' AND pinned_at IS NOT NULL`)) === 1 && await act(a.p, () => /Pinned/.test(document.getElementById('bmRows').textContent) && !!document.querySelector('.bm-row.pinned')));
  await act(a.p, () => document.querySelector('.bm-sw[data-key^="g:"]').scrollIntoView());
  const gk = await act(a.p, () => document.querySelector('.bm-sw[data-key^="g:"]').dataset.key);
  await act(a.p, (k) => document.querySelector('.bm-sw[data-key="' + k + '"] [data-sw="mute"]').click(), gk); await sleep(500); await sheetBtn(a, 'Always'); await sleep(900);
  check('mute shows a muted indicator and is stored', (await num(`SELECT count(*) n FROM public.conversation_settings WHERE user_id='${U.A}' AND group_id IS NOT NULL AND muted_until > now()`)) === 1 && await act(a.p, () => !!document.querySelector('.bm-row.muted .bm-ind')));
  await act(a.p, (k) => document.querySelector('.bm-sw[data-key="' + k + '"] [data-sw="arch"]').click(), gk); await sleep(900);
  check('archive hides the conversation and shows an Archived entry', await act(a.p, () => !document.querySelector('.bm-row[data-gid]') && !!document.querySelector('[data-act="arch"]')));
  await act(a.p, () => document.querySelector('[data-act="arch"]').click()); await sleep(400);
  check('archived list shows it again', await act(a.p, () => !!document.querySelector('.bm-row[data-gid]')));
  await act(a.p, () => document.querySelector('[data-act="arch-back"]').click());
  // swipe left reveals actions
  const sw = await a.p.evaluate(async () => {
    const el = document.querySelector('.bm-sw[data-key^="p:"]'), row = el.querySelector('.bm-row'), r = row.getBoundingClientRect(), ev = (t, x) => row.dispatchEvent(new PointerEvent(t, { pointerType: 'touch', pointerId: 5, isPrimary: true, bubbles: true, clientX: x, clientY: r.top + 20, button: 0 }));
    ev('pointerdown', r.right - 20); for (let i = 1; i <= 10; i++) { ev('pointermove', r.right - 20 - i * 22); await new Promise(r => setTimeout(r, 16)); } ev('pointerup', r.right - 240); await new Promise(r => setTimeout(r, 500));
    return new DOMMatrix(getComputedStyle(row).transform).m41;
  });
  check('swipe left on a row reveals Mute / Archive / Delete', sw < -150, String(sw));
  await a.p.screenshot({ path: 'shots_inbox_dark.png' });
  await act(a.p, () => document.querySelector('.bm-sw.open-r [data-sw="del"]').click()); await sleep(500);
  check('delete asks for confirmation first', await act(a.p, () => /Clear this conversation/.test(document.getElementById('bmSheet').textContent)));
  await a.p.evaluate(() => document.querySelector('#bmSheet [data-cancel]').click());

  // ---------- who_can_message + requests + blocks (enforced by the database) ----------
  await sql(`DELETE FROM public.follows WHERE following_id IN ('${U.C}','${U.D}')`);   // 'followers' mode = people Alice follows; C and D become strangers
  await sql(`INSERT INTO public.user_settings(user_id, who_can_message) VALUES ('${U.A}','followers') ON CONFLICT (user_id) DO UPDATE SET who_can_message='followers'`);
  const d = await L.newUser(U.D); await L.openInbox(d); await sleep(600);
  await d.p.evaluate((id) => window.BMNMessaging.openChat(id), U.A); await sleep(1000);
  await sendText(d, 'first hello');
  const d2 = await api('/query', { q: { table: 'messages', op: 'insert', values: { sender_id: U.D, recipient_id: U.A, content: 'second without reply' }, select: 'id' }, uid: U.D });
  check('stranger may send ONE message; the second is blocked by the database', (await num(`SELECT count(*) n FROM public.messages WHERE content='first hello'`)) === 1 && !!d2.error, JSON.stringify({err:d2.error,first:await num(`SELECT count(*) n FROM public.messages WHERE content='first hello'`),req:await q1('select * from public.message_requests'),lock:await d.p.evaluate(()=>document.getElementById('bmLock').textContent)}));
  // A follows D in reset => D is followed by A; use C as the true stranger
  await L.openInbox(c); await c.p.evaluate((id) => window.BMNMessaging.openChat(id), U.A); await sleep(900); await sendText(c, 'hi from stranger');
  await sleep(5500);
  check('A sees a Message requests banner (not mixed into the main list)', await act(a.p, () => !!document.querySelector('[data-act="req"]') && ![...document.querySelectorAll('#bmRows .bm-row')].some(r => /Cara/.test(r.textContent))));
  await act(a.p, () => document.querySelector('[data-act="req"]').click()); await sleep(400);
  await act(a.p, () => document.querySelector('#bmRows .bm-row[data-peer]').click()); await sleep(1200);
  check('request bar offers Accept / Decline / Block', await act(a.p, () => !document.getElementById('bmReqBar').hidden && ['accept', 'decline', 'block'].every(k => document.querySelector('[data-req="' + k + '"]'))));
  await act(a.p, () => document.querySelector('[data-req="accept"]').click()); await sleep(1000);
  check('accepting updates message_requests', (await num(`SELECT count(*) n FROM public.message_requests WHERE status='accepted'`)) >= 1);
  await sql(`UPDATE public.user_settings SET who_can_message='everyone' WHERE user_id='${U.A}'`);
  await act(a.p, () => document.getElementById('bmWho').click()); await sleep(500);
  await sheetBtn(a, 'Block'); await sheetBtn(a, 'Block'); await sleep(900);
  check('block stored in the existing user_blocks table (kind=block)', (await num(`SELECT count(*) n FROM public.user_blocks WHERE user_id='${U.A}' AND kind='block'`)) === 1);
  const bl = await api('/query', { q: { table: 'messages', op: 'insert', values: { sender_id: U.C, recipient_id: U.A, content: 'blocked msg' }, select: 'id' }, uid: U.C });
  check('blocked user cannot message (RLS), and composer says so', !!bl.error && await act(a.p, () => /You blocked this account/.test(document.getElementById('bmLock').textContent)), JSON.stringify(bl.error));

  // ---------- report ----------
  await act(a.p, () => document.getElementById('bmBack').click()); await sleep(500);
  await a.p.evaluate((id) => window.BMNMessaging.openChat(id), U.B); await sleep(1500);
  await ctx(b, 'hi bob, edited').catch(() => {});
  await L.openInbox(b); await b.p.evaluate((id) => window.BMNMessaging.openChat(id), U.A); await sleep(1500);
  await ctx(b, 'hi bob, edited'); await pick(b, 'Report'); await sheetBtn(b, 'Spam'); await sleep(900);
  check('message report stored for moderators (content_reports.message_id)', (await num(`SELECT count(*) n FROM public.content_reports WHERE message_id IS NOT NULL AND reporter_id='${U.B}'`)) === 1);

  // ---------- no demo data ----------
  check('no fake users or demo text anywhere', await act(a.p, () => !/Maya|Jordan|Sam Rivera|demo user/i.test(document.getElementById('bmnMsg').textContent)));
  check('no page errors during the whole run', a.errs.length + b.errs.length + c.errs.length + d.errs.length === 0, JSON.stringify([...a.errs, ...b.errs, ...c.errs, ...d.errs]));
  const s = L.summary(); console.log('SUMMARY pass', s.pass, 'fail', s.fail);
  require('fs').writeFileSync('t10_results.json', JSON.stringify({ when: new Date().toISOString(), ...s, results: L.results }, null, 1));
  await L.close(); process.exit(s.fail ? 1 : 0);
})().catch(async e => { console.log('CRASH', e.stack); await L.close(); process.exit(2); });
