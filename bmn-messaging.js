/* BMN Messaging: one module for the Community Inbox and conversations.
 *
 * Replaces the inline "BMNRealInbox" module that used to live in index.html. Same public API
 * (window.BMNRealInbox.open / close / openChat / refresh) so every existing entry point keeps working
 * (dock Inbox button, profile Message button, LGTT.openInbox, LGTT.openSelfChat, notifications).
 *
 * Data: real Supabase table `messages` only (sender_id, recipient_id, content, read_at, created_at,
 * deleted_by_sender, deleted_by_recipient). No demo data. No schema change is required for any feature here.
 * Optional server pieces (see docs/messaging/OPTIONAL_messaging.sql) are detected at run time and are never required.
 *
 *  - read receipts use the existing SECURITY DEFINER function bmn_mark_messages_read (a direct UPDATE is blocked by RLS)
 *  - history is loaded newest-first and paged, so busy conversations never lose their latest messages
 *  - realtime when the project publishes `messages`; automatic polling fallback when it does not
 *  - the dock Inbox badge shows the real unread count
 */
(function () {
  'use strict';
  if (window.BMNMessaging) return;

  var D = document;
  var $ = function (s, r) { return (r || D).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || D).querySelectorAll(s)); };
  var esc = function (v) { return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var sb = function () { return window.bmnSupabase || null; };
  var sess = function () { return (window.bmnSession && window.bmnSession.user) || null; };
  var meId = function () { var u = sess(); return u ? u.id : null; };
  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  var IMGP = 'bmn-img:';
  var PAGE = 60, MAX_LEN = 5000, POLL_MS = 5000;
  var COLS = 'id,sender_id,recipient_id,content,created_at,read_at,deleted_by_sender,deleted_by_recipient';

  var S = {
    built: false, open: false, peer: null, rows: [], hasMore: false, loadingMore: false, loadingThread: false,
    convs: new Map(), unreadTotal: 0, unreadFrom: null, newBelow: 0, tmp: 0, rpcInbox: null,
    ch: null, chUser: null, tick: 0, lastRT: 0, imgUrls: new Map(), query: '', lastList: 0, pollBusy: false, markTimer: 0
  };
  var R = {}; // dom refs

  /* ---------- small helpers ---------- */
  function haptic(k) { try { window.LGTT && window.LGTT.haptic && window.LGTT.haptic(k); } catch (_) {} }
  function prof(id) { return (window.bmnProfiles && window.bmnProfiles[id]) || {}; }
  function nameOf(id) { var p = prof(id); return p.display_name || p.full_name || p.username || 'BMN member'; }
  function handleOf(id) { var p = prof(id); return p.username ? '@' + p.username : ''; }
  function avatarUrl(id) { var p = prof(id); return p.avatar_display_url || p.avatar_url || p.avatar || ''; }
  function avatarHTML(id, cls) {
    var u = avatarUrl(id), ini = esc((nameOf(id).trim()[0] || 'B').toUpperCase());
    return '<span class="bm-av ' + (cls || '') + '" style="--h:' + hue(id) + '">' + (u ? '<img src="' + esc(u) + '" alt="" loading="lazy" decoding="async">' : ini) + '</span>';
  }
  function hue(id) { var h = 0, s = String(id || ''); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360; return h; }
  function isFounder(id) { var p = prof(id); return !!(p.is_founder || p.is_owner || p.role === 'owner' || p.role === 'founder'); }
  function fmtTime(ts) { var d = new Date(ts); return isNaN(d.getTime()) ? '' : d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }); }
  function dayStart(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); }
  function dayDiff(ts) { var d = new Date(ts); return Math.round((dayStart(new Date()) - dayStart(d)) / 864e5); }
  function dayLabel(ts) {
    var d = new Date(ts); if (isNaN(d.getTime())) return '';
    var n = dayDiff(ts);
    if (n === 0) return 'Today';
    if (n === 1) return 'Yesterday';
    if (n > 1 && n < 7) return d.toLocaleDateString([], { weekday: 'long' });
    return d.toLocaleDateString([], d.getFullYear() === new Date().getFullYear() ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' });
  }
  function listTime(ts) {
    var d = new Date(ts); if (isNaN(d.getTime())) return '';
    var n = dayDiff(ts);
    if (n === 0) return fmtTime(ts);
    if (n === 1) return 'Yesterday';
    if (n > 1 && n < 7) return d.toLocaleDateString([], { weekday: 'short' });
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }
  function previewOf(c, mine) {
    var t = String(c || ''); var p;
    if (t.indexOf(IMGP) === 0) p = '\u{1F4F7} Photo';
    else if (parseShare(t)) p = '\u{1F3AC} Shared a post';
    else p = t.replace(/\s+/g, ' ');
    return (mine ? 'You: ' : '') + p;
  }
  var IC = {
    back: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 18-6-6 6-6"/></svg>',
    compose: '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
    self: '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
    search: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>',
    photo: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>',
    send: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5"/><path d="m5 12 7-7 7 7"/></svg>',
    down: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>',
    check: '<svg viewBox="0 0 16 11" width="15" height="10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m1 5.5 3.2 3.2L10 1.5"/></svg>',
    check2: '<svg viewBox="0 0 20 11" width="19" height="10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m1 5.5 3.2 3.2L10 1.5"/><path d="m8 7.5.7.7L14.5 1.5"/></svg>',
    clock: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.3 1.4"/></svg>',
    warn: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13Zm-.8 3.2h1.6v4.3H7.2Zm.8 6.9a.95.95 0 1 1 0-1.9.95.95 0 0 1 0 1.9Z"/></svg>'
  };

  /* ---------- message content kinds ---------- */
  function parseShare(c) {
    var m = /^\u{1F3AC} Shared a BMN Community post(?:: ([\s\S]*?))?\n(https?:\/\/\S+)$/u.exec(String(c || ''));
    if (!m) return null;
    try { var u = new URL(m[2]); if (u.origin !== location.origin) return null; return { caption: (m[1] || '').trim(), url: u.href }; } catch (_) { return null; }
  }
  function linkify(escaped) {
    return escaped.replace(/\bhttps?:\/\/[^\s<]+/g, function (u) {
      var tail = ''; var mm = /[.,!?;:)\]]+$/.exec(u); if (mm) { tail = mm[0]; u = u.slice(0, -tail.length); }
      return '<a href="' + u + '" target="_blank" rel="noopener noreferrer nofollow">' + u + '</a>' + tail;
    });
  }
  var EMO = /^(?:\p{Extended_Pictographic}|️|‍|\s)+$/u;
  function isEmojiOnly(c) { return c.indexOf(IMGP) !== 0 && EMO.test(c) && (c.match(/\p{Extended_Pictographic}/gu) || []).length <= 3; }
  function bodyHTML(m) {
    var c = String(m.content || '');
    if (c.indexOf(IMGP) === 0) {
      var p = c.slice(IMGP.length), cached = S.imgUrls.get(p);
      return '<button type="button" class="bm-imgbtn" data-p="' + esc(p) + '" aria-label="Open photo"><img class="bm-img" data-p="' + esc(p) + '" alt="Photo"' + (cached ? ' src="' + esc(cached) + '"' : '') + '></button>';
    }
    var sh = parseShare(c);
    if (sh) return '<a class="bm-share" href="' + esc(sh.url) + '" data-share="1"><span class="bm-share-ic" aria-hidden="true">\u{1F3AC}</span><span><strong>Shared a BMN post</strong>' + (sh.caption ? '<small>' + esc(sh.caption) + '</small>' : '<small>Tap to open</small>') + '</span></a>';
    return linkify(esc(c));
  }

  /* ---------- data layer ---------- */
  async function msgSelect(build) {
    var s = sb(), tiers = [COLS, 'id,sender_id,recipient_id,content,created_at,read_at', 'id,sender_id,recipient_id,content,created_at'], r = null;
    for (var i = 0; i < tiers.length; i++) {
      r = await build(s.from('messages').select(tiers[i]));
      if (!r.error) return r;
      if (!/column|schema cache|deleted_by|read_at/i.test(String(r.error.message || ''))) return r;
    }
    return r;
  }
  var visibleToMe = function (m, me) { return m.sender_id === me ? !m.deleted_by_sender : !m.deleted_by_recipient; };
  async function ensureProfiles(ids) {
    var s = sb(); if (!s) return;
    if (!window.bmnProfiles) window.bmnProfiles = {};
    var miss = ids.filter(function (id) { return id && !window.bmnProfiles[id]; });
    if (!miss.length) return;
    try {
      var r = await s.from('profiles').select('*').in('id', miss);
      if (!r.error) (r.data || []).forEach(function (p) { window.bmnProfiles[p.id] = Object.assign({}, window.bmnProfiles[p.id] || {}, p); });
    } catch (_) {}
  }
  async function verifiedSession() {
    var c = sb(); if (!c) return { err: 'Messaging is still connecting. Your text is kept. Try again in a moment.' };
    try {
      var r = await c.auth.getSession();
      if (r && r.data && r.data.session && r.data.session.user) return { user: r.data.session.user };
      var g = await c.auth.getUser();
      if (g && g.data && g.data.user) return { user: g.data.user };
      var st = g && g.error && g.error.status, m = String((g && g.error && g.error.message) || '');
      if (!g.error || st === 401 || st === 403 || /session|jwt|token|not authenticated/i.test(m)) return { expired: true };
      return { err: 'Could not verify your sign-in (check your connection). Your text is kept.' };
    } catch (e) { return { err: 'Could not verify your sign-in (check your connection). Your text is kept.' }; }
  }
  function friendly(e) {
    if (e && e.bmnExpired) { setTimeout(function () { try { window.requestCommunityAuth && window.requestCommunityAuth('inbox'); } catch (_) {} }, 150); return 'Your session has expired. Please sign in again. Your message is kept.'; }
    if (e && e.bmnErr) return e.bmnErr;
    var msg = String((e && e.message) || ''), code = e && e.code;
    if (code === '42501' || /row-level security/i.test(msg)) return 'This message could not be sent. Your account may not be able to message this person right now.';
    if (code === 'P0001' && msg) return msg;
    if (/foreign key|violates/i.test(msg)) return 'This person could not be found. Go back and open the conversation again.';
    if (/Failed to fetch|NetworkError|network|timeout/i.test(msg)) return 'No connection. Your message is kept. Tap it to retry.';
    return 'Message not sent' + (msg ? ': ' + msg : '') + '. Tap it to retry.';
  }

  /* conversations: server function when present, client grouping otherwise */
  async function fetchConversations() {
    var s = sb(), me = meId(); if (!s || !me) return null;
    if (S.rpcInbox !== false) {
      try {
        var r = await s.rpc('bmn_inbox_conversations');
        if (!r.error && Array.isArray(r.data)) {
          S.rpcInbox = true;
          var out = new Map();
          r.data.forEach(function (x) {
            out.set(x.peer_id, { peer: x.peer_id, last: { id: x.last_message_id, sender_id: x.last_sender_id, recipient_id: x.last_sender_id === me ? x.peer_id : me, content: x.last_content, created_at: x.last_created_at }, unread: Number(x.unread_count || 0) });
          });
          return out;
        }
        S.rpcInbox = false;
      } catch (_) { S.rpcInbox = false; }
    }
    var res = await msgSelect(function (b) { return b.or('sender_id.eq.' + me + ',recipient_id.eq.' + me).order('created_at', { ascending: false }).limit(400); });
    if (res.error) throw res.error;
    var map = new Map();
    (res.data || []).forEach(function (m) {
      if (!visibleToMe(m, me)) return;
      var peer = m.sender_id === me ? m.recipient_id : m.sender_id;
      if (!map.has(peer)) map.set(peer, { peer: peer, last: m, unread: 0 });
    });
    var un = await fetchUnreadCounts();
    if (un) un.forEach(function (n, peer) { var c = map.get(peer); if (c) c.unread = n; });
    return map;
  }
  async function fetchUnreadCounts() {
    var s = sb(), me = meId(); if (!s || !me) return null;
    try {
      var r = await s.from('messages').select('sender_id').eq('recipient_id', me).is('read_at', null).neq('sender_id', me).limit(2000);
      if (r.error) return null;
      var m = new Map(); (r.data || []).forEach(function (x) { m.set(x.sender_id, (m.get(x.sender_id) || 0) + 1); });
      return m;
    } catch (_) { return null; }
  }
  function recount() {
    var n = 0; S.convs.forEach(function (c) { n += c.unread || 0; });
    S.unreadTotal = n; setBadge(n);
  }
  function setBadge(n) {
    window.__bmnRealUnread = n;
    var b = $('#lgttInboxBadge');
    if (b) { var was = b.hidden; b.hidden = n === 0; if (n) { b.textContent = n > 99 ? '99+' : (n > 9 ? '9+' : String(n)); } if (was && n) { b.style.animation = 'none'; void b.offsetWidth; b.style.animation = ''; } }
    if (R.sub) R.sub.textContent = n ? n + ' unread' : '';
    if (R.backN) { var other = n - ((S.peer && S.convs.get(S.peer) && S.convs.get(S.peer).unread) || 0); R.backN.hidden = !(S.peer && other > 0); R.backN.textContent = other > 99 ? '99+' : other; }
  }
  async function loadConversations(opts) {
    if (!meId()) { renderList(); return; }
    try {
      var map = await fetchConversations(); if (!map) return;
      if (S.peer && S.open && D.visibilityState !== 'hidden') { var cur = map.get(S.peer); if (cur) cur.unread = 0; }
      S.convs = map; S.lastList = Date.now();
      await ensureProfiles(Array.from(map.keys()));
      recount(); if (R.rows) renderList();
    } catch (e) {
      if (R.rows && !(opts && opts.silent)) R.rows.innerHTML = '<div class="bm-empty"><strong>Could not load your messages</strong><p>' + esc(e.message || 'Check your connection and try again.') + '</p><button type="button" class="bm-btn" data-act="retry-list">Try again</button></div>';
    }
  }
  async function fetchThread(peer, before) {
    var s = sb(), me = meId();
    var r = await msgSelect(function (b) {
      var q = b.order('created_at', { ascending: false });
      q = peer === me ? q.eq('sender_id', me).eq('recipient_id', me) : q.or('and(sender_id.eq.' + me + ',recipient_id.eq.' + peer + '),and(sender_id.eq.' + peer + ',recipient_id.eq.' + me + ')');
      if (before) q = q.lt('created_at', before);
      return q.limit(PAGE + 1);
    });
    if (r.error) throw r.error;
    var data = (r.data || []).filter(function (m) { return visibleToMe(m, me); });
    var more = (r.data || []).length > PAGE; if (more) data.pop();
    data.reverse();
    return { rows: data, more: more };
  }
  async function markRead(peer) {
    var s = sb(), me = meId(); if (!s || !me || !peer || peer === me) return;
    var c = S.convs.get(peer); if (c) { c.unread = 0; recount(); if (R.rows) renderList(); }
    try {
      var r = await s.rpc('bmn_mark_messages_read', { p_sender_id: peer });
      if (r.error) throw r.error;
    } catch (_) {
      try { await s.from('messages').update({ read_at: new Date().toISOString() }).eq('sender_id', peer).eq('recipient_id', me).is('read_at', null); } catch (_2) {}
    }
  }
  function scheduleMarkRead(peer) {
    clearTimeout(S.markTimer);
    S.markTimer = setTimeout(function () { if (S.open && S.peer === peer && D.visibilityState !== 'hidden') markRead(peer); }, 350);
  }

  /* ---------- merge / thread state ---------- */
  function sortRows() { S.rows.sort(function (a, b) { var d = new Date(a.created_at) - new Date(b.created_at); return d || String(a.id).localeCompare(String(b.id)); }); }
  function mergeRow(row) {
    var me = meId(), i = S.rows.findIndex(function (m) { return m.id === row.id; });
    if (i >= 0) { S.rows[i] = Object.assign({}, S.rows[i], row, { _pending: false, _failed: false }); return { isNew: false, changed: true }; }
    if (row.sender_id === me) {
      var j = S.rows.findIndex(function (m) { return m._pending && m.content === row.content && m.recipient_id === row.recipient_id; });
      if (j >= 0) { S.rows[j] = Object.assign({}, row); sortRows(); return { isNew: false, changed: true }; }
    }
    S.rows.push(row); sortRows(); return { isNew: true, changed: true };
  }
  function nearBottom() { return !R.msgs || R.msgs.scrollHeight - R.msgs.scrollTop - R.msgs.clientHeight < 160; }

  /* ---------- rendering: list ---------- */
  function renderList() {
    if (!R.rows) return;
    var me = meId();
    if (!me) { R.rows.innerHTML = '<div class="bm-empty"><strong>Sign in to use Messages</strong><p>Your messages stay connected to your BMN account.</p><button type="button" class="bm-btn" data-act="signin">Sign in</button></div>'; return; }
    var q = S.query.trim().toLowerCase();
    var items = Array.from(S.convs.values()).filter(function (c) {
      return !q || (nameOf(c.peer) + ' ' + handleOf(c.peer) + ' ' + String(c.last.content || '')).toLowerCase().indexOf(q) >= 0;
    });
    items.sort(function (a, b) { return new Date(b.last.created_at) - new Date(a.last.created_at); });
    if (!items.length) {
      R.rows.innerHTML = q
        ? '<div class="bm-empty"><strong>No conversations match</strong><p>Try a different name, or find the person below.</p></div>'
        : (S.lastList ? '<div class="bm-empty"><div class="bm-empty-ic" aria-hidden="true">\u{1F4AC}</div><strong>No messages yet</strong><p>Start a conversation with someone from the community.</p><button type="button" class="bm-btn bm-primary" data-act="new">New message</button></div>'
                      : '<div class="bm-empty"><p>Loading your messages…</p></div>');
      return;
    }
    R.rows.innerHTML = items.map(function (c) {
      var self = c.peer === me, mine = c.last.sender_id === me, un = c.unread || 0;
      return '<button type="button" class="bm-row' + (un ? ' unread' : '') + (isFounder(c.peer) ? ' founder' : '') + '" data-peer="' + esc(c.peer) + '" role="listitem" aria-label="' + esc((self ? 'Saved messages' : nameOf(c.peer)) + (un ? ', ' + un + ' unread' : '')) + '">'
        + avatarHTML(c.peer)
        + '<span class="bm-meta"><span class="bm-top"><strong>' + esc(self ? 'You (saved messages)' : nameOf(c.peer)) + '</strong><time>' + esc(listTime(c.last.created_at)) + '</time></span>'
        + '<span class="bm-bot"><small>' + esc(previewOf(c.last.content, mine)) + '</small>' + (un ? '<b class="bm-badge">' + (un > 99 ? '99+' : un) + '</b>' : '') + '</span></span></button>';
    }).join('');
  }
  var peopleTimer = 0, peopleSeq = 0;
  function sanitizeQ(q) { return String(q || '').replace(/[^\p{L}\p{N}_ ]/gu, '').trim().slice(0, 40); }
  async function searchPeople(q, into) {
    var s = sb(), me = meId(); if (!s || !me) return [];
    q = sanitizeQ(q); if (q.length < 2) return [];
    var r = await s.from('profiles').select('*').or('username.ilike.%' + q + '%,display_name.ilike.%' + q + '%').neq('id', me).limit(15);
    if (r.error) throw r.error;
    (r.data || []).forEach(function (p) { if (!window.bmnProfiles) window.bmnProfiles = {}; window.bmnProfiles[p.id] = Object.assign({}, window.bmnProfiles[p.id] || {}, p); });
    return r.data || [];
  }
  function peopleHTML(list) {
    return list.map(function (p) {
      return '<button type="button" class="bm-row bm-person" data-peer="' + esc(p.id) + '">' + avatarHTML(p.id) + '<span class="bm-meta"><span class="bm-top"><strong>' + esc(nameOf(p.id)) + '</strong></span><span class="bm-bot"><small>' + esc(handleOf(p.id) || 'BMN member') + '</small></span></span></button>';
    }).join('');
  }
  function onSearchInput() {
    S.query = R.search.value; renderList();
    clearTimeout(peopleTimer);
    var q = sanitizeQ(S.query);
    if (q.length < 2) { R.people.innerHTML = ''; return; }
    var seq = ++peopleSeq;
    peopleTimer = setTimeout(async function () {
      try {
        var res = await searchPeople(q); if (seq !== peopleSeq) return;
        var known = new Set(Array.from(S.convs.keys()));
        var fresh = res.filter(function (p) { return !known.has(p.id); });
        R.people.innerHTML = fresh.length ? '<div class="bm-sec">People</div>' + peopleHTML(fresh) : '';
      } catch (_) { if (seq === peopleSeq) R.people.innerHTML = ''; }
    }, 260);
  }

  /* ---------- rendering: thread ---------- */
  function statusHTML(m) {
    if (m.sender_id !== meId() || m.sender_id === m.recipient_id) return '';
    if (m._failed) return '<span class="bm-st fail">' + IC.warn + '</span>';
    if (m._pending) return '<span class="bm-st wait">' + IC.clock + '</span>';
    return '<span class="bm-st ' + (m.read_at ? 'read' : 'sent') + '" title="' + (m.read_at ? 'Read' : 'Sent') + '">' + (m.read_at ? IC.check2 : IC.check) + '</span>';
  }
  function renderThread(o) {
    o = o || {};
    if (!R.msgs) return;
    var me = meId(), rows = S.rows;
    var prevTop = R.msgs.scrollTop, prevH = R.msgs.scrollHeight, stick = o.stick || nearBottom();
    if (!rows.length) {
      R.msgs.innerHTML = S.loadingThread ? '<div class="bm-empty bm-loading"><p>Loading…</p></div>' : '<div class="bm-empty"><div class="bm-empty-ic" aria-hidden="true">\u{1F44B}</div><strong>No messages yet</strong><p>Say hello to ' + esc(S.peer === me ? 'yourself' : nameOf(S.peer)) + '.</p></div>';
      return;
    }
    var out = S.hasMore ? '<button type="button" class="bm-more" data-act="older">' + (S.loadingMore ? 'Loading…' : 'Load earlier messages') + '</button>' : '';
    var curDay = '', open = false;
    rows.forEach(function (m, i) {
      var t = new Date(m.created_at).getTime(), dk = String(dayStart(new Date(t)));
      if (dk !== curDay) { if (open) out += '</section>'; out += '<section class="bm-dayg"><div class="bm-day"><span>' + esc(dayLabel(m.created_at)) + '</span></div>'; curDay = dk; open = true; }
      if (S.unreadFrom && m.id === S.unreadFrom) out += '<div class="bm-unread" id="bmUnreadDiv"><span>Unread messages</span></div>';
      var prev = rows[i - 1], next = rows[i + 1];
      var sameP = function (a, b) { return a && b && a.sender_id === b.sender_id && Math.abs(new Date(b.created_at) - new Date(a.created_at)) < 5 * 60000 && dayStart(new Date(a.created_at)) === dayStart(new Date(b.created_at)) && !(S.unreadFrom && b.id === S.unreadFrom); };
      var first = !sameP(prev, m), last = !sameP(m, next);
      var mine = m.sender_id === me, c = String(m.content || ''), img = c.indexOf(IMGP) === 0, emo = isEmojiOnly(c), share = !!parseShare(c);
      out += '<div class="bm-msg' + (mine ? ' mine' : '') + (first ? ' g-first' : '') + (last ? ' g-last' : '') + (emo ? ' emoji' : '') + (img ? ' has-img' : '') + (share ? ' has-share' : '') + (m._pending ? ' pending' : '') + (m._failed ? ' failed' : '') + '" data-id="' + esc(m.id) + '"' + (m._failed ? ' role="button" tabindex="0" aria-label="Message not sent. Tap to retry."' : '') + '>'
        + '<div class="bm-bub">' + bodyHTML(m) + '<span class="bm-meta2"><time>' + esc(fmtTime(m.created_at)) + '</time>' + statusHTML(m) + '</span></div>'
        + (m._failed ? '<div class="bm-fail">Not sent. Tap to retry</div>' : '') + '</div>';
    });
    if (open) out += '</section>';
    R.msgs.innerHTML = out;
    hydrateImgs();
    if (o.toUnread && $('#bmUnreadDiv', R.msgs)) { var d = $('#bmUnreadDiv', R.msgs); R.msgs.scrollTop = Math.max(0, d.offsetTop - 110); }
    else if (o.anchorOlder) R.msgs.scrollTop = prevTop + (R.msgs.scrollHeight - prevH);
    else if (stick) R.msgs.scrollTop = R.msgs.scrollHeight;
    else R.msgs.scrollTop = prevTop;
    updateFab();
  }
  async function hydrateImgs() {
    var imgs = $$('img.bm-img:not([src])', R.msgs); if (!imgs.length) return;
    var s = sb(); if (!s) return;
    try {
      var paths = Array.from(new Set(imgs.map(function (i) { return i.dataset.p; })));
      var r = await s.storage.from('community-media').createSignedUrls(paths, 3600);
      if (r.error) throw r.error;
      (r.data || []).forEach(function (x) { if (x.signedUrl) S.imgUrls.set(x.path, x.signedUrl); });
      imgs.forEach(function (i) { var u = S.imgUrls.get(i.dataset.p); if (u) { i.src = u; i.classList.add('ok'); } else i.alt = 'Photo unavailable'; });
    } catch (e) { imgs.forEach(function (i) { i.alt = 'Photo unavailable'; }); note('Could not load a photo.', true); }
  }
  function updateFab() {
    if (!R.fab) return;
    var far = R.msgs.scrollHeight - R.msgs.scrollTop - R.msgs.clientHeight > 260;
    if (!far) S.newBelow = 0;
    R.fab.hidden = !far;
    R.fabN.hidden = !S.newBelow; R.fabN.textContent = S.newBelow > 99 ? '99+' : S.newBelow;
  }
  function note(t, err) { if (!R.note) return; R.note.textContent = t || ''; R.note.classList.toggle('err', !!err); R.note.classList.toggle('on', !!t); }

  /* ---------- chat lifecycle ---------- */
  async function openChat(id) {
    var me = meId();
    if (!me) { if (typeof window.requestCommunityAuth === 'function') window.requestCommunityAuth('inbox'); return; }
    id = id || me;
    if (!UUID.test(String(id))) { toast('That conversation could not be opened.'); return; }
    if (!S.open) open(true);
    S.peer = id; S.rows = []; S.hasMore = false; S.unreadFrom = null; S.newBelow = 0; S.loadingThread = true;
    await ensureProfiles([id]);
    if (id !== me && !prof(id).id) { S.peer = null; S.loadingThread = false; toast('That member could not be found.'); return; }
    var stage = D.getElementById('lgttStage'); if (stage) stage.classList.add('bmn-chat-open');
    R.root.dataset.view = 'chat'; R.chat.setAttribute('aria-hidden', 'false');
    paintHeader(); applyWall(); renderThread();
    try {
      var t = await fetchThread(id);
      if (S.peer !== id) return;
      S.rows = t.rows; S.hasMore = t.more; S.loadingThread = false;
      var first = t.rows.find(function (m) { return m.recipient_id === me && m.sender_id !== me && !m.read_at; });
      S.unreadFrom = first ? first.id : null;
      renderThread({ toUnread: !!first, stick: !first });
      if (D.visibilityState !== 'hidden') scheduleMarkRead(id);
    } catch (e) {
      S.loadingThread = false;
      if (S.peer === id) R.msgs.innerHTML = '<div class="bm-empty"><strong>Could not load this conversation</strong><p>' + esc(e.message || 'Check your connection.') + '</p><button type="button" class="bm-btn" data-act="retry-thread">Try again</button></div>';
    }
    setBadge(S.unreadTotal);
    if (window.matchMedia && matchMedia('(pointer:fine)').matches) setTimeout(function () { try { R.input.focus({ preventScroll: true }); } catch (_) {} }, 250);
  }
  function backToList() {
    S.peer = null; S.rows = []; S.unreadFrom = null; S.newBelow = 0;
    var stage = D.getElementById('lgttStage'); if (stage) stage.classList.remove('bmn-chat-open');
    if (R.root) { R.root.dataset.view = 'list'; R.chat.setAttribute('aria-hidden', 'true'); }
    try { R.input.blur(); } catch (_) {}
    closeSheet(); setBadge(S.unreadTotal);
    loadConversations({ silent: true });
  }
  function paintHeader() {
    var me = meId(), id = S.peer; if (!id) return;
    R.name.textContent = id === me ? 'Saved messages' : nameOf(id);
    R.sub2.textContent = id === me ? 'Notes to yourself' : (handleOf(id) || 'BMN Community');
    R.av.innerHTML = avatarHTML(id);
    R.who.classList.toggle('founder', isFounder(id));
    setBadge(S.unreadTotal);
  }
  async function loadOlder() {
    if (S.loadingMore || !S.hasMore || !S.peer || !S.rows.length) return;
    S.loadingMore = true; var peer = S.peer; renderThread({ anchorOlder: true });
    try {
      var t = await fetchThread(peer, S.rows[0].created_at);
      if (S.peer !== peer) return;
      var have = new Set(S.rows.map(function (m) { return m.id; }));
      S.rows = t.rows.filter(function (m) { return !have.has(m.id); }).concat(S.rows); S.hasMore = t.more;
    } catch (e) { note('Could not load earlier messages.', true); }
    S.loadingMore = false; renderThread({ anchorOlder: true });
  }
  async function refreshThread() {
    var peer = S.peer; if (!peer) return;
    try {
      var t = await fetchThread(peer); if (S.peer !== peer) return;
      var incoming = 0, near = nearBottom(), changed = false;
      var before = JSON.stringify(S.rows.filter(function (m) { return !m._pending && !m._failed; }).slice(-PAGE).map(function (m) { return [m.id, m.read_at]; }));
      t.rows.forEach(function (m) { var r = mergeRow(m); if (r.isNew && m.sender_id !== meId()) incoming++; });
      // drop rows the server no longer returns (cleared conversation)
      var keep = new Set(t.rows.map(function (m) { return m.id; })), oldest = t.rows.length ? t.rows[0].created_at : null;
      S.rows = S.rows.filter(function (m) { return m._pending || m._failed || keep.has(m.id) || (oldest && new Date(m.created_at) < new Date(oldest)); });
      var after = JSON.stringify(S.rows.filter(function (m) { return !m._pending && !m._failed; }).slice(-PAGE).map(function (m) { return [m.id, m.read_at]; }));
      changed = before !== after;
      if (changed) { renderThread({ stick: near }); if (!near && incoming) { S.newBelow += incoming; updateFab(); } }
      if (incoming && D.visibilityState !== 'hidden') scheduleMarkRead(peer);
    } catch (_) {}
  }

  /* ---------- sending ---------- */
  function queue(content) {
    var me = meId(), peer = S.peer;
    var row = { id: 'tmp-' + (++S.tmp), sender_id: me, recipient_id: peer, content: content, created_at: new Date().toISOString(), read_at: null, _pending: true };
    S.rows.push(row); renderThread({ stick: true }); haptic('send');
    return doSend(row);
  }
  async function doSend(row) {
    var s = sb(); row._pending = true; row._failed = false;
    try {
      if (navigator.onLine === false) throw { bmnErr: 'You are offline. Your message is kept. Tap it to retry.' };
      var v = await verifiedSession(); if (v.expired) throw { bmnExpired: true }; if (v.err) throw { bmnErr: v.err };
      var uid = v.user.id;
      var r = await s.from('messages').insert({ sender_id: uid, recipient_id: row.recipient_id, content: row.content }).select('id,sender_id,recipient_id,content,created_at,read_at').single();
      if (r.error) throw r.error;
      var real = r.data;
      var i = S.rows.findIndex(function (m) { return m === row || m.id === row.id; });
      var dupe = S.rows.findIndex(function (m) { return m.id === real.id; });
      if (dupe >= 0 && i >= 0 && dupe !== i) S.rows.splice(i, 1); else if (i >= 0) S.rows[i] = real;
      sortRows(); if (S.peer === row.recipient_id) renderThread({ stick: true });
      if (row.recipient_id !== uid) { try { s.from('notifications').insert({ user_id: row.recipient_id, actor_id: uid, type: 'message', message: 'sent you a message' }).then(function () {}, function () {}); } catch (_) {} }
      var c = S.convs.get(row.recipient_id) || { peer: row.recipient_id, unread: 0 }; c.last = real; S.convs.set(row.recipient_id, c);
      if (R.rows) renderList();
      note('');
    } catch (e) {
      row._pending = false; row._failed = true; row._err = friendly(e);
      if (S.peer === row.recipient_id) { renderThread({ stick: true }); note(row._err, true); }
    }
  }
  function retry(id) {
    var row = S.rows.find(function (m) { return m.id === id && m._failed; }); if (!row) return;
    row._failed = false; row._pending = true; note(''); renderThread({ stick: true }); doSend(row);
  }
  function submit() {
    var me = meId(), text = R.input.value.trim();
    if (!me) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    if (!S.peer || !text) return;
    if (!UUID.test(String(S.peer))) { note('This conversation has no valid recipient. Go back and open it again.', true); return; }
    if (text.length > MAX_LEN) { note('Messages can be up to ' + MAX_LEN + ' characters.', true); return; }
    R.input.value = ''; autosize(); syncSend(); note('');
    queue(text);
    try { R.input.focus({ preventScroll: true }); } catch (_) {}
  }
  async function sendImage(file) {
    var s = sb(), me = meId();
    if (!file) return;
    if (!me) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    if (!s || !S.peer) return;
    if (!/^image\//.test(file.type)) { note('Please choose a photo.', true); return; }
    if (file.size > 25 * 1024 * 1024) { note('That photo is larger than 25 MB. Choose a smaller one.', true); return; }
    if (navigator.onLine === false) { note('You are offline. Reconnect to send photos.', true); return; }
    var peer = S.peer; note('Sending photo…');
    try {
      var v = await verifiedSession(); if (v.expired) throw { bmnExpired: true }; if (v.err) throw { bmnErr: v.err };
      var uid = v.user.id;
      var blob = await new Promise(function (res, rej) {
        var url = URL.createObjectURL(file), im = new Image();
        im.onload = function () { var k = Math.min(1, 1600 / Math.max(im.width, im.height)), c = D.createElement('canvas'); c.width = Math.round(im.width * k); c.height = Math.round(im.height * k); c.getContext('2d').drawImage(im, 0, 0, c.width, c.height); URL.revokeObjectURL(url); c.toBlob(function (b) { b ? res(b) : rej(new Error('Could not process this photo')); }, 'image/jpeg', 0.82); };
        im.onerror = function () { URL.revokeObjectURL(url); rej(new Error('This photo format is not supported')); };
        im.src = url;
      });
      var path = uid + '/messages/' + Date.now() + '-' + Math.random().toString(36).slice(2, 8) + '.jpg';
      var up = await s.storage.from('community-media').upload(path, blob, { cacheControl: '2592000', upsert: false, contentType: 'image/jpeg' });
      if (up.error) throw up.error;
      S.imgUrls.set(path, URL.createObjectURL(blob));
      var r = await s.from('messages').insert({ sender_id: uid, recipient_id: peer, content: IMGP + path }).select('id,sender_id,recipient_id,content,created_at,read_at').single();
      if (r.error) { try { await s.storage.from('community-media').remove([path]); } catch (_) {} throw r.error; }
      if (S.peer === peer) { mergeRow(r.data); renderThread({ stick: true }); }
      var c = S.convs.get(peer) || { peer: peer, unread: 0 }; c.last = r.data; S.convs.set(peer, c); renderList();
      if (peer !== uid) { try { s.from('notifications').insert({ user_id: peer, actor_id: uid, type: 'message', message: 'sent you a message' }).then(function () {}, function () {}); } catch (_) {} }
      note(''); haptic('send');
    } catch (e) { note(e && (e.bmnExpired || e.bmnErr) ? friendly(e) : 'Photo not sent: ' + ((e && e.message) || 'check your connection'), true); }
  }

  /* ---------- realtime + polling ---------- */
  function teardownRT() { try { S.ch && S.ch.unsubscribe && S.ch.unsubscribe(); } catch (_) {} S.ch = null; S.chUser = null; }
  function setupRT() {
    var s = sb(), me = meId();
    if (!s || !me || !s.channel) return;
    if (S.ch && S.chUser === me) return;
    teardownRT();
    try {
      var on = function (filter) { return { event: '*', schema: 'public', table: 'messages', filter: filter }; };
      S.ch = s.channel('bmn-messages-' + me)
        .on('postgres_changes', on('recipient_id=eq.' + me), onRT)
        .on('postgres_changes', on('sender_id=eq.' + me), onRT)
        .subscribe();
      S.chUser = me;
    } catch (_) { S.ch = null; }
  }
  function onRT(p) {
    var me = meId(), row = p && p.new; if (!me || !row || !row.id) return;
    if (row.sender_id !== me && row.recipient_id !== me) return;
    S.lastRT = Date.now();
    var gone = (row.sender_id === me && row.deleted_by_sender) || (row.recipient_id === me && row.deleted_by_recipient);
    var peer = row.sender_id === me ? row.recipient_id : row.sender_id;
    if (gone) { S.rows = S.rows.filter(function (m) { return m.id !== row.id; }); if (S.peer === peer) renderThread(); loadConversations({ silent: true }); return; }
    var incoming = row.sender_id !== me && p.eventType === 'INSERT';
    var viewing = S.open && S.peer === peer && D.visibilityState !== 'hidden';
    var c = S.convs.get(peer);
    if (p.eventType === 'INSERT') {
      if (!c) { c = { peer: peer, unread: 0 }; S.convs.set(peer, c); ensureProfiles([peer]).then(function () { if (R.rows) renderList(); }); }
      if (!c.last || new Date(row.created_at) >= new Date(c.last.created_at)) c.last = row;
      if (incoming && !viewing) { c.unread = (c.unread || 0) + 1; haptic('tap'); }
      recount(); if (R.rows) renderList();
    }
    if (S.open && S.peer === peer) {
      var near = nearBottom(), r = mergeRow(row);
      renderThread({ stick: near });
      if (incoming) { if (!near) { S.newBelow++; updateFab(); } if (viewing) scheduleMarkRead(peer); }
    }
  }
  function poll() {
    if (S.pollBusy) return;
    var me = meId();
    if (!me) { if (S.ch) teardownRT(); if (S.unreadTotal) { S.convs = new Map(); recount(); } return; }
    if (D.visibilityState === 'hidden') return;
    setupRT();
    S.pollBusy = true; S.tick++;
    var jobs = [];
    var rtFresh = Date.now() - S.lastRT < 12000;
    if (S.open && S.peer) { if (!rtFresh || S.tick % 6 === 0) jobs.push(refreshThread()); }
    if (S.open && !S.peer) { if (!rtFresh || S.tick % 6 === 0) jobs.push(loadConversations({ silent: true })); }
    if (!S.open && (S.tick % 4 === 0 || S.lastList === 0)) jobs.push(refreshUnreadOnly());
    Promise.all(jobs).catch(function () {}).then(function () { S.pollBusy = false; });
  }
  async function refreshUnreadOnly() {
    if (S.rpcInbox === true || S.convs.size === 0 && S.lastList === 0) { await loadConversations({ silent: true }); return; }
    var un = await fetchUnreadCounts(); if (!un) return;
    var changed = false;
    S.convs.forEach(function (c, peer) { var n = un.get(peer) || 0; if (c.unread !== n) { c.unread = n; changed = true; } });
    un.forEach(function (n, peer) { if (!S.convs.has(peer)) changed = true; });
    if (changed || S.lastList === 0) await loadConversations({ silent: true }); else recount();
  }

  /* ---------- sheets, toast ---------- */
  function toast(t) { note(t, true); setTimeout(function () { if (R.note && R.note.textContent === t) note(''); }, 3500); if (!S.open || !R.root) { try { window.setBackendStatus && window.setBackendStatus(t, true); } catch (_) {} } }
  function closeSheet() { if (R.sheet) { R.sheet.hidden = true; R.sheet.innerHTML = ''; R.sheet.onclick = null; } }
  function sheet(title, items, extra) {
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass" role="dialog" aria-modal="true" aria-label="' + esc(title) + '"><div class="bm-grab"></div><h2>' + esc(title) + '</h2>' + (extra || '') + items.map(function (it, i) {
      return '<button type="button" class="bm-act' + (it.danger ? ' danger' : '') + '" data-i="' + i + '">' + (it.icon || '') + '<span>' + esc(it.label) + '</span></button>';
    }).join('') + '<button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
    R.sheet.onclick = function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var b = e.target.closest('.bm-act[data-i]'); if (!b) return;
      var it = items[+b.dataset.i]; closeSheet(); it && it.run && it.run();
    };
    var f = $('.bm-act', R.sheet); if (f) f.focus({ preventScroll: true });
  }
  function confirmSheet(title, msg, okLabel) {
    return new Promise(function (res) {
      R.sheet.hidden = false;
      R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass" role="alertdialog" aria-modal="true" aria-label="' + esc(title) + '"><div class="bm-grab"></div><h2>' + esc(title) + '</h2><p class="bm-p">' + esc(msg) + '</p><button type="button" class="bm-act danger" data-ok="1"><span>' + esc(okLabel) + '</span></button><button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
      R.sheet.onclick = function (e) {
        if (e.target.closest('[data-ok]')) { closeSheet(); res(true); } else if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); res(false); }
      };
    });
  }
  async function clearConversation(peer) {
    var s = sb(), me = meId(); if (!s || !me || !peer || peer === me) return; // saved messages cannot be cleared: the server function rejects self-chat and RLS has no UPDATE policy
    var ok = await confirmSheet('Clear this conversation?', 'Messages are removed from your view only. ' + nameOf(peer) + ' keeps their copy.', 'Clear conversation');
    if (!ok) return;
    try {
      var r = await s.rpc('bmn_clear_conversation', { p_peer: peer });
      if (r.error) throw r.error;
      S.convs.delete(peer); recount();
      if (S.peer === peer) { S.rows = []; S.hasMore = false; renderThread(); }
      renderList(); toast('Conversation cleared.');
      if (S.peer === peer) backToList();
    } catch (e) { note('Could not clear this conversation' + (e && e.message ? ': ' + e.message : '') + '.', true); }
  }
  function chatMenu() {
    var me = meId(), peer = S.peer; if (!peer) return;
    var items = [];
    if (peer !== me) items.push({ label: 'View profile', icon: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>', run: function () { close(true); try { window.LGTT && window.LGTT.openProfile(peer); } catch (_) {} } });
    items.push({ label: 'Chat wallpaper', icon: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="4"/><path d="M3 15l5-5 4 4 3-3 6 6"/></svg>', run: wallpaperSheet });
    if (peer !== me) items.push({ label: 'Clear conversation', danger: true, icon: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/></svg>', run: function () { clearConversation(peer); } });
    sheet(peer === me ? 'Saved messages' : nameOf(peer), items);
  }
  function rowMenu(peer) {
    var c = S.convs.get(peer), items = [];
    items.push({ label: 'Open', run: function () { openChat(peer); } });
    if (c && c.unread) items.push({ label: 'Mark as read', run: function () { markRead(peer); } });
    if (peer !== meId()) items.push({ label: 'Clear conversation', danger: true, run: function () { clearConversation(peer); } });
    sheet(peer === meId() ? 'Saved messages' : nameOf(peer), items);
  }
  function newMessageSheet() {
    if (!meId()) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="New message"><div class="bm-grab"></div><h2>New message</h2><label class="bm-search bm-glass-in">' + IC.search + '<input type="search" id="bmNewQ" placeholder="Search people by name or @username" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Search people"></label><div class="bm-people" id="bmNewList" aria-live="polite"></div><button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
    var list = $('#bmNewList', R.sheet), q = $('#bmNewQ', R.sheet), seq = 0, timer = 0;
    var show = function (arr, empty) { list.innerHTML = arr.length ? peopleHTML(arr) : '<div class="bm-empty small"><p>' + esc(empty) + '</p></div>'; };
    // suggestions: people the user follows (real follow data); search replaces them
    (async function () {
      try {
        var f = window.bmnFollowing; var ids = f && f.size ? Array.from(f).slice(0, 30) : [];
        if (!ids.length) { show([], 'Type a name or @username to find someone.'); return; }
        await ensureProfiles(ids);
        show(ids.filter(function (id) { return id !== meId() && prof(id).id; }).map(function (id) { return prof(id); }), 'Type a name or @username to find someone.');
        list.insertAdjacentHTML('afterbegin', '<div class="bm-sec">People you follow</div>');
      } catch (_) { show([], 'Type a name or @username to find someone.'); }
    })();
    q.oninput = function () {
      clearTimeout(timer); var v = sanitizeQ(q.value);
      if (v.length < 2) return;
      var my = ++seq;
      timer = setTimeout(async function () {
        try { var r = await searchPeople(v); if (my === seq) show(r, 'No one found for “' + v + '”.'); } catch (e) { if (my === seq) show([], 'Search is unavailable right now.'); }
      }, 260);
    };
    R.sheet.onclick = function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var b = e.target.closest('[data-peer]'); if (b) { var id = b.dataset.peer; closeSheet(); openChat(id); }
    };
    setTimeout(function () { try { q.focus(); } catch (_) {} }, 120);
  }

  /* ---------- wallpaper (per conversation, this device only; same storage keys as before) ---------- */
  var WP = [['Default', ''], ['Midnight', 'linear-gradient(160deg,#0b1020,#1a2347)'], ['Storm', 'linear-gradient(160deg,#1c2b4a,#3b5b8f)'], ['Violet', 'linear-gradient(160deg,#1b1038,#5b3a9e)'], ['Cyan', 'linear-gradient(160deg,#06222e,#0e7490)'], ['Pearl', 'linear-gradient(160deg,#e8edf7,#b9c4dc)'], ['Ember', 'linear-gradient(160deg,#2a0f1a,#8a3b4f)'], ['Forest', 'linear-gradient(160deg,#08201a,#1f6b53)'],
    ['Doodle', 'url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%27120%27 height=%27120%27%3E%3Cg fill=%27none%27 stroke=%27%23ffffff%27 stroke-opacity=%27.07%27 stroke-width=%271.6%27 stroke-linecap=%27round%27%3E%3Ccircle cx=%2724%27 cy=%2724%27 r=%278%27/%3E%3Cpath d=%27M70 18l10 10M80 18L70 28%27/%3E%3Cpath d=%27M20 80q8-12 16 0t16 0%27/%3E%3Cpath d=%27M84 76l8 14H76z%27/%3E%3Crect x=%2750%27 y=%2754%27 width=%2714%27 height=%2714%27 rx=%273%27/%3E%3C/g%3E%3C/svg%3E"),linear-gradient(160deg,#0b1020,#1a2347)']];
  var wpKey = function (id) { return 'bmn-chat-wp:' + id; };
  var wpGet = function (id) { try { return localStorage.getItem(wpKey(id)) || ''; } catch (_) { return ''; } };
  var wpSet = function (id, v) { try { v ? localStorage.setItem(wpKey(id), v) : localStorage.removeItem(wpKey(id)); return true; } catch (_) { return false; } };
  function applyWall() {
    if (!R.wall) return; var v = S.peer ? wpGet(S.peer) : '';
    R.wall.style.backgroundImage = v && v.indexOf('data:') === 0 ? 'url("' + v + '")' : (v || '');
    R.wall.style.backgroundSize = v && v.indexOf('url(') === 0 ? '120px 120px,cover' : 'cover';
    R.wall.style.backgroundRepeat = v && v.indexOf('url(') === 0 ? 'repeat,no-repeat' : 'no-repeat';
    R.wall.classList.toggle('on', !!v);
  }
  function wallpaperSheet() {
    var peer = S.peer; if (!peer) return;
    var cur = wpGet(peer);
    var grid = '<p class="bm-p">Saved on this device only. It is not synced to your account.</p><div class="bm-wp-grid">' + WP.map(function (p) { return '<button type="button" class="bm-wp" data-v="' + esc(p[1]) + '" title="' + esc(p[0]) + '" aria-label="' + esc(p[0]) + ' wallpaper" aria-pressed="' + String(p[1] === cur) + '" style="background:' + (p[1] ? esc(p[1]) : 'rgba(128,128,128,.25)') + '"></button>'; }).join('') + '</div>';
    sheet('Chat wallpaper', [{ label: 'Upload image', run: function () { R.wpFile.click(); } }, { label: 'Reset to default', run: function () { wpSet(peer, ''); applyWall(); } }], grid);
    var base = R.sheet.onclick;
    R.sheet.onclick = function (e) {
      var b = e.target.closest('.bm-wp');
      if (!b) { base(e); return; }
      if (!wpSet(peer, b.dataset.v)) note('Wallpaper could not be saved on this device.', true);
      applyWall(); $$('.bm-wp', R.sheet).forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
    };
  }
  function onWallFile() {
    var f = R.wpFile.files && R.wpFile.files[0]; R.wpFile.value = ''; if (!f || !S.peer) return;
    if (!/^image\//.test(f.type)) { note('Please choose an image file.', true); return; }
    var peer = S.peer, img = new Image(), url = URL.createObjectURL(f);
    img.onload = function () {
      var k = Math.min(1, 1100 / Math.max(img.width, img.height)), c = D.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k); c.getContext('2d').drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
      var out = ''; try { out = c.toDataURL('image/jpeg', 0.72); } catch (_) {}
      if (!out || !wpSet(peer, out)) { note('That image is too large to save as a wallpaper on this device.', true); return; }
      if (S.peer === peer) applyWall(); note('');
    };
    img.onerror = function () { URL.revokeObjectURL(url); note('That image could not be read.', true); };
    img.src = url;
  }

  /* ---------- composer ---------- */
  function autosize() { R.input.style.height = 'auto'; R.input.style.height = Math.min(R.input.scrollHeight, 132) + 'px'; }
  function syncSend() { var has = !!R.input.value.trim(); R.form.classList.toggle('has-text', has); R.send.disabled = !has; R.quick.hidden = has; }
  function keyboard() {
    if (!window.visualViewport) return;
    var vv = window.visualViewport;
    var upd = function () {
      var kb = Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop));
      D.documentElement.style.setProperty('--bmn-kb', kb > 80 ? kb + 'px' : '0px');
      if (R.root) R.root.classList.toggle('kb', kb > 80);
      if (kb > 80 && S.open && S.peer && R.msgs) R.msgs.scrollTop = R.msgs.scrollHeight;
    };
    vv.addEventListener('resize', upd); vv.addEventListener('scroll', upd);
  }

  /* ---------- build + wiring ---------- */
  function build() {
    if (S.built) return;
    var root = D.createElement('section');
    root.id = 'bmnMsg'; root.dataset.view = 'list'; root.setAttribute('aria-label', 'Messages');
    root.innerHTML =
      '<section class="bm-list" aria-label="Conversations">'
      + '<header class="bm-bar"><button type="button" class="bm-circle bm-glass" id="bmClose" aria-label="Close messages">' + IC.back + '</button>'
      + '<div class="bm-title bm-glass"><h1>Messages</h1><small id="bmSub" aria-live="polite"></small></div>'
      + '<button type="button" class="bm-circle bm-glass" id="bmSelf" aria-label="Saved messages (message yourself)">' + IC.self + '</button>'
      + '<button type="button" class="bm-circle bm-glass bm-accent" id="bmNew" aria-label="New message">' + IC.compose + '</button></header>'
      + '<div class="bm-scroll" id="bmListScroll"><label class="bm-search bm-glass-in">' + IC.search + '<input id="bmSearch" type="search" placeholder="Search messages or people" autocomplete="off" aria-label="Search messages or people"></label>'
      + '<div class="bm-rows" id="bmRows" role="list"></div><div id="bmPeople"></div></div></section>'
      + '<section class="bm-chat" id="bmChat" aria-label="Conversation" aria-hidden="true"><div class="bm-wall" id="bmWall" aria-hidden="true"></div>'
      + '<header class="bm-chead"><button type="button" class="bm-circle bm-glass bm-backc" id="bmBack" aria-label="Back to messages">' + IC.back + '<b id="bmBackN" hidden></b></button>'
      + '<button type="button" class="bm-pill bm-glass" id="bmWho" aria-haspopup="dialog" aria-label="Conversation options"><strong id="bmName"></strong><small id="bmSub2"></small></button>'
      + '<button type="button" class="bm-circle bm-glass bm-avc" id="bmAv" aria-label="Conversation options"></button></header>'
      + '<div class="bm-msgs" id="bmMsgs" role="log" aria-live="polite" aria-relevant="additions" tabindex="-1"></div>'
      + '<form class="bm-composer" id="bmForm" autocomplete="off">'
      + '<button type="button" class="bm-fab bm-glass" id="bmFab" hidden aria-label="Jump to latest messages">' + IC.down + '<b id="bmFabN" hidden></b></button>'
      + '<div class="bm-note" id="bmNote" role="status" aria-live="polite"></div>'
      + '<div class="bm-quick" id="bmQuick" role="group" aria-label="Quick reactions"><button type="button" data-q="❤️" aria-label="Send heart">❤️</button><button type="button" data-q="\u{1F602}" aria-label="Send laughing">\u{1F602}</button><button type="button" data-q="\u{1F44D}" aria-label="Send thumbs up">\u{1F44D}</button><button type="button" data-q="\u{1F44B}" aria-label="Send wave">\u{1F44B}</button></div>'
      + '<div class="bm-cbar"><button type="button" class="bm-circle bm-glass" id="bmAttach" aria-label="Send a photo">' + IC.photo + '</button>'
      + '<div class="bm-input bm-glass"><textarea id="bmInput" rows="1" maxlength="' + MAX_LEN + '" placeholder="Message" aria-label="Message" enterkeyhint="send"></textarea></div>'
      + '<button type="submit" class="bm-circle bm-send" id="bmSend" disabled aria-label="Send message">' + IC.send + '</button></div></form>'
      + '<input type="file" id="bmFile" accept="image/*" hidden><input type="file" id="bmWpFile" accept="image/*" hidden></section>'
      + '<div class="bm-sheet" id="bmSheet" hidden></div>';
    (D.getElementById('lgttStage') || D.body).appendChild(root);
    R = { root: root, rows: $('#bmRows', root), people: $('#bmPeople', root), search: $('#bmSearch', root), sub: $('#bmSub', root), chat: $('#bmChat', root), wall: $('#bmWall', root),
      msgs: $('#bmMsgs', root), fab: $('#bmFab', root), fabN: $('#bmFabN', root), note: $('#bmNote', root), form: $('#bmForm', root), input: $('#bmInput', root), send: $('#bmSend', root),
      quick: $('#bmQuick', root), name: $('#bmName', root), sub2: $('#bmSub2', root), av: $('#bmAv', root), who: $('#bmWho', root), backN: $('#bmBackN', root), sheet: $('#bmSheet', root), file: $('#bmFile', root), wpFile: $('#bmWpFile', root) };
    S.built = true;

    $('#bmClose', root).onclick = function () { close(); };
    $('#bmSelf', root).onclick = function () { openChat(meId()); };
    $('#bmNew', root).onclick = newMessageSheet;
    $('#bmBack', root).onclick = backToList;
    R.who.onclick = chatMenu; R.av.onclick = chatMenu;
    R.search.oninput = onSearchInput;
    R.rows.addEventListener('click', function (e) {
      if (S.suppress) { S.suppress = false; return; }
      var b = e.target.closest('[data-act]');
      if (b) { var a = b.dataset.act; if (a === 'signin') window.requestCommunityAuth && window.requestCommunityAuth('inbox'); else if (a === 'new') newMessageSheet(); else if (a === 'retry-list') loadConversations(); return; }
      var r = e.target.closest('.bm-row[data-peer]'); if (r) openChat(r.dataset.peer);
    });
    R.people.addEventListener('click', function (e) { var r = e.target.closest('.bm-row[data-peer]'); if (r) openChat(r.dataset.peer); });
    // long-press / right click for conversation actions
    var lp = 0, lpRow = null;
    R.rows.addEventListener('pointerdown', function (e) { var r = e.target.closest('.bm-row[data-peer]'); if (!r || e.pointerType === 'mouse') return; lpRow = r; clearTimeout(lp); lp = setTimeout(function () { S.suppress = true; haptic('tap'); rowMenu(r.dataset.peer); }, 480); });
    ['pointerup', 'pointercancel', 'pointermove'].forEach(function (t) { R.rows.addEventListener(t, function () { clearTimeout(lp); }); });
    R.rows.addEventListener('contextmenu', function (e) { var r = e.target.closest('.bm-row[data-peer]'); if (!r) return; e.preventDefault(); rowMenu(r.dataset.peer); });
    R.msgs.addEventListener('click', function (e) {
      var a = e.target.closest('[data-act]');
      if (a) { if (a.dataset.act === 'older') loadOlder(); else if (a.dataset.act === 'retry-thread') openChat(S.peer); return; }
      var ib = e.target.closest('.bm-imgbtn'); if (ib) { var img = $('img', ib); if (img && img.src) lightbox(img.src); return; }
      var sh = e.target.closest('[data-share]'); if (sh) { close(true); return; }
      var f = e.target.closest('.bm-msg.failed'); if (f) retry(f.dataset.id);
    });
    R.msgs.addEventListener('keydown', function (e) { if ((e.key === 'Enter' || e.key === ' ') && e.target.classList && e.target.classList.contains('failed')) { e.preventDefault(); retry(e.target.dataset.id); } });
    var ticking = false;
    R.msgs.addEventListener('scroll', function () {
      if (!ticking) { ticking = true; requestAnimationFrame(function () { ticking = false; updateFab(); if (R.msgs.scrollTop < 90 && S.hasMore) loadOlder(); }); }
    }, { passive: true });
    R.fab.onclick = function () { S.newBelow = 0; R.msgs.scrollTo({ top: R.msgs.scrollHeight, behavior: 'smooth' }); };
    R.input.addEventListener('input', function () { autosize(); syncSend(); });
    R.input.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && window.matchMedia && matchMedia('(pointer:fine)').matches) { e.preventDefault(); submit(); } });
    R.input.addEventListener('focus', function () { setTimeout(function () { R.msgs.scrollTop = R.msgs.scrollHeight; }, 320); });
    R.form.onsubmit = function (e) { e.preventDefault(); submit(); };
    R.quick.addEventListener('click', function (e) { var b = e.target.closest('[data-q]'); if (!b || !S.peer || !meId()) return; queue(b.dataset.q); });
    $('#bmAttach', root).onclick = function () { R.file.click(); };
    R.file.onchange = function () { var f = R.file.files && R.file.files[0]; R.file.value = ''; sendImage(f); };
    R.wpFile.onchange = onWallFile;
    keyboard();
  }
  function lightbox(url) {
    var d = D.createElement('div'); d.className = 'bm-lightbox'; d.setAttribute('role', 'dialog'); d.setAttribute('aria-label', 'Photo');
    d.innerHTML = '<img alt="Photo"><button type="button" aria-label="Close photo">✕</button>'; d.querySelector('img').src = url;
    d.onclick = function () { d.remove(); }; R.root.appendChild(d); d.querySelector('button').focus();
  }

  /* ---------- open / close (public) ---------- */
  function currentView() { var v = (D.getElementById('lgttStage') || {}).dataset; v = v && v.view || 'feed'; return v === 'discover' || v === 'profile' ? v : 'feed'; }
  function open(keepChat) {
    build();
    var stage = D.getElementById('lgttStage');
    if (stage && R.root.parentNode !== stage) stage.appendChild(R.root);
    R.root.classList.add('open'); S.open = true;
    if (stage) stage.classList.add('bmn-inbox-open');
    D.body.classList.add('bmn-real-inbox-open');
    try { window.LGTT && window.LGTT.resume && window.LGTT.resume(); } catch (_) {}
    if (!keepChat) { S.peer = null; R.root.dataset.view = 'list'; R.chat.setAttribute('aria-hidden', 'true'); if (stage) stage.classList.remove('bmn-chat-open'); R.search.value = ''; S.query = ''; R.people.innerHTML = ''; closeSheet(); }
    renderList(); loadConversations(); setupRT();
  }
  function close(quiet) {
    var q = quiet === true;
    if (!R.root) return;
    R.root.classList.remove('open'); S.open = false; S.peer = null; S.rows = [];
    var stage = D.getElementById('lgttStage');
    if (stage) { stage.classList.remove('bmn-inbox-open'); stage.classList.remove('bmn-chat-open'); }
    D.body.classList.remove('bmn-real-inbox-open');
    R.root.dataset.view = 'list'; R.chat.setAttribute('aria-hidden', 'true'); closeSheet();
    try { window.LGTT && window.LGTT.resume && window.LGTT.resume(); } catch (_) {}
    if (!q) { try { window.bmnSetDock && window.bmnSetDock(currentView()); } catch (_) {} }
  }

  /* Escape: the page has a capture-phase Escape handler on document that would close the whole Community overlay.
     A capture listener on window runs first, so Escape steps back one level inside Messages (sheet, photo, chat, list). */
  window.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' || !S.open || !R.root) return;
    if (D.querySelector('#bmnSheetHost[data-open="1"]')) return;
    e.stopPropagation(); e.preventDefault();
    if (!R.sheet.hidden) { closeSheet(); return; }
    var lb = $('.bm-lightbox', R.root); if (lb) { lb.remove(); return; }
    if (S.peer) backToList(); else close();
  }, true);

  /* start: background unread tracking runs as soon as a member is signed in */
  setInterval(poll, POLL_MS);
  D.addEventListener('visibilitychange', function () { if (D.visibilityState === 'visible') { S.tick = 0; poll(); if (S.open && S.peer) scheduleMarkRead(S.peer); } });
  window.addEventListener('online', function () { poll(); if (S.open && S.peer) refreshThread(); });
  setTimeout(poll, 1500);

  window.BMNMessaging = {
    open: open, close: close, openChat: openChat, refresh: function () { return loadConversations(); }, unread: function () { return S.unreadTotal; },
    _state: S
  };
  window.BMNRealInbox = { open: function () { open(); }, close: close, openChat: openChat, refresh: function () { return loadConversations(); } };
})();
