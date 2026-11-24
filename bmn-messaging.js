/* BMN Messaging: one module for the Community Inbox, one-to-one chats and group chats.
 *
 * Public API is unchanged (window.BMNMessaging / window.BMNRealInbox: open, close, openChat, refresh), so every
 * existing entry point keeps working (dock Inbox button, profile Message button, LGTT.openInbox, openSelfChat, notifications).
 *
 * Data: Supabase tables `messages` (1:1) and, when the Batch 3 migrations are applied, `group_messages` and friends.
 * No demo data. Every feature that needs the new database objects is detected at run time (capability probes) and is
 * hidden or falls back when the objects are missing, so this file is safe to deploy BEFORE the SQL is applied.
 *
 *  - read receipts: existing SECURITY DEFINER function bmn_mark_messages_read (a direct UPDATE is blocked by RLS)
 *  - history is loaded newest-first and paged
 *  - realtime when the project publishes the tables; polling fallback otherwise
 *  - themes: dark / light / system + accent, saved per user (server when available, this device always)
 *  - Liquid Glass only on small floating surfaces; the conversation list and thread backgrounds stay solid
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
  var IMGP = 'bmn-img:', UNSENT = 'bmn-unsent:', SYSP = 'bmn-sys:';
  var PAGE = 60, MAX_LEN = 5000, POLL_MS = 5000;
  var COLS = 'id,sender_id,recipient_id,content,created_at,read_at,deleted_by_sender,deleted_by_recipient';
  var COLS_X = COLS + ',reply_to_id,forwarded_from_user_id,forwarded_from_name,edited_at,unsent_at,expires_at';
  var GCOLS = 'id,group_id,sender_id,content,kind,created_at,reply_to_id,forwarded_from_user_id,forwarded_from_name,edited_at,unsent_at,expires_at';
  var REASONS = [['harassment', 'Harassment or bullying'], ['spam', 'Spam'], ['scam', 'Scam or fraud'], ['hate', 'Hate speech'], ['violence', 'Violence or threats'], ['sexual_content', 'Sexual content'], ['nudity', 'Nudity'], ['copyright', 'Copyright'], ['other', 'Something else']];
  var EMOJIS = ['\u{1F44D}', '❤️', '\u{1F602}', '\u{1F62E}', '\u{1F622}', '\u{1F64F}'];
  var ZERO = '00000000-0000-0000-0000-000000000000';

  var S = {
    built: false, open: false, peer: null, gid: null, rows: [], hasMore: false, loadingMore: false, loadingThread: false,
    convs: new Map(), groups: new Map(), unreadTotal: 0, unreadFrom: null, newBelow: 0, tmp: 0, rpcInbox: null,
    ch: null, chUser: null, tick: 0, lastRT: 0, imgUrls: new Map(), query: '', lastList: 0, pollBusy: false, markTimer: 0,
    cap: { actions: null, groups: null, privacy: null, probed: 0 },
    set: null, cs: new Map(), pres: new Map(), react: new Map(), pins: [], reqs: new Set(), members: new Map(),
    reply: null, edit: null, sel: null, filter: 'all', arch: false, typingUntil: 0, typingSent: 0, typeCh: null, jump: null, blocked: new Set()
  };
  var R = {}; // dom refs

  /* ---------- small helpers ---------- */
  function haptic(k) { try { window.LGTT && window.LGTT.haptic && window.LGTT.haptic(k); } catch (_) {} }
  function prof(id) { return (window.bmnProfiles && window.bmnProfiles[id]) || {}; }
  function nameOf(id) { var p = prof(id); return p.display_name || p.full_name || p.username || 'BMN member'; }
  function handleOf(id) { var p = prof(id); return p.username ? '@' + p.username : ''; }
  function avatarUrl(id) { var p = prof(id); return p.avatar_display_url || p.avatar_url || p.avatar || ''; }
  function hue(id) { var h = 0, s = String(id || ''); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360; return h; }
  function avatarHTML(id, cls, dot) {
    var u = avatarUrl(id), ini = esc((nameOf(id).trim()[0] || 'B').toUpperCase());
    return '<span class="bm-av ' + (cls || '') + '" style="--h:' + hue(id) + '">' + (u ? '<img src="' + esc(u) + '" alt="" loading="lazy" decoding="async">' : ini) + (dot ? '<i class="bm-dot" aria-hidden="true"></i>' : '') + '</span>';
  }
  function groupAvatarHTML(g, cls) {
    var u = g && g.avatar_url ? String(g.avatar_url) : '', ini = esc((String(g && g.name || 'G').trim()[0] || 'G').toUpperCase()), inner = ini;
    if (u.indexOf(IMGP) === 0) { var p = u.slice(IMGP.length), c = S.imgUrls.get(p); inner = '<img data-gp="' + esc(p) + '" alt=""' + (c ? ' src="' + esc(c) + '"' : '') + ' loading="lazy" decoding="async">'; }
    else if (/^https:/i.test(u)) inner = '<img src="' + esc(u) + '" alt="" loading="lazy" decoding="async">';
    return '<span class="bm-av bm-gav ' + (cls || '') + '" style="--h:' + hue(g && g.group_id) + '">' + inner + '</span>';
  }
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
  function seenLabel(ts) {
    var d = new Date(ts); if (isNaN(d.getTime())) return '';
    var n = dayDiff(ts);
    return 'last seen ' + (n === 0 ? 'at ' + fmtTime(ts) : n === 1 ? 'yesterday at ' + fmtTime(ts) : 'on ' + d.toLocaleDateString([], { month: 'short', day: 'numeric' }));
  }
  function plural(n, w) { return n + ' ' + w + (n === 1 ? '' : 's'); }
  function lsGet(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
  function lsSet(k, v) { try { if (v == null || v === '') localStorage.removeItem(k); else localStorage.setItem(k, v); return true; } catch (_) { return false; } }
  function isRpcMissing(e) { var m = String(e && (e.message || e.details || '') || ''), c = e && e.code; return c === 'PGRST202' || c === '42883' || c === '404' || /could not find the function|does not exist|not found/i.test(m) && !/Message not found/i.test(m); }
  function isTableMissing(e) { var m = String(e && e.message || ''), c = e && e.code; return c === '42P01' || c === 'PGRST205' || /relation .* does not exist|could not find the table|schema cache/i.test(m); }

  var IC = {
    back: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 18-6-6 6-6"/></svg>',
    compose: '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
    self: '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
    gear: '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z"/></svg>',
    search: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>',
    photo: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>',
    send: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5"/><path d="m5 12 7-7 7 7"/></svg>',
    down: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>',
    check: '<svg viewBox="0 0 16 11" width="15" height="10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m1 5.5 3.2 3.2L10 1.5"/></svg>',
    check2: '<svg viewBox="0 0 20 11" width="19" height="10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m1 5.5 3.2 3.2L10 1.5"/><path d="m8 7.5.7.7L14.5 1.5"/></svg>',
    clock: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.3 1.4"/></svg>',
    warn: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13Zm-.8 3.2h1.6v4.3H7.2Zm.8 6.9a.95.95 0 1 1 0-1.9.95.95 0 0 1 0 1.9Z"/></svg>',
    pin: '<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="M16 3a1 1 0 0 1 .7 1.7L15 6.4l.6 5 2.4 2.4a1 1 0 0 1-.7 1.7H13v5l-1 1-1-1v-5H6.7A1 1 0 0 1 6 13.8l2.4-2.4.6-5L7.3 4.7A1 1 0 0 1 8 3Z"/></svg>',
    mute: '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-9.3-5M6.3 6.3A6 6 0 0 0 6 8c0 7-3 9-3 9h14M9.7 21a2 2 0 0 0 3.4 0M2 2l20 20"/></svg>',
    bell: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0"/></svg>',
    archive: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8M10 12h4"/></svg>',
    trash: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/></svg>',
    reply: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 6 6v3"/></svg>',
    copy: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h8"/></svg>',
    fwd: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 14 5-5-5-5"/><path d="M20 9H10a6 6 0 0 0-6 6v3"/></svg>',
    edit: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
    save: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2Z"/></svg>',
    select: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/></svg>',
    flag: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 22V4M4 4h13l-2 4 2 4H4"/></svg>',
    users: '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8"/></svg>',
    block: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/></svg>',
    user: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>',
    wall: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="4"/><path d="M3 15l5-5 4 4 3-3 6 6"/></svg>',
    close: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>',
    plus: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>',
    unread: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z"/><path d="m22 7-10 6L2 7"/></svg>',
    leave: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>'
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
  function isUnsent(m) { return !!(m && (m.unsent_at || m.content === UNSENT)); }
  function isSys(m) { return !!(m && m.kind === 'system'); }
  function isEmojiOnly(c) { return c.indexOf(IMGP) !== 0 && c.indexOf(UNSENT) !== 0 && EMO.test(c) && (c.match(/\p{Extended_Pictographic}/gu) || []).length <= 3; }
  function isTextMsg(m) { var c = String(m.content || ''); return !isUnsent(m) && !isSys(m) && c.indexOf(IMGP) !== 0 && !/^bmn-[a-z]+:/.test(c) && !parseShare(c); }
  function sysText(m) {
    var c = String(m.content || '').slice(SYSP.length), who = m.sender_id === meId() ? 'You' : nameOf(m.sender_id), p = c.split(':');
    var nm = function (id) { return id === meId() ? 'you' : nameOf(id); };
    if (p[0] === 'created') return who + ' created the group';
    if (p[0] === 'added') return who + ' added ' + (p[1] || '').split(',').filter(Boolean).map(nm).join(', ');
    if (p[0] === 'removed') return who + ' removed ' + nm(p[1]);
    if (p[0] === 'left') return who + ' left the group';
    if (p[0] === 'renamed') return who + ' renamed the group to “' + c.slice(8) + '”';
    if (p[0] === 'role') return who + (p[2] === 'owner' ? ' made ' + nm(p[1]) + ' the group owner' : p[2] === 'admin' ? ' made ' + nm(p[1]) + ' an admin' : ' removed ' + nm(p[1]) + ' as admin');
    return 'Group updated';
  }
  function previewOf(c, mine, m) {
    var t = String(c || ''); var p;
    if (m && isUnsent(m)) return mine ? 'You unsent a message' : 'This message was unsent';
    if (m && isSys(m)) return sysText(m);
    if (t.indexOf(IMGP) === 0) p = '\u{1F4F7} Photo';
    else if (t.indexOf('bmn-voice:') === 0) p = '\u{1F3A4} Voice message';
    else if (parseShare(t)) p = '\u{1F3AC} Shared a post';
    else p = t.replace(/\s+/g, ' ');
    return (mine ? 'You: ' : '') + p;
  }
  function snippet(m) {
    if (!m) return '';
    var c = String(m.content || '');
    if (isUnsent(m)) return 'Unsent message';
    if (c.indexOf(IMGP) === 0) return '\u{1F4F7} Photo';
    if (c.indexOf('bmn-voice:') === 0) return '\u{1F3A4} Voice message';
    if (parseShare(c)) return '\u{1F3AC} Shared a post';
    return c.replace(/\s+/g, ' ').slice(0, 140);
  }
  function bodyHTML(m) {
    var c = String(m.content || '');
    if (isUnsent(m)) return '<span class="bm-unsent">' + (m.sender_id === meId() ? 'You unsent this message' : 'This message was unsent') + '</span>';
    if (c.indexOf(IMGP) === 0) {
      var p = c.slice(IMGP.length), cached = S.imgUrls.get(p);
      return '<button type="button" class="bm-imgbtn" data-p="' + esc(p) + '" aria-label="Open photo"><img class="bm-img" data-p="' + esc(p) + '" alt="Photo"' + (cached ? ' src="' + esc(cached) + '"' : '') + '></button>';
    }
    var sh = parseShare(c);
    if (sh) return '<a class="bm-share" href="' + esc(sh.url) + '" data-share="1"><span class="bm-share-ic" aria-hidden="true">\u{1F3AC}</span><span><strong>Shared a BMN post</strong>' + (sh.caption ? '<small>' + esc(sh.caption) + '</small>' : '<small>Tap to open</small>') + '</span></a>';
    return linkify(esc(c));
  }

  /* ======================================================================
   * Theme + settings
   *   theme: system | dark | light        accent: bmn | ocean | forest | sunset | rose
   *   Saved on this device always, and in bmn_messaging_settings when that table exists.
   *   "system" follows the device (prefers-color-scheme); when the BMN app itself has an explicit light/dark
   *   theme (html[data-bmn-theme]) that wins, so Messages never disagrees with the rest of the app.
   * ====================================================================== */
  var THEMES = ['system', 'dark', 'light'], ACCENTS = ['bmn', 'ocean', 'forest', 'sunset', 'rose'];
  var DEFAULTS = { theme: 'system', accent: 'bmn', read_receipts: true, show_activity_status: true, who_can_message: 'everyone',
    typing_indicator: true, last_seen: 'everyone', group_invites: 'everyone', auto_download: { photos: 'wifi', video: 'wifi', voice: 'always' } };
  function loadLocalSettings() {
    var s = JSON.parse(JSON.stringify(DEFAULTS)), t = lsGet('bmn-msg-theme', ''), a = lsGet('bmn-msg-accent', ''), ad = lsGet('bmn-msg-autodl', '');
    if (THEMES.indexOf(t) >= 0) s.theme = t;
    if (ACCENTS.indexOf(a) >= 0) s.accent = a;
    try { if (ad) s.auto_download = Object.assign(s.auto_download, JSON.parse(ad)); } catch (_) {}
    return s;
  }
  S.set = loadLocalSettings();
  function resolveTheme() {
    var t = S.set.theme;
    if (t === 'dark' || t === 'light') return t;
    var h = D.documentElement.getAttribute('data-bmn-theme');
    if (h === 'light' || h === 'dark') return h;
    if (D.body && D.body.classList.contains('light')) return 'light';
    try { return window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'; } catch (_) { return 'dark'; }
  }
  function applyTheme() {
    if (!R.root) return;
    R.root.dataset.bmTheme = resolveTheme();
    R.root.dataset.bmAccent = ACCENTS.indexOf(S.set.accent) >= 0 ? S.set.accent : 'bmn';
  }
  try {
    if (window.matchMedia) { var mq = matchMedia('(prefers-color-scheme: light)'); (mq.addEventListener ? mq.addEventListener.bind(mq, 'change') : mq.addListener.bind(mq))(function () { applyTheme(); }); }
    if (window.MutationObserver) {
      var mo = new MutationObserver(function () { applyTheme(); });
      mo.observe(D.documentElement, { attributes: true, attributeFilter: ['data-bmn-theme', 'class'] });
      if (D.body) mo.observe(D.body, { attributes: true, attributeFilter: ['class'] });
    }
  } catch (_) {}

  var SET1 = ['read_receipts', 'show_activity_status', 'who_can_message'];                       // existing public.user_settings
  var SET2 = ['typing_indicator', 'last_seen', 'group_invites', 'theme', 'accent', 'auto_download']; // public.bmn_messaging_settings (M1)
  async function loadSettings() {
    var s = sb(), me = meId(); if (!s || !me) return;
    var jobs = [];
    if (S.cap.set1 !== false) jobs.push(s.from('user_settings').select('read_receipts,show_activity_status,who_can_message').eq('user_id', me).maybeSingle().then(function (r) {
      if (r.error) { if (isTableMissing(r.error) || r.error.code === '42703') S.cap.set1 = false; return; }
      S.cap.set1 = true; if (r.data) SET1.forEach(function (k) { if (r.data[k] != null) S.set[k] = r.data[k]; });
    }, function () {}));
    if (S.cap.set2 !== false) jobs.push(s.from('bmn_messaging_settings').select('typing_indicator,last_seen,group_invites,theme,accent,auto_download').eq('user_id', me).maybeSingle().then(function (r) {
      if (r.error) { if (isTableMissing(r.error) || r.error.code === '42703') S.cap.set2 = false; return; }
      S.cap.set2 = true;
      if (r.data) SET2.forEach(function (k) {
        if (r.data[k] == null) return;
        if (k === 'theme' || k === 'accent') { if (!lsGet('bmn-msg-' + k, '')) S.set[k] = r.data[k]; }   // this device's own choice wins
        else if (k === 'auto_download') S.set[k] = Object.assign({}, S.set[k], r.data[k]);
        else S.set[k] = r.data[k];
      });
    }, function () {}));
    await Promise.all(jobs); applyTheme();
  }
  async function saveSettings(patch) {
    var s = sb(), me = meId(), ok = true;
    Object.keys(patch).forEach(function (k) { S.set[k] = patch[k]; });
    if ('theme' in patch) lsSet('bmn-msg-theme', patch.theme);
    if ('accent' in patch) lsSet('bmn-msg-accent', patch.accent);
    if ('auto_download' in patch) lsSet('bmn-msg-autodl', JSON.stringify(patch.auto_download));
    applyTheme();
    if (!s || !me) return true;
    var p1 = {}, p2 = {};
    Object.keys(patch).forEach(function (k) { if (SET1.indexOf(k) >= 0) p1[k] = patch[k]; else if (SET2.indexOf(k) >= 0) p2[k] = patch[k]; });
    try {
      if (Object.keys(p1).length && S.cap.set1 !== false) { p1.user_id = me; var r1 = await s.from('user_settings').upsert(p1, { onConflict: 'user_id' }); if (r1.error) { ok = false; } }
      if (Object.keys(p2).length && S.cap.set2 !== false) { p2.user_id = me; p2.updated_at = new Date().toISOString(); var r2 = await s.from('bmn_messaging_settings').upsert(p2, { onConflict: 'user_id' }); if (r2.error) ok = false; }
      else if (Object.keys(p2).length && !('theme' in p2 || 'accent' in p2 || 'auto_download' in p2)) ok = false;
    } catch (_) { ok = false; }
    return ok;
  }

  /* ======================================================================
   * Capability probes. Everything new is optional: a feature turns on only when its database object answers.
   * ====================================================================== */
  async function probe(force) {
    var s = sb(), me = meId(); if (!s || !me) return;
    var c = S.cap;
    if (c.probed === me && !force && (Date.now() - (c.at || 0) < 120000 || c.groups === true)) return;
    c.probed = me; c.at = Date.now();
    var chk = function (p, set) { return p.then(function (r) { set(!r.error, r); }, function () {}); };
    await Promise.all([
      chk(s.from('messages').select('reply_to_id').limit(1), function (ok) { c.actions = ok; }),
      chk(s.from('conversation_settings').select('id').limit(1), function (ok) { c.cs = ok; }),
      chk(s.from('user_blocks').select('target_id').eq('kind', 'block').limit(1), function (ok) { c.blocks = ok; }),
      chk(s.from('message_requests').select('requester_id').limit(1), function (ok) { c.req = ok; }),
      chk(s.rpc('bmn_peers_presence', { p_peers: [] }), function (ok) { c.pres = ok; }),
      chk(s.from('bmn_messaging_config').select('key,value'), function (ok, r) { c.cfg = ok; if (ok) { S.cfg = {}; (r.data || []).forEach(function (x) { S.cfg[x.key] = Number(x.value); }); } }),
      loadSettings()
    ]);
  }
  var gcfg = function (k, d) { return S.cfg && S.cfg[k] != null ? S.cfg[k] : d; };
  S.cfg = null;

  /* ======================================================================
   * Data layer
   * ====================================================================== */
  async function msgSelect(build) {
    var s = sb(), tiers = S.cap.actions === false ? [COLS, 'id,sender_id,recipient_id,content,created_at,read_at', 'id,sender_id,recipient_id,content,created_at'] : [COLS_X, COLS, 'id,sender_id,recipient_id,content,created_at,read_at', 'id,sender_id,recipient_id,content,created_at'], r = null;
    for (var i = 0; i < tiers.length; i++) {
      r = await build(s.from('messages').select(tiers[i]));
      if (!r.error) return r;
      if (!/column|schema cache|deleted_by|read_at/i.test(String(r.error.message || ''))) return r;
      if (i === 0 && tiers[0] === COLS_X) S.cap.actions = false;
    }
    return r;
  }
  var visibleToMe = function (m, me) { if (m.expires_at && new Date(m.expires_at) < new Date()) return false; return m.sender_id === me ? !m.deleted_by_sender : !m.deleted_by_recipient; };
  async function ensureProfiles(ids) {
    var s = sb(); if (!s) return;
    if (!window.bmnProfiles) window.bmnProfiles = {};
    var miss = Array.from(new Set(ids.filter(function (id) { return id && UUID.test(String(id)) && !window.bmnProfiles[id]; })));
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
    if (code === '42501' || /row-level security/i.test(msg)) return S.gid ? 'This message could not be sent. You may no longer be able to post in this group.' : 'This message could not be sent. Your account may not be able to message this person right now.';
    if (code === 'P0001' && msg) return msg;
    if (/foreign key|violates/i.test(msg)) return 'This conversation could not be found. Go back and open it again.';
    if (/Failed to fetch|NetworkError|network|timeout/i.test(msg)) return 'No connection. Your message is kept. Tap it to retry.';
    return 'Message not sent' + (msg ? ': ' + msg : '') + '. Tap it to retry.';
  }
  function rpcMsg(e) { var m = String((e && e.message) || ''); return /Failed to fetch|network/i.test(m) ? 'No connection. Try again.' : (m || 'Something went wrong. Try again.'); }

  /* ----- conversation list ----- */
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
  async function fetchGroups() {
    var s = sb(); if (!s || S.cap.groups === false) return null;
    try {
      var r = await s.rpc('bmn_group_inbox');
      if (r.error) { S.cap.groups = false; return null; }
      S.cap.groups = true;
      var out = new Map();
      (r.data || []).forEach(function (x) {
        out.set(x.group_id, { group_id: x.group_id, name: x.name, description: x.description, avatar_url: x.avatar_url, my_role: x.my_role, member_count: Number(x.member_count || 0), unread: Number(x.unread_count || 0),
          only_admins_post: !!x.only_admins_post, members_can_add: !!x.members_can_add, disappearing_seconds: x.disappearing_seconds || 0,
          last: x.last_message_id ? { id: x.last_message_id, content: x.last_message_content, sender_id: x.last_message_sender, kind: x.last_message_kind, unsent_at: x.last_message_unsent ? x.last_message_at : null, created_at: x.last_message_at } : null, created_at: x.last_message_at });
      });
      return out;
    } catch (_) { return null; }
  }
  function csKey(peer, gid) { return gid ? 'g:' + gid : 'p:' + peer; }
  function csLocalGet() { try { return JSON.parse(lsGet('bmn-cs:' + meId(), '{}')) || {}; } catch (_) { return {}; } }
  async function fetchConvSettings() {
    var s = sb(), me = meId(); if (!s || !me) return;
    if (S.cap.cs === false) { var o = csLocalGet(), m = new Map(); Object.keys(o).forEach(function (k) { m.set(k, o[k]); }); S.cs = m; return; }
    try {
      var r = await s.from('conversation_settings').select('id,peer_id,group_id,pinned_at,muted_until,archived_at');
      if (r.error) { if (isTableMissing(r.error)) { S.cap.cs = false; return fetchConvSettings(); } return; }
      var map = new Map(); (r.data || []).forEach(function (x) { map.set(csKey(x.peer_id, x.group_id), x); }); S.cs = map;
    } catch (_) {}
  }
  async function fetchRequests() {
    var s = sb(), me = meId(); if (!s || !me || S.cap.req === false) return;
    try {
      var r = await s.from('message_requests').select('requester_id,status').eq('recipient_id', me).eq('status', 'pending');
      if (!r.error) S.reqs = new Set((r.data || []).map(function (x) { return x.requester_id; }));
    } catch (_) {}
  }
  async function fetchBlocked() {
    var s = sb(), me = meId(); if (!s || !me || S.cap.blocks === false) return;
    try {
      var r = await s.from('user_blocks').select('target_id').eq('user_id', me).eq('kind', 'block');
      if (!r.error) S.blocked = new Set((r.data || []).map(function (x) { return x.target_id; }));
    } catch (_) {}
  }
  async function fetchPresence(ids) {
    var s = sb(); if (!s || S.cap.pres === false || !ids.length) return;
    try {
      var r = await s.rpc('bmn_peers_presence', { p_peers: ids.slice(0, 100) });
      if (r.error) return;
      (r.data || []).forEach(function (x) { S.pres.set(x.peer_id, { online: !!x.online, last_seen_at: x.last_seen_at, blocked: !!x.blocked }); });
    } catch (_) {}
  }
  function isMuted(key) { var c = S.cs.get(key); return !!(c && c.muted_until && new Date(c.muted_until) > new Date()); }
  function recount() {
    var n = 0;
    S.convs.forEach(function (c, id) { if (!isMuted('p:' + id) && !S.reqs.has(id)) n += c.unread || 0; });
    S.groups.forEach(function (g, id) { if (!isMuted('g:' + id)) n += g.unread || 0; });
    S.unreadTotal = n; setBadge(n);
  }
  function setBadge(n) {
    window.__bmnRealUnread = n;
    var b = $('#lgttInboxBadge');
    if (b) { var was = b.hidden; b.hidden = n === 0; if (n) { b.textContent = n > 99 ? '99+' : (n > 9 ? '9+' : String(n)); } if (was && n) { b.style.animation = 'none'; void b.offsetWidth; b.style.animation = ''; } }
    if (R.sub) R.sub.textContent = n ? n + ' unread' : '';
    if (R.backN) {
      var cur = S.gid ? (S.groups.get(S.gid) && S.groups.get(S.gid).unread) : (S.convs.get(S.peer) && S.convs.get(S.peer).unread);
      var other = n - (cur || 0); R.backN.hidden = !((S.peer || S.gid) && other > 0); R.backN.textContent = other > 99 ? '99+' : other;
    }
  }
  async function loadConversations(opts) {
    if (!meId()) { renderList(); return; }
    try {
      await probe();
      var res = await Promise.all([fetchConversations(), fetchGroups(), fetchConvSettings(), fetchRequests(), fetchBlocked()]);
      var map = res[0]; if (!map) return;
      var viewing = S.open && D.visibilityState !== 'hidden';
      if (S.peer && viewing) { var cur = map.get(S.peer); if (cur) cur.unread = 0; }
      if (S.gid && viewing && res[1]) { var cg = res[1].get(S.gid); if (cg) cg.unread = 0; }
      S.convs = map; if (res[1]) S.groups = res[1]; S.lastList = Date.now();
      var ids = Array.from(map.keys());
      S.groups.forEach(function (g) { if (g.last && g.last.sender_id) ids.push(g.last.sender_id); });
      await Promise.all([ensureProfiles(ids), fetchPresence(Array.from(map.keys()))]);
      recount(); if (R.rows) renderList();
    } catch (e) {
      if (R.rows && !(opts && opts.silent)) R.rows.innerHTML = '<div class="bm-empty"><strong>Could not load your messages</strong><p>' + esc(e.message || 'Check your connection and try again.') + '</p><button type="button" class="bm-btn" data-act="retry-list">Try again</button></div>';
    }
  }

  /* ----- conversation settings: pin / mute / archive ----- */
  async function setConv(peer, gid, patch) {
    var s = sb(), me = meId(), key = csKey(peer, gid); if (!s || !me) return false;
    var cur = S.cs.get(key) || {}, next = Object.assign({}, cur, patch);
    S.cs.set(key, next); recount(); renderList();
    if (S.cap.cs === false) {
      var o = csLocalGet(); o[key] = { pinned_at: next.pinned_at || null, muted_until: next.muted_until || null, archived_at: next.archived_at || null }; lsSet('bmn-cs:' + me, JSON.stringify(o)); return true;
    }
    try {
      var r;
      if (cur.id) r = await s.from('conversation_settings').update(Object.assign({ updated_at: new Date().toISOString() }, patch)).eq('id', cur.id);
      else { var row = Object.assign({ user_id: me }, gid ? { group_id: gid } : { peer_id: peer }, patch); r = await s.from('conversation_settings').insert(row).select('id,peer_id,group_id,pinned_at,muted_until,archived_at').single(); if (!r.error && r.data) S.cs.set(key, r.data); }
      if (r.error) throw r.error;
      return true;
    } catch (e) { S.cs.set(key, cur); recount(); renderList(); toast(rpcMsg(e)); return false; }
  }

  /* ----- thread data ----- */
  var isG = function () { return !!S.gid; };
  var scopeOf = function () { return S.gid ? 'group' : 'dm'; };
  var curKey = function () { return S.gid ? 'g:' + S.gid : (S.peer ? 'p:' + S.peer : null); };
  async function fetchThread(before) {
    var s = sb(), me = meId();
    if (S.gid) {
      var gid = S.gid, rg = await s.from('group_messages').select(GCOLS).eq('group_id', gid).order('created_at', { ascending: false }).lt('created_at', before || '9999-12-31T00:00:00Z').limit(PAGE + 1);
      if (rg.error) throw rg.error;
      var gd = (rg.data || []).filter(function (m) { return !(m.expires_at && new Date(m.expires_at) < new Date()); }); var gm = (rg.data || []).length > PAGE; if (gm) gd.pop();
      gd.forEach(function (m) { m._g = true; }); gd.reverse();
      return { rows: gd, more: gm };
    }
    var peer = S.peer;
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
  async function markGroupRead(gid) {
    var s = sb(); if (!s || !gid) return;
    var g = S.groups.get(gid); if (g) { g.unread = 0; recount(); if (R.rows) renderList(); }
    try { await s.rpc('bmn_mark_group_read', { p_group: gid }); } catch (_) {}
  }
  function scheduleMarkRead() {
    clearTimeout(S.markTimer);
    var peer = S.peer, gid = S.gid;
    S.markTimer = setTimeout(function () {
      if (!S.open || D.visibilityState === 'hidden') return;
      if (gid && S.gid === gid) markGroupRead(gid); else if (peer && S.peer === peer) markRead(peer);
    }, 350);
  }

  /* reactions, reply targets, pins, peer flags, members */
  async function fetchReactions(ids) {
    var s = sb(); if (!s || S.cap.actions === false || !ids.length) return;
    var col = S.gid ? 'group_message_id' : 'message_id';
    try {
      for (var i = 0; i < ids.length; i += 100) {
        var r = await s.from('message_reactions').select('message_id,group_message_id,user_id,emoji').in(col, ids.slice(i, i + 100));
        if (r.error) { if (isTableMissing(r.error)) S.cap.actions = false; return; }
        var by = {}; (r.data || []).forEach(function (x) { var k = x.message_id || x.group_message_id; (by[k] = by[k] || []).push({ user_id: x.user_id, emoji: x.emoji }); });
        ids.slice(i, i + 100).forEach(function (id) { if (by[id]) S.react.set(id, by[id]); else S.react.delete(id); });
      }
    } catch (_) {}
  }
  async function fetchRefs(rows) {
    var s = sb(); if (!s || S.cap.actions === false) return;
    var have = new Set(S.rows.map(function (m) { return m.id; }));
    var need = Array.from(new Set(rows.map(function (m) { return m.reply_to_id; }).filter(function (id) { return id && !have.has(id) && !S.refs.has(id); })));
    if (!need.length) return;
    try {
      var r = await s.from(S.gid ? 'group_messages' : 'messages').select('id,sender_id,content,unsent_at').in('id', need.slice(0, 100));
      if (!r.error) { (r.data || []).forEach(function (x) { S.refs.set(x.id, x); }); need.forEach(function (id) { if (!S.refs.has(id)) S.refs.set(id, null); }); }
    } catch (_) {}
  }
  async function fetchPins() {
    var s = sb(); if (!s || S.cap.actions === false) { S.pins = []; return; }
    try {
      var r = await s.rpc('bmn_conversation_pins', S.gid ? { p_group: S.gid } : { p_peer: S.peer });
      S.pins = r.error ? [] : (r.data || []).slice().sort(function (a, b) { return new Date(b.pinned_at) - new Date(a.pinned_at); });
    } catch (_) { S.pins = []; }
  }
  async function fetchFlags() {
    var s = sb(), peer = S.peer; S.flags = null;
    if (!s || !peer || peer === meId() || S.cap.pres === false) return;
    try { var r = await s.rpc('bmn_peer_flags', { p_peer: peer }); if (!r.error) { var d = Array.isArray(r.data) ? r.data[0] : r.data; if (S.peer === peer) S.flags = d || null; } } catch (_) {}
  }
  async function fetchMembers(gid) {
    var s = sb(); if (!s || !gid) return [];
    try {
      var r = await s.from('group_members').select('user_id,role,joined_at').eq('group_id', gid).order('joined_at', { ascending: true });
      if (r.error) return S.members.get(gid) || [];
      S.members.set(gid, r.data || []);
      await ensureProfiles((r.data || []).map(function (m) { return m.user_id; }));
      return r.data || [];
    } catch (_) { return S.members.get(gid) || []; }
  }
  async function loadExtras() {
    var tag = curKey(), ids = S.rows.filter(function (m) { return !m._pending && !m._failed && String(m.id).indexOf('tmp-') !== 0; }).map(function (m) { return m.id; });
    var jobs = [fetchReactions(ids), fetchRefs(S.rows), fetchPins()];
    if (S.gid) jobs.push(fetchMembers(S.gid)); else jobs.push(fetchFlags());
    await Promise.all(jobs);
    if (curKey() !== tag) return;
    await ensureProfiles(S.rows.map(function (m) { return m.sender_id; }));
    paintHeader(); renderPinned(); renderThread();
  }
  var myRole = function () { return S.gid && S.groups.get(S.gid) ? S.groups.get(S.gid).my_role : null; };
  var isAdmin = function () { var r = myRole(); return r === 'owner' || r === 'admin'; };

  /* ---------- merge / thread state ---------- */
  function sortRows() { S.rows.sort(function (a, b) { var d = new Date(a.created_at) - new Date(b.created_at); return d || String(a.id).localeCompare(String(b.id)); }); }
  function mergeRow(row) {
    var me = meId(), i = S.rows.findIndex(function (m) { return m.id === row.id; });
    if (S.gid) row._g = true;
    if (i >= 0) { S.rows[i] = Object.assign({}, S.rows[i], row, { _pending: false, _failed: false }); return { isNew: false, changed: true }; }
    if (row.sender_id === me) {
      var j = S.rows.findIndex(function (m) { return m._pending && m.content === row.content && (S.gid ? true : m.recipient_id === row.recipient_id); });
      if (j >= 0) { S.rows[j] = Object.assign({}, row); sortRows(); return { isNew: false, changed: true }; }
    }
    S.rows.push(row); sortRows(); return { isNew: true, changed: true };
  }
  function nearBottom() { return !R.msgs || R.msgs.scrollHeight - R.msgs.scrollTop - R.msgs.clientHeight < 160; }

  /* ======================================================================
   * Rendering: conversation list
   * ====================================================================== */
  function draftKey(kind, id) { return 'bmn-draft:' + meId() + ':' + kind + ':' + id; }
  function getDraft(kind, id) { return lsGet(draftKey(kind, id), ''); }
  function setDraft(kind, id, v) { lsSet(draftKey(kind, id), v && v.trim() ? v.slice(0, 4000) : ''); }
  function isArchived(it) {
    var c = S.cs.get(it.key); if (!c || !c.archived_at) return false;
    var lt = it.last && it.last.created_at ? new Date(it.last.created_at) : 0;
    return !(lt && lt > new Date(c.archived_at) && !isMuted(it.key) && it.unread > 0);
  }
  function listItems() {
    var items = [];
    S.convs.forEach(function (c, id) { items.push({ kind: 'dm', key: 'p:' + id, id: id, last: c.last, unread: c.unread || 0, t: new Date(c.last.created_at).getTime() || 0 }); });
    S.groups.forEach(function (g, id) { items.push({ kind: 'group', key: 'g:' + id, id: id, g: g, last: g.last, unread: g.unread || 0, t: new Date((g.last && g.last.created_at) || g.created_at || 0).getTime() || 0 }); });
    return items;
  }
  function itemName(it) { return it.kind === 'group' ? it.g.name : (it.id === meId() ? 'You (saved messages)' : nameOf(it.id)); }
  function visibleItems() {
    var q = S.query.trim().toLowerCase(), all = listItems();
    var arch = all.filter(isArchived).length;
    var reqCount = all.filter(function (it) { return it.kind === 'dm' && S.reqs.has(it.id); }).length;
    var items = all.filter(function (it) {
      var isReq = it.kind === 'dm' && S.reqs.has(it.id);
      if (S.filter === 'requests') { if (!isReq) return false; }
      else if (isReq) return false;
      if (S.arch ? !isArchived(it) : isArchived(it)) return false;
      if (S.filter === 'unread' && !it.unread) return false;
      if (S.filter === 'groups' && it.kind !== 'group') return false;
      if (q) { var hay = (itemName(it) + ' ' + (it.kind === 'dm' ? handleOf(it.id) : '') + ' ' + String(it.last && it.last.content || '')).toLowerCase(); if (hay.indexOf(q) < 0) return false; }
      return true;
    });
    items.sort(function (a, b) {
      var pa = (S.cs.get(a.key) || {}).pinned_at, pb = (S.cs.get(b.key) || {}).pinned_at;
      if (!!pa !== !!pb) return pa ? -1 : 1;
      if (pa && pb) return new Date(pb) - new Date(pa);
      return b.t - a.t;
    });
    return { items: items, arch: arch, reqCount: reqCount };
  }
  function previewHTML(it) {
    var me = meId(), cur = (it.kind === 'group' ? S.gid === it.id : S.peer === it.id) && S.open;
    var d = cur ? '' : getDraft(it.kind === 'group' ? 'grp' : 'dm', it.id);
    if (d) return '<small class="draft"><em>Draft:</em> ' + esc(d.replace(/\s+/g, ' ').slice(0, 120)) + '</small>';
    if (!it.last) return '<small>' + (it.kind === 'group' ? plural(it.g.member_count, 'member') : '') + '</small>';
    var mine = it.last.sender_id === me, m = it.kind === 'group' ? it.last : null, txt;
    if (it.kind === 'group') {
      if (it.last.kind === 'system') txt = sysText(it.last);
      else txt = (mine ? 'You: ' : nameOf(it.last.sender_id).split(' ')[0] + ': ') + previewOf(it.last.content, false, isUnsent(it.last) ? it.last : null).replace(/^You: /, '');
    } else txt = previewOf(it.last.content, mine, isUnsent(it.last) ? it.last : null);
    return '<small>' + esc(txt) + '</small>';
  }
  function rowHTML(it) {
    var me = meId(), un = it.unread || 0, c = S.cs.get(it.key) || {}, muted = isMuted(it.key), pinned = !!c.pinned_at;
    var name = itemName(it), p = it.kind === 'dm' ? S.pres.get(it.id) : null, online = !!(p && p.online && !p.blocked);
    var attr = it.kind === 'group' ? 'data-gid="' + esc(it.id) + '"' : 'data-peer="' + esc(it.id) + '"';
    var av = it.kind === 'group' ? groupAvatarHTML(it.g) : avatarHTML(it.id, '', online);
    var when = it.last && it.last.created_at ? listTime(it.last.created_at) : '';
    var arch = isArchived(it);
    return '<div class="bm-sw" data-key="' + esc(it.key) + '" role="presentation">'
      + '<div class="bm-sw-l"><button type="button" class="bm-swb pin" data-sw="pin" aria-label="' + (pinned ? 'Unpin' : 'Pin') + '">' + IC.pin + '<span>' + (pinned ? 'Unpin' : 'Pin') + '</span></button></div>'
      + '<div class="bm-sw-r"><button type="button" class="bm-swb mute" data-sw="mute" aria-label="' + (muted ? 'Unmute' : 'Mute') + '">' + (muted ? IC.bell : IC.mute) + '<span>' + (muted ? 'Unmute' : 'Mute') + '</span></button>'
      + '<button type="button" class="bm-swb arch" data-sw="arch" aria-label="' + (arch ? 'Unarchive' : 'Archive') + '">' + IC.archive + '<span>' + (arch ? 'Unarchive' : 'Archive') + '</span></button>'
      + '<button type="button" class="bm-swb del" data-sw="del" aria-label="' + (it.kind === 'group' ? 'Leave group' : 'Delete') + '">' + (it.kind === 'group' ? IC.leave : IC.trash) + '<span>' + (it.kind === 'group' ? 'Leave' : 'Delete') + '</span></button></div>'
      + '<button type="button" class="bm-row' + (un ? ' unread' : '') + (muted ? ' muted' : '') + (pinned ? ' pinned' : '') + (it.kind === 'dm' && isFounder(it.id) ? ' founder' : '') + '" ' + attr + ' role="listitem" aria-label="' + esc(name + (un ? ', ' + un + ' unread' : '') + (muted ? ', muted' : '') + (pinned ? ', pinned' : '')) + '">'
      + av
      + '<span class="bm-meta"><span class="bm-top"><strong>' + esc(name) + '</strong>' + (muted ? '<i class="bm-ind" title="Muted">' + IC.mute + '</i>' : '') + (pinned ? '<i class="bm-ind" title="Pinned">' + IC.pin + '</i>' : '') + '<time>' + esc(when) + '</time></span>'
      + '<span class="bm-bot">' + previewHTML(it) + (un ? '<b class="bm-badge' + (muted ? ' muted' : '') + '">' + (un > 99 ? '99+' : un) + '</b>' : '') + '</span></span></button></div>';
  }
  function renderChips(v) {
    if (!R.chips) return;
    var chips = [['all', 'All'], ['unread', 'Unread']]; if (S.cap.groups !== false) chips.push(['groups', 'Groups']);
    R.chips.innerHTML = chips.map(function (c) { return '<button type="button" class="bm-chip' + (S.filter === c[0] && !S.arch ? ' on' : '') + '" data-chip="' + c[0] + '" aria-pressed="' + String(S.filter === c[0] && !S.arch) + '">' + c[1] + '</button>'; }).join('');
  }
  function renderList() {
    if (!R.rows) return;
    var me = meId();
    if (!me) { R.rows.innerHTML = '<div class="bm-empty"><strong>Sign in to use Messages</strong><p>Your messages stay connected to your BMN account.</p><button type="button" class="bm-btn" data-act="signin">Sign in</button></div>'; if (R.chips) R.chips.innerHTML = ''; return; }
    renderChips();
    var v = visibleItems(), q = S.query.trim();
    var head = '';
    if (S.filter === 'requests') head += '<button type="button" class="bm-banner" data-act="req-back">' + IC.back + '<span>Message requests</span></button><p class="bm-hint">People you don’t follow can ask to message you. Nothing is shared with them until you accept.</p>';
    else if (S.arch) head += '<button type="button" class="bm-banner" data-act="arch-back">' + IC.back + '<span>Archived chats</span></button>';
    else {
      if (v.reqCount) head += '<button type="button" class="bm-banner req" data-act="req">' + IC.unread + '<span>Message requests</span><b class="bm-badge">' + v.reqCount + '</b></button>';
      if (v.arch && !q) head += '<button type="button" class="bm-banner" data-act="arch">' + IC.archive + '<span>Archived</span><em>' + v.arch + '</em></button>';
    }
    if (!v.items.length) {
      R.rows.innerHTML = head + (q
        ? '<div class="bm-empty"><strong>No conversations match</strong><p>Try a different name, or find the person below.</p></div>'
        : S.filter === 'unread' ? '<div class="bm-empty"><strong>You’re all caught up</strong><p>No unread conversations.</p></div>'
        : S.filter === 'groups' ? '<div class="bm-empty"><div class="bm-empty-ic" aria-hidden="true">\u{1F465}</div><strong>No groups yet</strong><p>Create a group to chat with several people at once.</p><button type="button" class="bm-btn bm-primary" data-act="new-group">New group</button></div>'
        : S.filter === 'requests' || S.arch ? '<div class="bm-empty small"><p>Nothing here.</p></div>'
        : (S.lastList ? '<div class="bm-empty"><div class="bm-empty-ic" aria-hidden="true">\u{1F4AC}</div><strong>No messages yet</strong><p>Start a conversation with someone from the community.</p><button type="button" class="bm-btn bm-primary" data-act="new">New message</button></div>'
                      : '<div class="bm-empty"><p>Loading your messages…</p></div>'));
      return;
    }
    var pinned = v.items.filter(function (it) { return (S.cs.get(it.key) || {}).pinned_at; }).length, out = head;
    v.items.forEach(function (it, i) {
      if (pinned && i === 0 && !q) out += '<div class="bm-sec">Pinned</div>';
      if (pinned && i === pinned && !q) out += '<div class="bm-sec">All messages</div>';
      out += rowHTML(it);
    });
    R.rows.innerHTML = out;
    hydrateAvatars(R.rows);
  }
  var peopleTimer = 0, peopleSeq = 0;
  function sanitizeQ(q) { return String(q || '').replace(/[^\p{L}\p{N}_ ]/gu, '').trim().slice(0, 40); }
  async function searchPeople(q) {
    var s = sb(), me = meId(); if (!s || !me) return [];
    q = sanitizeQ(q); if (q.length < 2) return [];
    var r = await s.from('profiles').select('*').or('username.ilike.%' + q + '%,display_name.ilike.%' + q + '%').neq('id', me).limit(15);
    if (r.error) throw r.error;
    (r.data || []).forEach(function (p) { if (!window.bmnProfiles) window.bmnProfiles = {}; window.bmnProfiles[p.id] = Object.assign({}, window.bmnProfiles[p.id] || {}, p); });
    return r.data || [];
  }
  function peopleHTML(list, sel) {
    return list.map(function (p) {
      var on = sel && sel.has(p.id);
      return '<button type="button" class="bm-row bm-person' + (on ? ' sel' : '') + '" data-peer="' + esc(p.id) + '"' + (sel ? ' role="checkbox" aria-checked="' + String(!!on) + '"' : '') + '>' + avatarHTML(p.id) + '<span class="bm-meta"><span class="bm-top"><strong>' + esc(nameOf(p.id)) + '</strong></span><span class="bm-bot"><small>' + esc(handleOf(p.id) || 'BMN member') + '</small></span></span>' + (sel ? '<i class="bm-tick' + (on ? ' on' : '') + '" aria-hidden="true">' + IC.check + '</i>' : '') + '</button>';
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
  /* group photos are stored as bmn-img:<path> in the private bucket and shown through signed URLs */
  async function hydrateAvatars(root) {
    var s = sb(); if (!s) return;
    var imgs = $$('img[data-gp]:not([src])', root); if (!imgs.length) return;
    var need = Array.from(new Set(imgs.map(function (i) { return i.dataset.gp; }).filter(function (p) { return !S.imgUrls.has(p); })));
    if (need.length) { try { var r = await s.storage.from('community-media').createSignedUrls(need, 3600); (r.data || []).forEach(function (x) { if (x.signedUrl) S.imgUrls.set(x.path, x.signedUrl); }); } catch (_) {} }
    imgs.forEach(function (i) { var u = S.imgUrls.get(i.dataset.gp); if (u) i.src = u; });
  }

  /* ======================================================================
   * Rendering: conversation
   * ====================================================================== */
  function readOK() { return S.set.read_receipts !== false && !(S.flags && S.flags.read_receipts === false); }
  function statusHTML(m) {
    if (m.sender_id !== meId() || (!S.gid && m.sender_id === m.recipient_id) || isUnsent(m)) return '';
    if (m._failed) return '<span class="bm-st fail">' + IC.warn + '</span>';
    if (m._pending) return '<span class="bm-st wait">' + IC.clock + '</span>';
    var rd = !S.gid && m.read_at && readOK();
    return '<span class="bm-st ' + (rd ? 'read' : 'sent') + '" title="' + (rd ? 'Read' : 'Sent') + '">' + (rd ? IC.check2 : IC.check) + '</span>';
  }
  function rowById(id) { return S.rows.find(function (m) { return m.id === id; }) || null; }
  function replyHTML(m) {
    if (!m.reply_to_id) return '';
    var t = rowById(m.reply_to_id) || S.refs.get(m.reply_to_id);
    if (!t) return '<div class="bm-quote gone"><span>Original message unavailable</span></div>';
    return '<button type="button" class="bm-quote" data-jump="' + esc(m.reply_to_id) + '" aria-label="Go to the original message"><b>' + esc(t.sender_id === meId() ? 'You' : nameOf(t.sender_id)) + '</b><span>' + esc(snippet(t)) + '</span></button>';
  }
  function reactionsHTML(m) {
    var list = S.react.get(m.id); if (!list || !list.length || isUnsent(m)) return '';
    var by = {}, me = meId();
    list.forEach(function (x) { var e = by[x.emoji] || (by[x.emoji] = { n: 0, mine: false }); e.n++; if (x.user_id === me) e.mine = true; });
    return '<div class="bm-rxs">' + Object.keys(by).map(function (e) { return '<button type="button" class="bm-rx' + (by[e].mine ? ' mine' : '') + '" data-rx="' + esc(e) + '" data-id="' + esc(m.id) + '" aria-label="' + esc(e + ' ' + by[e].n + (by[e].mine ? ', you reacted' : '')) + '">' + esc(e) + (by[e].n > 1 ? '<i>' + by[e].n + '</i>' : '') + '</button>'; }).join('') + '</div>';
  }
  function fwdHTML(m) {
    if (!m.forwarded_from_user_id && !m.forwarded_from_name) return '';
    return '<div class="bm-fwd">' + IC.fwd.replace('width="20" height="20"', 'width="12" height="12"') + '<span>Forwarded' + (m.forwarded_from_name ? ' from ' + esc(m.forwarded_from_name) : '') + '</span></div>';
  }
  function renderThread(o) {
    o = o || {};
    if (!R.msgs) return;
    var me = meId(), rows = S.rows;
    var prevTop = R.msgs.scrollTop, prevH = R.msgs.scrollHeight, stick = o.stick || nearBottom();
    if (!rows.length) {
      var who = S.gid ? 'the group' : (S.peer === me ? 'yourself' : nameOf(S.peer));
      R.msgs.innerHTML = S.loadingThread ? '<div class="bm-empty bm-loading"><p>Loading…</p></div>' : '<div class="bm-empty"><div class="bm-empty-ic" aria-hidden="true">\u{1F44B}</div><strong>No messages yet</strong><p>Say hello to ' + esc(who) + '.</p></div>';
      return;
    }
    var out = S.hasMore ? '<button type="button" class="bm-more" data-act="older">' + (S.loadingMore ? 'Loading…' : 'Load earlier messages') + '</button>' : '';
    var curDay = '', open = false;
    rows.forEach(function (m, i) {
      var t = new Date(m.created_at).getTime(), dk = String(dayStart(new Date(t)));
      if (dk !== curDay) { if (open) out += '</section>'; out += '<section class="bm-dayg"><div class="bm-day"><span>' + esc(dayLabel(m.created_at)) + '</span></div>'; curDay = dk; open = true; }
      if (S.unreadFrom && m.id === S.unreadFrom) out += '<div class="bm-unread" id="bmUnreadDiv"><span>Unread messages</span></div>';
      if (isSys(m)) { out += '<div class="bm-sysmsg" data-id="' + esc(m.id) + '"><span>' + esc(sysText(m)) + '</span></div>'; return; }
      var prev = rows[i - 1], next = rows[i + 1];
      var sameP = function (a, b) { return a && b && !isSys(a) && !isSys(b) && a.sender_id === b.sender_id && Math.abs(new Date(b.created_at) - new Date(a.created_at)) < 5 * 60000 && dayStart(new Date(a.created_at)) === dayStart(new Date(b.created_at)) && !(S.unreadFrom && b.id === S.unreadFrom); };
      var first = !sameP(prev, m), last = !sameP(m, next);
      var mine = m.sender_id === me, c = String(m.content || ''), un = isUnsent(m), img = !un && c.indexOf(IMGP) === 0, emo = !un && isEmojiOnly(c), share = !un && !!parseShare(c), quoted = !!m.reply_to_id && !un, fwd = !un && (m.forwarded_from_user_id || m.forwarded_from_name);
      var sel = S.sel && S.sel.has(m.id), gshow = S.gid && !mine;
      out += '<div class="bm-msg' + (mine ? ' mine' : '') + (first ? ' g-first' : '') + (last ? ' g-last' : '') + (emo ? ' emoji' : '') + (img ? ' has-img' : '') + (share ? ' has-share' : '') + (un ? ' unsent' : '') + (m._pending ? ' pending' : '') + (m._failed ? ' failed' : '') + (sel ? ' sel' : '') + (S.sel ? ' selecting' : '') + (m.id === S.jump ? ' flash' : '') + '" data-id="' + esc(m.id) + '"' + (m._failed ? ' role="button" tabindex="0" aria-label="Message not sent. Tap to retry."' : '') + '>'
        + (S.sel ? '<i class="bm-selbox' + (sel ? ' on' : '') + '" aria-hidden="true">' + IC.check + '</i>' : '')
        + (gshow ? (last ? '<span class="bm-gslot">' + avatarHTML(m.sender_id, 'bm-mini') + '</span>' : '<span class="bm-gslot"></span>') : '')
        + '<div class="bm-col">'
        + (gshow && first ? '<span class="bm-sender" style="--h:' + hue(m.sender_id) + '">' + esc(nameOf(m.sender_id)) + '</span>' : '')
        + '<div class="bm-bub">' + fwdHTML(m) + (quoted ? replyHTML(m) : '') + bodyHTML(m) + '<span class="bm-meta2">' + (m.edited_at && !un ? '<em>edited</em>' : '') + '<time>' + esc(fmtTime(m.created_at)) + '</time>' + statusHTML(m) + '</span></div>'
        + reactionsHTML(m) + (m._failed ? '<div class="bm-fail">Not sent. Tap to retry</div>' : '') + '</div></div>';
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
  function autoLoadOK(kind) { var a = (S.set.auto_download || {})[kind] || 'wifi', c = navigator.connection; if (a === 'never') return false; if (c && c.saveData) return false; if (a === 'wifi' && c && c.type === 'cellular') return false; return true; }
  async function hydrateImgs() {
    var imgs = $$('img.bm-img:not([src])', R.msgs); if (!imgs.length) return;
    var s = sb(); if (!s) return;
    if (!autoLoadOK('photos')) { imgs.forEach(function (i) { i.closest('.bm-imgbtn').classList.add('held'); i.closest('.bm-imgbtn').dataset.hold = '1'; }); imgs = imgs.filter(function (i) { return false; }); if (!imgs.length) return; }
    try {
      var paths = Array.from(new Set(imgs.map(function (i) { return i.dataset.p; })));
      var r = await s.storage.from('community-media').createSignedUrls(paths, 3600);
      if (r.error) throw r.error;
      (r.data || []).forEach(function (x) { if (x.signedUrl) S.imgUrls.set(x.path, x.signedUrl); });
      imgs.forEach(function (i) { var u = S.imgUrls.get(i.dataset.p); if (u) { i.src = u; i.classList.add('ok'); } else i.alt = 'Photo unavailable'; });
    } catch (e) { imgs.forEach(function (i) { i.alt = 'Photo unavailable'; }); note('Could not load a photo.', true); }
  }
  async function loadHeldImage(btn) {
    var img = $('img', btn), s = sb(); if (!img || !s) return;
    btn.classList.remove('held'); btn.dataset.hold = '';
    try { var r = await s.storage.from('community-media').createSignedUrls([img.dataset.p], 3600); (r.data || []).forEach(function (x) { if (x.signedUrl) S.imgUrls.set(x.path, x.signedUrl); }); var u = S.imgUrls.get(img.dataset.p); if (u) { img.src = u; img.classList.add('ok'); } } catch (_) { img.alt = 'Photo unavailable'; }
  }
  function updateFab() {
    if (!R.fab) return;
    var far = R.msgs.scrollHeight - R.msgs.scrollTop - R.msgs.clientHeight > 260;
    if (!far) S.newBelow = 0;
    R.fab.hidden = !far;
    R.fabN.hidden = !S.newBelow; R.fabN.textContent = S.newBelow > 99 ? '99+' : S.newBelow;
  }
  function note(t, err) { if (!R.note) return; R.note.textContent = t || ''; R.note.classList.toggle('err', !!err); R.note.classList.toggle('on', !!t); }
  function toast(t) { note(t, true); setTimeout(function () { if (R.note && R.note.textContent === t) note(''); }, 3500); if (!S.open || !R.root) { try { window.setBackendStatus && window.setBackendStatus(t, true); } catch (_) {} } }

  /* pinned bar */
  function renderPinned() {
    if (!R.pinbar) return;
    var n = S.pins.length;
    R.pinbar.hidden = !n;
    if (!n) return;
    var p = S.pins[S.pinIdx % n];
    R.pinbar.innerHTML = '<button type="button" class="bm-pinbtn bm-glass" data-jump="' + esc(p.id) + '" aria-label="Go to pinned message">' + IC.pin + '<span><b>Pinned' + (n > 1 ? ' ' + (S.pinIdx % n + 1) + ' of ' + n : '') + '</b><small>' + esc(snippet(p) || 'Message') + '</small></span></button>';
  }
  async function jumpTo(id) {
    S.jump = id; S.pinIdx = Math.max(0, S.pins.findIndex(function (p) { return p.id === id; })) + 1;
    var tries = 0;
    while (!rowById(id) && S.hasMore && tries < 6) { tries++; await loadOlder(); }
    var el = R.msgs.querySelector('.bm-msg[data-id="' + (window.CSS && CSS.escape ? CSS.escape(id) : id) + '"]');
    if (!el) { S.jump = null; toast('That message is no longer available.'); return; }
    el.scrollIntoView({ block: 'center', behavior: 'smooth' }); el.classList.add('flash');
    setTimeout(function () { S.jump = null; el.classList.remove('flash'); }, 1600);
    renderPinned();
  }

  /* header */
  function typingText() {
    if (!S.typing || S.typing.until < Date.now()) return '';
    return S.gid ? nameOf(S.typing.uid).split(' ')[0] + ' is typing…' : 'typing…';
  }
  function paintHeader() {
    var me = meId(); if (!S.peer && !S.gid) return;
    var sub, name, av;
    if (S.gid) {
      var g = S.groups.get(S.gid) || {}; name = g.name || 'Group'; av = groupAvatarHTML(g);
      sub = typingText() || (g.member_count ? plural(g.member_count, 'member') : 'Group');
    } else {
      var id = S.peer; name = id === me ? 'Saved messages' : nameOf(id); av = avatarHTML(id);
      sub = typingText() || (id === me ? 'Notes to yourself' : (S.flags && S.flags.online ? 'online' : (S.flags && S.flags.last_seen_at ? seenLabel(S.flags.last_seen_at) : (handleOf(id) || 'BMN Community'))));
    }
    R.name.textContent = name; R.sub2.textContent = sub; R.sub2.classList.toggle('live', !!typingText() || !!(S.flags && S.flags.online && !S.gid)); R.av.innerHTML = av; hydrateAvatars(R.av);
    R.who.classList.toggle('founder', !S.gid && isFounder(S.peer));
    setBadge(S.unreadTotal);
    var req = !S.gid && S.peer && S.reqs.has(S.peer);
    R.reqbar.hidden = !req;
    if (req) R.reqbar.innerHTML = '<p>' + esc(nameOf(S.peer)) + ' isn’t someone you follow. Accept to keep chatting.</p><div><button type="button" class="bm-btn bm-primary" data-req="accept">Accept</button><button type="button" class="bm-btn" data-req="decline">Decline</button>' + (S.cap.blocks !== false ? '<button type="button" class="bm-btn danger" data-req="block">Block</button>' : '') + '</div>';
    paintComposerState();
  }
  function paintComposerState() {
    var g = S.gid ? S.groups.get(S.gid) : null, locked = !!(g && g.only_admins_post && !isAdmin());
    var blocked = !S.gid && S.peer && S.blocked.has(S.peer);
    R.form.classList.toggle('locked', locked || blocked);
    R.lock.hidden = !(locked || blocked);
    R.lock.textContent = blocked ? 'You blocked this account. Unblock it from the menu to send messages.' : 'Only admins can send messages in this group.';
    R.reply.hidden = !(S.reply || S.edit);
    if (S.edit) R.reply.innerHTML = '<div class="bm-rbar edit">' + IC.edit + '<span><b>Edit message</b><small>' + esc(snippet(S.edit)) + '</small></span><button type="button" class="bm-x" data-act="cancel-reply" aria-label="Cancel edit">' + IC.close + '</button></div>';
    else if (S.reply) R.reply.innerHTML = '<div class="bm-rbar">' + IC.reply + '<span><b>Replying to ' + esc(S.reply.sender_id === meId() ? 'yourself' : nameOf(S.reply.sender_id)) + '</b><small>' + esc(snippet(S.reply)) + '</small></span><button type="button" class="bm-x" data-act="cancel-reply" aria-label="Cancel reply">' + IC.close + '</button></div>';
    else R.reply.innerHTML = '';
    R.input.placeholder = S.edit ? 'Edit message' : 'Message';
  }

  /* ======================================================================
   * Chat lifecycle
   * ====================================================================== */
  function resetThread() {
    S.rows = []; S.hasMore = false; S.unreadFrom = null; S.newBelow = 0; S.loadingThread = true; S.reply = null; S.edit = null; S.sel = null;
    S.pins = []; S.pinIdx = 0; S.flags = null; S.react = new Map(); S.refs = new Map(); S.typing = null; S.jump = null;
  }
  function showChatView() {
    var stage = D.getElementById('lgttStage'); if (stage) stage.classList.add('bmn-chat-open');
    R.root.dataset.view = 'chat'; R.chat.setAttribute('aria-hidden', 'false'); R.chat.style.transform = ''; R.list.style.transform = ''; R.list.style.opacity = '';
  }
  async function openChat(id) {
    var me = meId();
    if (!me) { if (typeof window.requestCommunityAuth === 'function') window.requestCommunityAuth('inbox'); return; }
    id = id || me;
    if (!UUID.test(String(id))) { toast('That conversation could not be opened.'); return; }
    if (!S.open) open(true);
    saveDraftNow();
    S.peer = id; S.gid = null; resetThread();
    await ensureProfiles([id]);
    if (id !== me && !prof(id).id) { S.peer = null; S.loadingThread = false; toast('That member could not be found.'); return; }
    showChatView(); paintHeader(); applyWall(); restoreDraft(); renderThread(); renderPinned(); setupTyping();
    try {
      var t = await fetchThread();
      if (S.peer !== id) return;
      S.rows = t.rows; S.hasMore = t.more; S.loadingThread = false;
      var first = t.rows.find(function (m) { return m.recipient_id === me && m.sender_id !== me && !m.read_at; });
      S.unreadFrom = first ? first.id : null;
      renderThread({ toUnread: !!first, stick: !first });
      if (D.visibilityState !== 'hidden') scheduleMarkRead();
      loadExtras();
    } catch (e) {
      S.loadingThread = false;
      if (S.peer === id) R.msgs.innerHTML = '<div class="bm-empty"><strong>Could not load this conversation</strong><p>' + esc(e.message || 'Check your connection.') + '</p><button type="button" class="bm-btn" data-act="retry-thread">Try again</button></div>';
    }
    setBadge(S.unreadTotal);
    if (window.matchMedia && matchMedia('(pointer:fine)').matches) setTimeout(function () { try { R.input.focus({ preventScroll: true }); } catch (_) {} }, 250);
  }
  async function openGroup(gid) {
    var me = meId();
    if (!me) { if (typeof window.requestCommunityAuth === 'function') window.requestCommunityAuth('inbox'); return; }
    if (!UUID.test(String(gid))) { toast('That group could not be opened.'); return; }
    if (!S.open) open(true);
    if (!S.groups.has(gid)) { await loadConversations({ silent: true }); }
    if (!S.groups.has(gid)) { toast('That group could not be found. You may no longer be a member.'); return; }
    saveDraftNow();
    var unread = (S.groups.get(gid) || {}).unread || 0;
    S.gid = gid; S.peer = null; resetThread();
    showChatView(); paintHeader(); applyWall(); restoreDraft(); renderThread(); setupTyping();
    try {
      var t = await fetchThread();
      if (S.gid !== gid) return;
      S.rows = t.rows; S.hasMore = t.more; S.loadingThread = false;
      if (unread) { var inc = t.rows.filter(function (m) { return m.sender_id !== me && !isSys(m); }); var f = inc[Math.max(0, inc.length - unread)]; S.unreadFrom = f ? f.id : null; }
      renderThread({ toUnread: !!S.unreadFrom, stick: !S.unreadFrom });
      if (D.visibilityState !== 'hidden') scheduleMarkRead();
      await ensureProfiles(t.rows.map(function (m) { return m.sender_id; })); renderThread({ stick: !S.unreadFrom });
      loadExtras();
    } catch (e) {
      S.loadingThread = false;
      if (S.gid === gid) R.msgs.innerHTML = '<div class="bm-empty"><strong>Could not load this group</strong><p>' + esc(e.message || 'Check your connection.') + '</p><button type="button" class="bm-btn" data-act="retry-thread">Try again</button></div>';
    }
    setBadge(S.unreadTotal);
  }
  function backToList() {
    saveDraftNow();
    S.peer = null; S.gid = null; S.rows = []; S.unreadFrom = null; S.newBelow = 0; S.reply = null; S.edit = null; S.sel = null; S.typing = null; teardownTyping();
    var stage = D.getElementById('lgttStage'); if (stage) stage.classList.remove('bmn-chat-open');
    if (R.root) { R.root.dataset.view = 'list'; R.chat.setAttribute('aria-hidden', 'true'); R.chat.style.transform = ''; R.list.style.transform = ''; R.list.style.opacity = ''; }
    try { R.input.blur(); } catch (_) {}
    R.input.value = ''; autosize(); syncSend();
    closeSheet(); closeCtx(); setBadge(S.unreadTotal);
    renderList(); loadConversations({ silent: true });
  }
  async function loadOlder() {
    if (S.loadingMore || !S.hasMore || !(S.peer || S.gid) || !S.rows.length) return;
    S.loadingMore = true; var tag = curKey(); renderThread({ anchorOlder: true });
    try {
      var t = await fetchThread(S.rows[0].created_at);
      if (curKey() !== tag) return;
      var have = new Set(S.rows.map(function (m) { return m.id; }));
      S.rows = t.rows.filter(function (m) { return !have.has(m.id); }).concat(S.rows); S.hasMore = t.more;
      await Promise.all([fetchReactions(t.rows.map(function (m) { return m.id; })), fetchRefs(t.rows)]);
    } catch (e) { note('Could not load earlier messages.', true); }
    S.loadingMore = false; renderThread({ anchorOlder: true });
  }
  function sigOf(rows) { return JSON.stringify(rows.filter(function (m) { return !m._pending && !m._failed; }).slice(-PAGE).map(function (m) { return [m.id, m.read_at, m.edited_at, m.unsent_at, m.content === UNSENT]; })); }
  function reactSig() { var o = []; S.react.forEach(function (v, k) { o.push(k + ':' + v.map(function (x) { return x.user_id + x.emoji; }).sort().join(',')); }); return o.sort().join('|') + '#' + S.pins.map(function (p) { return p.id; }).join(','); }
  async function refreshThread() {
    var tag = curKey(); if (!tag) return;
    try {
      var t = await fetchThread(); if (curKey() !== tag) return;
      var incoming = 0, near = nearBottom();
      var before = sigOf(S.rows), rb = reactSig();
      t.rows.forEach(function (m) { var r = mergeRow(m); if (r.isNew && m.sender_id !== meId() && !isSys(m)) incoming++; });
      var keep = new Set(t.rows.map(function (m) { return m.id; })), oldest = t.rows.length ? t.rows[0].created_at : null;
      S.rows = S.rows.filter(function (m) { return m._pending || m._failed || keep.has(m.id) || (oldest && new Date(m.created_at) < new Date(oldest)); });
      var ids = S.rows.filter(function (m) { return !m._pending && !m._failed; }).slice(-PAGE).map(function (m) { return m.id; });
      await Promise.all([fetchReactions(ids), fetchRefs(t.rows), fetchPins()]);
      if (S.gid) { var g = S.groups.get(S.gid); if (g && g.member_count !== (S.members.get(S.gid) || []).length && S.members.has(S.gid)) fetchMembers(S.gid); }
      if (curKey() !== tag) return;
      if (before !== sigOf(S.rows) || rb !== reactSig()) { renderThread({ stick: near }); renderPinned(); if (!near && incoming) { S.newBelow += incoming; updateFab(); } }
      if (incoming && D.visibilityState !== 'hidden') scheduleMarkRead();
    } catch (_) {}
  }

  /* ---------- drafts (this device) ---------- */
  function saveDraftNow() {
    if (!R.input || !(S.peer || S.gid) || S.edit) return;
    setDraft(S.gid ? 'grp' : 'dm', S.gid || S.peer, R.input.value);
  }
  function restoreDraft() {
    var d = getDraft(S.gid ? 'grp' : 'dm', S.gid || S.peer);
    R.input.value = d || ''; autosize(); syncSend();
  }
  var draftTimer = 0;
  function onDraftInput() { clearTimeout(draftTimer); draftTimer = setTimeout(saveDraftNow, 300); }

  /* ---------- typing indicator (realtime broadcast, no database writes) ---------- */
  function teardownTyping() { try { if (S.typeCh && sb() && sb().removeChannel) sb().removeChannel(S.typeCh); else S.typeCh && S.typeCh.unsubscribe && S.typeCh.unsubscribe(); } catch (_) {} S.typeCh = null; clearTimeout(S.typeTimer); }
  function setupTyping() {
    teardownTyping();
    var s = sb(), me = meId(); if (!s || !s.channel || !me || S.peer === me) return;
    var topic = S.gid ? 'bmn-typing-g-' + S.gid : 'bmn-typing-' + [me, S.peer].sort().join('-');
    try {
      S.typeCh = s.channel(topic, { config: { broadcast: { self: false } } })
        .on('broadcast', { event: 'typing' }, function (msg) {
          var p = msg && msg.payload; if (!p || !p.uid || p.uid === me) return;
          if (S.set.typing_indicator === false) return;
          if (!S.gid && S.flags && S.flags.typing_indicator === false) return;
          S.typing = { uid: p.uid, until: Date.now() + 4000 };
          ensureProfiles([p.uid]).then(paintHeader); paintHeader();
          clearTimeout(S.typeTimer); S.typeTimer = setTimeout(paintHeader, 4200);
        }).subscribe();
    } catch (_) { S.typeCh = null; }
  }
  function sendTyping() {
    if (!S.typeCh || S.set.typing_indicator === false || Date.now() - S.typingSent < 2500) return;
    if (!S.gid && S.flags && S.flags.blocked) return;
    S.typingSent = Date.now();
    try { S.typeCh.send({ type: 'broadcast', event: 'typing', payload: { uid: meId() } }); } catch (_) {}
  }

  /* ======================================================================
   * Sending
   * ====================================================================== */
  function queue(content) {
    var me = meId(), row = { id: 'tmp-' + (++S.tmp), sender_id: me, content: content, created_at: new Date().toISOString(), read_at: null, _pending: true };
    if (S.gid) { row.group_id = S.gid; row._g = true; row.kind = 'user'; } else row.recipient_id = S.peer;
    if (S.reply && S.cap.actions !== false) { row.reply_to_id = S.reply.id; S.refs.set(S.reply.id, S.reply); }
    S.reply = null; paintComposerState();
    S.rows.push(row); renderThread({ stick: true }); haptic('send');
    return doSend(row);
  }
  var NOTIF_OK = true;
  async function doSend(row) {
    var s = sb(); row._pending = true; row._failed = false;
    try {
      if (navigator.onLine === false) throw { bmnErr: 'You are offline. Your message is kept. Tap it to retry.' };
      var v = await verifiedSession(); if (v.expired) throw { bmnExpired: true }; if (v.err) throw { bmnErr: v.err };
      var uid = v.user.id, g = !!row.group_id, r;
      var ins = g ? { group_id: row.group_id, sender_id: uid, content: row.content } : { sender_id: uid, recipient_id: row.recipient_id, content: row.content };
      if (row.reply_to_id && S.cap.actions !== false) ins.reply_to_id = row.reply_to_id;
      var sel = g ? GCOLS : (S.cap.actions === false ? 'id,sender_id,recipient_id,content,created_at,read_at' : 'id,sender_id,recipient_id,content,created_at,read_at,reply_to_id,forwarded_from_user_id,forwarded_from_name,edited_at,unsent_at,expires_at');
      r = await s.from(g ? 'group_messages' : 'messages').insert(ins).select(sel).single();
      if (r.error && !g && /column/i.test(String(r.error.message || ''))) { r = await s.from('messages').insert(ins).select('id,sender_id,recipient_id,content,created_at,read_at').single(); }
      if (r.error) throw r.error;
      var real = r.data; if (g) real._g = true;
      var i = S.rows.findIndex(function (m) { return m === row || m.id === row.id; });
      var dupe = S.rows.findIndex(function (m) { return m.id === real.id; });
      if (dupe >= 0 && i >= 0 && dupe !== i) S.rows.splice(i, 1); else if (i >= 0) S.rows[i] = Object.assign({}, real);
      sortRows(); if ((g && S.gid === row.group_id) || (!g && S.peer === row.recipient_id)) renderThread({ stick: true });
      if (!g && row.recipient_id !== uid && NOTIF_OK) { try { s.from('notifications').insert({ user_id: row.recipient_id, actor_id: uid, type: 'message' }).then(function (x) { if (x && x.error) NOTIF_OK = false; }, function () { NOTIF_OK = false; }); } catch (_) { NOTIF_OK = false; } }
      if (g) { var gg = S.groups.get(row.group_id); if (gg) { gg.last = { id: real.id, content: real.content, sender_id: uid, kind: 'user', created_at: real.created_at }; } }
      else { var c = S.convs.get(row.recipient_id) || { peer: row.recipient_id, unread: 0 }; c.last = real; S.convs.set(row.recipient_id, c); }
      setDraft(g ? 'grp' : 'dm', g ? row.group_id : row.recipient_id, '');
      if (R.rows) renderList();
      note('');
    } catch (e) {
      row._pending = false; row._failed = true; row._err = friendly(e);
      if ((row.group_id && S.gid === row.group_id) || (row.recipient_id && S.peer === row.recipient_id)) { renderThread({ stick: true }); note(row._err, true); }
    }
  }
  function retry(id) {
    var row = S.rows.find(function (m) { return m.id === id && m._failed; }); if (!row) return;
    row._failed = false; row._pending = true; note(''); renderThread({ stick: true }); doSend(row);
  }
  function submit() {
    var me = meId(), text = R.input.value.trim();
    if (!me) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    if (!(S.peer || S.gid) || !text) return;
    if (S.peer && !UUID.test(String(S.peer))) { note('This conversation has no valid recipient. Go back and open it again.', true); return; }
    if (text.length > MAX_LEN) { note('Messages can be up to ' + MAX_LEN + ' characters.', true); return; }
    if (R.form.classList.contains('locked')) { note(R.lock.textContent, true); return; }
    if (S.edit) { var ed = S.edit; R.input.value = ''; autosize(); syncSend(); S.edit = null; paintComposerState(); doEdit(ed, text); return; }
    R.input.value = ''; autosize(); syncSend(); note(''); setDraft(S.gid ? 'grp' : 'dm', S.gid || S.peer, '');
    queue(text);
    try { R.input.focus({ preventScroll: true }); } catch (_) {}
  }
  async function sendImage(file) {
    var s = sb(), me = meId();
    if (!file) return;
    if (!me) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    if (!s || !(S.peer || S.gid)) return;
    if (R.form.classList.contains('locked')) { note(R.lock.textContent, true); return; }
    if (!/^image\//.test(file.type)) { note('Please choose a photo.', true); return; }
    if (file.size > 25 * 1024 * 1024) { note('That photo is larger than 25 MB. Choose a smaller one.', true); return; }
    if (navigator.onLine === false) { note('You are offline. Reconnect to send photos.', true); return; }
    var peer = S.peer, gid = S.gid; note('Sending photo…');
    try {
      var v = await verifiedSession(); if (v.expired) throw { bmnExpired: true }; if (v.err) throw { bmnErr: v.err };
      var uid = v.user.id;
      var blob = await imageToBlob(file, 1600, 0.82);
      var path = uid + '/messages/' + Date.now() + '-' + Math.random().toString(36).slice(2, 8) + '.jpg';
      var up = await s.storage.from('community-media').upload(path, blob, { cacheControl: '2592000', upsert: false, contentType: 'image/jpeg' });
      if (up.error) throw up.error;
      S.imgUrls.set(path, URL.createObjectURL(blob));
      var ins = gid ? { group_id: gid, sender_id: uid, content: IMGP + path } : { sender_id: uid, recipient_id: peer, content: IMGP + path };
      var r = await s.from(gid ? 'group_messages' : 'messages').insert(ins).select(gid ? GCOLS : 'id,sender_id,recipient_id,content,created_at,read_at').single();
      if (r.error) { try { await s.storage.from('community-media').remove([path]); } catch (_) {} throw r.error; }
      if (gid) r.data._g = true;
      if ((gid && S.gid === gid) || (!gid && S.peer === peer)) { mergeRow(r.data); renderThread({ stick: true }); }
      if (gid) { var gg = S.groups.get(gid); if (gg) gg.last = { id: r.data.id, content: r.data.content, sender_id: uid, kind: 'user', created_at: r.data.created_at }; }
      else { var c = S.convs.get(peer) || { peer: peer, unread: 0 }; c.last = r.data; S.convs.set(peer, c); }
      renderList();
      if (!gid && peer !== uid && NOTIF_OK) { try { s.from('notifications').insert({ user_id: peer, actor_id: uid, type: 'message' }).then(function (x) { if (x && x.error) NOTIF_OK = false; }, function () { NOTIF_OK = false; }); } catch (_) { NOTIF_OK = false; } }
      note(''); haptic('send');
    } catch (e) { note(e && (e.bmnExpired || e.bmnErr) ? friendly(e) : 'Photo not sent: ' + ((e && e.message) || 'check your connection'), true); }
  }
  function imageToBlob(file, max, q) {
    return new Promise(function (res, rej) {
      var url = URL.createObjectURL(file), im = new Image();
      im.onload = function () { var k = Math.min(1, max / Math.max(im.width, im.height)), c = D.createElement('canvas'); c.width = Math.round(im.width * k); c.height = Math.round(im.height * k); c.getContext('2d').drawImage(im, 0, 0, c.width, c.height); URL.revokeObjectURL(url); c.toBlob(function (b) { b ? res(b) : rej(new Error('Could not process this photo')); }, 'image/jpeg', q); };
      im.onerror = function () { URL.revokeObjectURL(url); rej(new Error('This photo format is not supported')); };
      im.src = url;
    });
  }

  /* ======================================================================
   * Realtime + polling. Realtime is used when the tables are published; otherwise polling carries everything.
   * ====================================================================== */
  function teardownRT() { try { S.ch && S.ch.unsubscribe && S.ch.unsubscribe(); } catch (_) {} S.ch = null; S.chUser = null; S.chSig = ''; }
  function setupRT() {
    var s = sb(), me = meId();
    if (!s || !me || !s.channel) return;
    var sig = me + ':' + (S.cap.groups === true ? 'g' : '') + (S.cap.actions === true ? 'a' : '');
    if (S.ch && S.chSig === sig) return;
    teardownRT();
    try {
      var on = function (table, filter) { var o = { event: '*', schema: 'public', table: table }; if (filter) o.filter = filter; return o; };
      var ch = s.channel('bmn-messages-' + me)
        .on('postgres_changes', on('messages', 'recipient_id=eq.' + me), onRT)
        .on('postgres_changes', on('messages', 'sender_id=eq.' + me), onRT);
      if (S.cap.groups === true) ch = ch.on('postgres_changes', on('group_messages'), onRTGroup).on('postgres_changes', on('group_members'), onRTSoft);
      if (S.cap.actions === true) ch = ch.on('postgres_changes', on('message_reactions'), onRTSoft).on('postgres_changes', on('message_pins'), onRTSoft);
      S.ch = ch.subscribe(); S.chUser = me; S.chSig = sig;
    } catch (_) { S.ch = null; }
  }
  var softTimer = 0;
  function onRTSoft() { S.lastRT = Date.now(); clearTimeout(softTimer); softTimer = setTimeout(function () { if (S.open && (S.peer || S.gid)) refreshThread(); loadConversations({ silent: true }); }, 250); }
  function onRTGroup(p) {
    var me = meId(), row = p && p.new; if (!me || !row || !row.id || !row.group_id) return;
    S.lastRT = Date.now();
    var g = S.groups.get(row.group_id), viewing = S.open && S.gid === row.group_id && D.visibilityState !== 'hidden';
    if (p.eventType === 'INSERT') {
      if (!g) { loadConversations({ silent: true }); }
      else {
        if (!g.last || new Date(row.created_at) >= new Date(g.last.created_at)) g.last = { id: row.id, content: row.content, sender_id: row.sender_id, kind: row.kind, created_at: row.created_at };
        if (row.sender_id !== me && row.kind === 'user' && !viewing) { g.unread = (g.unread || 0) + 1; haptic('tap'); }
        ensureProfiles([row.sender_id]).then(function () { if (R.rows) renderList(); });
        recount(); if (R.rows) renderList();
      }
    }
    if (S.open && S.gid === row.group_id) {
      var near = nearBottom(); row._g = true; var r = mergeRow(row); renderThread({ stick: near });
      if (row.sender_id !== me && p.eventType === 'INSERT') { if (!near) { S.newBelow++; updateFab(); } if (viewing) scheduleMarkRead(); }
    }
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
      if (incoming && !viewing) { c.unread = (c.unread || 0) + 1; if (!isMuted('p:' + peer)) haptic('tap'); }
      recount(); if (R.rows) renderList();
    }
    if (S.open && S.peer === peer) {
      var near = nearBottom(), r = mergeRow(row);
      renderThread({ stick: near });
      if (incoming) { if (!near) { S.newBelow++; updateFab(); } if (viewing) scheduleMarkRead(); }
    }
  }
  function poll() {
    if (S.pollBusy) return;
    var me = meId();
    if (!me) { if (S.ch) teardownRT(); if (S.unreadTotal) { S.convs = new Map(); S.groups = new Map(); recount(); } return; }
    if (D.visibilityState === 'hidden') return;
    setupRT();
    S.pollBusy = true; S.tick++;
    var jobs = [];
    var rtFresh = Date.now() - S.lastRT < 12000;
    if (S.open && (S.peer || S.gid)) { if (!rtFresh || S.tick % 6 === 0) jobs.push(refreshThread()); if (S.tick % 3 === 0) jobs.push(loadConversations({ silent: true })); }
    if (S.open && !S.peer && !S.gid) { if (!rtFresh || S.tick % 6 === 0) jobs.push(loadConversations({ silent: true })); }
    if (!S.open && (S.tick % 4 === 0 || S.lastList === 0)) jobs.push(refreshUnreadOnly());
    Promise.all(jobs).catch(function () {}).then(function () { S.pollBusy = false; });
  }
  async function refreshUnreadOnly() {
    if (S.rpcInbox === true || S.cap.groups === true || S.convs.size === 0 && S.lastList === 0) { await loadConversations({ silent: true }); return; }
    var un = await fetchUnreadCounts(); if (!un) return;
    var changed = false;
    S.convs.forEach(function (c, peer) { var n = un.get(peer) || 0; if (c.unread !== n) { c.unread = n; changed = true; } });
    un.forEach(function (n, peer) { if (!S.convs.has(peer)) changed = true; });
    if (changed || S.lastList === 0) await loadConversations({ silent: true }); else recount();
  }

  /* ======================================================================
   * Sheets, confirmations
   * ====================================================================== */
  function closeSheet() { if (R.sheet) { R.sheet.hidden = true; R.sheet.innerHTML = ''; R.sheet.onclick = null; R.sheet.oninput = null; R.sheet.onchange = null; } }
  function sheet(title, items, extra, opts) {
    opts = opts || {};
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass' + (opts.tall ? ' bm-tall' : '') + '" role="dialog" aria-modal="true" aria-label="' + esc(title) + '"><div class="bm-grab"></div><h2>' + esc(title) + '</h2>' + (extra || '') + items.map(function (it, i) {
      return '<button type="button" class="bm-act' + (it.danger ? ' danger' : '') + '" data-i="' + i + '">' + (it.icon || '') + '<span>' + esc(it.label) + '</span></button>';
    }).join('') + '<button type="button" class="bm-act cancel" data-cancel="1"><span>' + (opts.done || 'Cancel') + '</span></button></div>';
    R.sheet.onclick = function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var b = e.target.closest('.bm-act[data-i]'); if (!b) return;
      var it = items[+b.dataset.i]; if (!it.keep) closeSheet(); it && it.run && it.run();
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
  function lightbox(url) {
    var d = D.createElement('div'); d.className = 'bm-lightbox'; d.setAttribute('role', 'dialog'); d.setAttribute('aria-label', 'Photo');
    d.innerHTML = '<img alt="Photo"><button type="button" aria-label="Close photo">✕</button>'; d.querySelector('img').src = url;
    d.onclick = function () { d.remove(); }; R.root.appendChild(d); d.querySelector('button').focus();
  }
  async function clearConversation(peer) {
    var s = sb(), me = meId(); if (!s || !me || !peer || peer === me) return;
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
  async function leaveGroup(gid) {
    var s = sb(), g = S.groups.get(gid); if (!s || !g) return;
    var ok = await confirmSheet('Leave “' + g.name + '”?', g.my_role === 'owner' ? 'Ownership passes to another member. You will no longer receive messages from this group.' : 'You will no longer receive messages from this group.', 'Leave group');
    if (!ok) return;
    try {
      var r = await s.rpc('bmn_leave_group', { p_group: gid }); if (r.error) throw r.error;
      S.groups.delete(gid); recount();
      if (S.gid === gid) backToList(); else renderList();
      toast('You left the group.');
    } catch (e) { toast(rpcMsg(e)); }
  }
  var ICON_MORE = '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor" aria-hidden="true"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>';

  /* ======================================================================
   * Conversation actions (list rows + chat menu)
   * ====================================================================== */
  function muteSheet(peer, gid) {
    var set = function (ms) { return function () { setConv(peer, gid, { muted_until: ms ? new Date(Date.now() + ms).toISOString() : new Date(Date.now() + 100 * 365 * 864e5).toISOString() }); }; };
    sheet('Mute notifications', [{ label: 'For 8 hours', icon: IC.mute, run: set(8 * 36e5) }, { label: 'For 1 week', icon: IC.mute, run: set(7 * 864e5) }, { label: 'Always', icon: IC.mute, run: set(0) }]);
  }
  function rowAction(key, act) {
    var peer = key.slice(0, 2) === 'p:' ? key.slice(2) : null, gid = key.slice(0, 2) === 'g:' ? key.slice(2) : null, c = S.cs.get(key) || {};
    if (act === 'pin') return setConv(peer, gid, { pinned_at: c.pinned_at ? null : new Date().toISOString() });
    if (act === 'mute') { if (isMuted(key)) return setConv(peer, gid, { muted_until: null }); return muteSheet(peer, gid); }
    if (act === 'arch') return setConv(peer, gid, { archived_at: isArchived({ key: key, last: peer ? (S.convs.get(peer) || {}).last : (S.groups.get(gid) || {}).last, unread: (peer ? (S.convs.get(peer) || {}).unread : (S.groups.get(gid) || {}).unread) || 0 }) ? null : new Date().toISOString() });
    if (act === 'del') return gid ? leaveGroup(gid) : clearConversation(peer);
  }
  function rowMenu(key) {
    var peer = key.slice(0, 2) === 'p:' ? key.slice(2) : null, gid = key.slice(0, 2) === 'g:' ? key.slice(2) : null, c = S.cs.get(key) || {};
    var un = peer ? (S.convs.get(peer) || {}).unread : (S.groups.get(gid) || {}).unread, items = [];
    items.push({ label: 'Open', run: function () { gid ? openGroup(gid) : openChat(peer); } });
    if (un) items.push({ label: 'Mark as read', icon: IC.select, run: function () { gid ? markGroupRead(gid) : markRead(peer); } });
    items.push({ label: c.pinned_at ? 'Unpin' : 'Pin to top', icon: IC.pin, run: function () { rowAction(key, 'pin'); } });
    items.push({ label: isMuted(key) ? 'Unmute' : 'Mute', icon: isMuted(key) ? IC.bell : IC.mute, run: function () { rowAction(key, 'mute'); } });
    items.push({ label: c.archived_at ? 'Unarchive' : 'Archive', icon: IC.archive, run: function () { rowAction(key, 'arch'); } });
    if (gid) items.push({ label: 'Leave group', danger: true, icon: IC.leave, run: function () { leaveGroup(gid); } });
    else if (peer !== meId()) items.push({ label: 'Clear conversation', danger: true, icon: IC.trash, run: function () { clearConversation(peer); } });
    sheet(gid ? (S.groups.get(gid) || {}).name || 'Group' : (peer === meId() ? 'Saved messages' : nameOf(peer)), items);
  }
  async function setBlock(peer, on) {
    var s = sb(), me = meId(); if (!s || !me) return;
    try {
      var r = on ? await s.from('user_blocks').insert({ user_id: me, target_id: peer, kind: 'block' }) : await s.from('user_blocks').delete().eq('user_id', me).eq('target_id', peer).eq('kind', 'block');
      if (r.error && !(on && r.error.code === '23505')) throw r.error;
      if (on) S.blocked.add(peer); else S.blocked.delete(peer);
      paintComposerState(); toast(on ? nameOf(peer) + ' is blocked. Neither of you can send messages.' : nameOf(peer) + ' is unblocked.');
      if (R.rows) renderList();
    } catch (e) { toast(rpcMsg(e)); }
  }
  async function respondRequest(peer, accept) {
    var s = sb(); if (!s) return;
    try {
      var r = await s.rpc('bmn_respond_message_request', { p_requester: peer, p_accept: accept }); if (r.error) throw r.error;
      S.reqs.delete(peer); recount();
      if (!accept) { await setConv(peer, null, { archived_at: new Date().toISOString() }); if (S.peer === peer) backToList(); toast('Request declined.'); }
      else { paintHeader(); toast('Request accepted.'); }
      renderList();
    } catch (e) { toast(rpcMsg(e)); }
  }
  function chatMenu() {
    var me = meId(), peer = S.peer; if (S.gid) { groupInfoSheet(); return; } if (!peer) return;
    var items = [];
    if (peer !== me) items.push({ label: 'View profile', icon: IC.user, run: function () { close(true); try { window.LGTT && window.LGTT.openProfile(peer); } catch (_) {} } });
    items.push({ label: 'Chat wallpaper', icon: IC.wall, run: wallpaperSheet });
    items.push({ label: isMuted('p:' + peer) ? 'Unmute' : 'Mute', icon: isMuted('p:' + peer) ? IC.bell : IC.mute, run: function () { rowAction('p:' + peer, 'mute'); } });
    if (peer !== me && S.cap.blocks !== false) { var b = S.blocked.has(peer); items.push({ label: b ? 'Unblock' : 'Block', danger: !b, icon: IC.block, run: function () { b ? setBlock(peer, false) : confirmSheet('Block ' + nameOf(peer) + '?', 'They won’t be able to message you, and you won’t be able to message them.', 'Block').then(function (ok) { if (ok) setBlock(peer, true); }); } }); }
    if (peer !== me) items.push({ label: 'Clear conversation', danger: true, icon: IC.trash, run: function () { clearConversation(peer); } });
    sheet(peer === me ? 'Saved messages' : nameOf(peer), items);
  }

  /* ======================================================================
   * Message actions
   * ====================================================================== */
  function scopeFor(m) { return m._g || S.gid ? 'group' : 'dm'; }
  function copyText(t) {
    var done = function () { toast('Copied.'); };
    try { if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(t).then(done, function () { fallbackCopy(t); done(); }); return; } } catch (_) {}
    fallbackCopy(t); done();
  }
  function fallbackCopy(t) { var a = D.createElement('textarea'); a.value = t; a.setAttribute('readonly', ''); a.style.cssText = 'position:fixed;opacity:0;top:0'; D.body.appendChild(a); a.select(); try { D.execCommand('copy'); } catch (_) {} a.remove(); }
  function withinWindow(m, key, def) { return (Date.now() - new Date(m.created_at).getTime()) / 1000 <= gcfg(key, def); }
  function canEdit(m) { return S.cap.actions !== false && m.sender_id === meId() && isTextMsg(m) && !m._pending && !m._failed && withinWindow(m, 'edit_window_seconds', 172800); }
  function canUnsend(m) { return S.cap.actions !== false && !m._pending && !m._failed && !isUnsent(m) && ((m.sender_id === meId() && withinWindow(m, 'unsend_window_seconds', 172800)) || (S.gid && isAdmin())); }
  function msgText(m) { var c = String(m.content || ''); return isTextMsg(m) ? c : (parseShare(c) ? c : ''); }
  function startReply(m) { S.reply = { id: m.id, sender_id: m.sender_id, content: m.content, unsent_at: m.unsent_at }; S.edit = null; paintComposerState(); try { R.input.focus({ preventScroll: true }); } catch (_) {} }
  function startEdit(m) { S.edit = m; S.reply = null; R.input.value = m.content; autosize(); syncSend(); paintComposerState(); try { R.input.focus({ preventScroll: true }); R.input.setSelectionRange(R.input.value.length, R.input.value.length); } catch (_) {} }
  async function doEdit(m, text) {
    var s = sb(); if (text === m.content) return;
    var old = { content: m.content, edited_at: m.edited_at }; m.content = text; m.edited_at = new Date().toISOString(); renderThread();
    try { var r = await s.rpc('bmn_edit_message', { p_scope: scopeFor(m), p_id: m.id, p_content: text }); if (r.error) throw r.error; if (r.data) m.edited_at = r.data; renderThread(); refreshListLast(m); }
    catch (e) { m.content = old.content; m.edited_at = old.edited_at; renderThread(); toast(rpcMsg(e)); }
  }
  function refreshListLast(m) {
    if (S.gid) { var g = S.groups.get(S.gid); if (g && g.last && g.last.id === m.id) { g.last.content = m.content; g.last.unsent_at = m.unsent_at; } }
    else { var c = S.convs.get(S.peer); if (c && c.last && c.last.id === m.id) c.last = Object.assign({}, c.last, { content: m.content, unsent_at: m.unsent_at }); }
    renderList();
  }
  async function doUnsend(m) {
    var s = sb(), ok = await confirmSheet('Unsend this message?', S.gid ? 'It will be replaced by “This message was unsent” for everyone in the group.' : 'It will be replaced by “This message was unsent” for both of you.', 'Unsend for everyone');
    if (!ok) return;
    try { var r = await s.rpc('bmn_unsend_message', { p_scope: scopeFor(m), p_id: m.id }); if (r.error) throw r.error; m.unsent_at = r.data || new Date().toISOString(); S.react.delete(m.id); renderThread(); refreshListLast(m); fetchPins().then(renderPinned); }
    catch (e) { toast(rpcMsg(e)); }
  }
  async function doDeleteForMe(m) {
    var s = sb();
    try { var r = await s.rpc('bmn_delete_message_for_me', { p_scope: scopeFor(m), p_id: m.id }); if (r.error) throw r.error; S.rows = S.rows.filter(function (x) { return x.id !== m.id; }); renderThread(); loadConversations({ silent: true }); }
    catch (e) { toast(rpcMsg(e)); }
  }
  async function doReact(m, emoji) {
    var s = sb(), me = meId(), list = (S.react.get(m.id) || []).slice(), prev = list.slice(), mine = list.find(function (x) { return x.user_id === me; });
    var next = list.filter(function (x) { return x.user_id !== me; }); if (!mine || mine.emoji !== emoji) next.push({ user_id: me, emoji: emoji });
    next.length ? S.react.set(m.id, next) : S.react.delete(m.id); renderThread(); haptic('tap');
    try { var r = await s.rpc('bmn_toggle_reaction', { p_scope: scopeFor(m), p_id: m.id, p_emoji: emoji }); if (r.error) throw r.error; }
    catch (e) { prev.length ? S.react.set(m.id, prev) : S.react.delete(m.id); renderThread(); toast(rpcMsg(e)); }
  }
  async function doPin(m, on) {
    var s = sb();
    try { var r = await s.rpc('bmn_set_message_pin', { p_scope: scopeFor(m), p_id: m.id, p_pinned: on }); if (r.error) throw r.error; await fetchPins(); renderPinned(); toast(on ? 'Message pinned.' : 'Message unpinned.'); }
    catch (e) { toast(rpcMsg(e)); }
  }
  async function doSave(m) {
    var s = sb(), me = meId();
    try { var r = await s.rpc('bmn_forward_message', { p_scope: scopeFor(m), p_id: m.id, p_to_peer: me }); if (r.error) throw r.error; toast('Saved to your saved messages.'); loadConversations({ silent: true }); }
    catch (e) { toast(rpcMsg(e)); }
  }
  function reportSheet(m) {
    sheet('Report message', REASONS.map(function (r) { return { label: r[1], run: async function () {
      try { var x = await sb().rpc('bmn_report_message', { p_scope: scopeFor(m), p_id: m.id, p_reason: r[0] }); if (x.error) throw x.error; toast('Thanks. Your report was sent to the BMN team.'); } catch (e) { toast(rpcMsg(e)); }
    } }; }), '<p class="bm-p">Reports go to BMN moderators with this message. The sender isn’t told.</p>');
  }
  function forwardSheet(msgs) {
    if (!msgs.length) return;
    var pick = new Set(), me = meId(), q = '';
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="Forward to"><div class="bm-grab"></div><h2>Forward ' + (msgs.length > 1 ? msgs.length + ' messages' : 'message') + '</h2><label class="bm-search bm-glass-in">' + IC.search + '<input type="search" id="bmFwdQ" placeholder="Search chats" autocomplete="off" aria-label="Search chats"></label><div class="bm-people" id="bmFwdList"></div><button type="button" class="bm-act bm-primary-act" id="bmFwdGo" disabled><span>Forward</span></button><button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
    var list = $('#bmFwdList', R.sheet), go = $('#bmFwdGo', R.sheet);
    var targets = function () {
      var arr = []; S.convs.forEach(function (c, id) { arr.push({ k: 'p:' + id, name: id === me ? 'Saved messages' : nameOf(id), peer: id, t: new Date(c.last.created_at).getTime() }); });
      S.groups.forEach(function (g, id) { arr.push({ k: 'g:' + id, name: g.name, gid: id, t: new Date((g.last && g.last.created_at) || 0).getTime() }); });
      if (!S.convs.has(me)) arr.push({ k: 'p:' + me, name: 'Saved messages', peer: me, t: 0 });
      return arr.filter(function (x) { return !q || x.name.toLowerCase().indexOf(q) >= 0; }).sort(function (a, b) { return b.t - a.t; });
    };
    var draw = function () {
      list.innerHTML = targets().map(function (x) { var on = pick.has(x.k); return '<button type="button" class="bm-row bm-person' + (on ? ' sel' : '') + '" data-k="' + esc(x.k) + '" role="checkbox" aria-checked="' + String(on) + '">' + (x.gid ? groupAvatarHTML(S.groups.get(x.gid)) : avatarHTML(x.peer)) + '<span class="bm-meta"><span class="bm-top"><strong>' + esc(x.name) + '</strong></span><span class="bm-bot"><small>' + (x.gid ? 'Group' : 'Chat') + '</small></span></span><i class="bm-tick' + (on ? ' on' : '') + '" aria-hidden="true">' + IC.check + '</i></button>'; }).join('') || '<div class="bm-empty small"><p>No chats found.</p></div>';
      go.disabled = !pick.size; hydrateAvatars(list);
    };
    draw();
    $('#bmFwdQ', R.sheet).oninput = function (e) { q = e.target.value.trim().toLowerCase(); draw(); };
    R.sheet.onclick = async function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var row = e.target.closest('[data-k]'); if (row) { var k = row.dataset.k; pick.has(k) ? pick.delete(k) : pick.add(k); draw(); return; }
      if (e.target.closest('#bmFwdGo') && pick.size) {
        go.disabled = true; var fails = 0, s = sb();
        for (var i = 0; i < msgs.length; i++) for (const k of pick) {
          try { var args = { p_scope: scopeFor(msgs[i]), p_id: msgs[i].id }; if (k[0] === 'g') args.p_to_group = k.slice(2); else args.p_to_peer = k.slice(2); var r = await s.rpc('bmn_forward_message', args); if (r.error) throw r.error; } catch (er) { fails++; }
        }
        closeSheet(); S.sel = null; setSelUI(); renderThread();
        toast(fails ? 'Some messages could not be forwarded.' : 'Forwarded.'); loadConversations({ silent: true });
      }
    };
    setTimeout(function () { try { $('#bmFwdQ', R.sheet).focus(); } catch (_) {} }, 120);
  }

  /* ----- selection mode ----- */
  function setSelUI() {
    var on = !!S.sel; R.chat.classList.toggle('selecting', on); R.selbar.hidden = !on;
    if (on) { var n = S.sel.size; R.selbar.innerHTML = '<button type="button" class="bm-x" data-sel="cancel" aria-label="Cancel selection">' + IC.close + '</button><strong>' + n + ' selected</strong><div><button type="button" data-sel="copy"' + (n ? '' : ' disabled') + ' aria-label="Copy">' + IC.copy + '</button><button type="button" data-sel="fwd"' + (n && S.cap.actions !== false ? '' : ' disabled') + ' aria-label="Forward">' + IC.fwd + '</button><button type="button" data-sel="del"' + (n && S.cap.actions !== false ? '' : ' disabled') + ' aria-label="Delete for me" class="danger">' + IC.trash + '</button></div>'; }
  }
  function toggleSel(id) { if (!S.sel) return; S.sel.has(id) ? S.sel.delete(id) : S.sel.add(id); setSelUI(); renderThread(); haptic('tap'); }
  async function selAction(a) {
    var msgs = S.rows.filter(function (m) { return S.sel && S.sel.has(m.id); });
    if (a === 'cancel') { S.sel = null; setSelUI(); renderThread(); return; }
    if (!msgs.length) return;
    if (a === 'copy') { copyText(msgs.map(function (m) { return msgText(m) || snippet(m); }).join('\n')); S.sel = null; setSelUI(); renderThread(); }
    if (a === 'fwd') forwardSheet(msgs.filter(function (m) { return !isUnsent(m); }));
    if (a === 'del') { var ok = await confirmSheet('Delete ' + plural(msgs.length, 'message') + ' for you?', 'They are removed from your view only. Other people keep their copy.', 'Delete for me'); if (!ok) return; for (var i = 0; i < msgs.length; i++) await doDeleteForMe(msgs[i]); S.sel = null; setSelUI(); renderThread(); }
  }

  /* ----- long-press context menu ----- */
  function closeCtx() { if (R.ctx) { R.ctx.hidden = true; R.ctx.innerHTML = ''; R.ctx.onclick = null; } }
  function openCtx(id, el) {
    var m = rowById(id); if (!m || isSys(m) || m._pending) return;
    if (S.sel) { toggleSel(id); return; }
    haptic('tap');
    var me = meId(), mine = m.sender_id === me, un = isUnsent(m), ca = S.cap.actions !== false, items = [];
    if (!un && ca) items.push({ label: 'Reply', icon: IC.reply, run: function () { startReply(m); } });
    if (!un && msgText(m)) items.push({ label: 'Copy', icon: IC.copy, run: function () { copyText(msgText(m)); } });
    if (!un && ca) items.push({ label: 'Forward', icon: IC.fwd, run: function () { forwardSheet([m]); } });
    if (canEdit(m)) items.push({ label: 'Edit', icon: IC.edit, run: function () { startEdit(m); } });
    if (!un && ca && (!S.gid || isAdmin())) { var pinned = S.pins.some(function (p) { return p.id === m.id; }); items.push({ label: pinned ? 'Unpin' : 'Pin', icon: IC.pin, run: function () { doPin(m, !pinned); } }); }
    if (!un && ca) items.push({ label: 'Save', icon: IC.save, run: function () { doSave(m); } });
    items.push({ label: 'Select', icon: IC.select, run: function () { S.sel = new Set([m.id]); setSelUI(); renderThread(); } });
    if (ca) items.push({ label: 'Delete for me', icon: IC.trash, run: function () { confirmSheet('Delete for you?', 'It is removed from your view only. Other people keep their copy.', 'Delete for me').then(function (ok) { if (ok) doDeleteForMe(m); }); } });
    if (canUnsend(m)) items.push({ label: 'Unsend for everyone', icon: IC.trash, danger: true, run: function () { doUnsend(m); } });
    if (!mine && !un && ca) items.push({ label: 'Report', icon: IC.flag, danger: true, run: function () { reportSheet(m); } });
    var my = (S.react.get(m.id) || []).find(function (x) { return x.user_id === me; });
    var react = !un && ca ? '<div class="bm-ctx-react bm-glass" role="group" aria-label="React">' + EMOJIS.map(function (e) { return '<button type="button" class="' + (my && my.emoji === e ? 'on' : '') + '" data-e="' + e + '" aria-label="React ' + e + '">' + e + '</button>'; }).join('') + '</div>' : '';
    R.ctx.hidden = false;
    R.ctx.innerHTML = '<div class="bm-ctx-scrim"></div>' + react + '<div class="bm-ctx-msg' + (mine ? ' mine' : '') + '"></div><div class="bm-ctx-menu bm-glass" role="menu" aria-label="Message actions">' + items.map(function (it, i) { return '<button type="button" role="menuitem" class="bm-ctx-item' + (it.danger ? ' danger' : '') + '" data-i="' + i + '"><span>' + esc(it.label) + '</span>' + (it.icon || '') + '</button>'; }).join('') + '</div>';
    var rr = R.root.getBoundingClientRect(), bub = $('.bm-bub', el) || el, br = bub.getBoundingClientRect(), clone = $('.bm-ctx-msg', R.ctx), rx = $('.bm-ctx-react', R.ctx), mn = $('.bm-ctx-menu', R.ctx);
    var cl = bub.cloneNode(true); cl.style.margin = '0'; clone.appendChild(cl);
    var W = rr.width, H = rr.height, top = br.top - rr.top, left = br.left - rr.left;
    clone.style.width = br.width + 'px';
    var mh = mn.offsetHeight, rh = rx ? rx.offsetHeight : 0, ch = Math.min(br.height, H * 0.4), safeT = 70;
    clone.style.maxHeight = ch + 'px'; clone.style.overflow = 'hidden';
    var total = (rh ? rh + 8 : 0) + ch + 8 + mh;
    var y = top - (rh ? rh + 8 : 0); if (y + total > H - 12) y = H - 12 - total; if (y < safeT) y = safeT;
    var cy = y + (rh ? rh + 8 : 0);
    clone.style.top = cy + 'px'; clone.style.left = Math.max(8, Math.min(left, W - br.width - 8)) + 'px';
    var side = function (node) { var w = node.offsetWidth; var l = mine ? (left + br.width - w) : left; node.style.left = Math.max(8, Math.min(l, W - w - 8)) + 'px'; };
    mn.style.top = (cy + ch + 8) + 'px'; side(mn);
    if (rx) { rx.style.top = y + 'px'; side(rx); }
    R.ctx.onclick = function (e) {
      if (e.target.classList.contains('bm-ctx-scrim')) { closeCtx(); return; }
      var eb = e.target.closest('[data-e]'); if (eb) { closeCtx(); doReact(m, eb.dataset.e); return; }
      var b = e.target.closest('.bm-ctx-item'); if (!b) return; var it = items[+b.dataset.i]; closeCtx(); it && it.run && it.run();
    };
    var f = $('.bm-ctx-item', R.ctx); if (f) f.focus({ preventScroll: true });
  }

  /* ======================================================================
   * New message / new group
   * ====================================================================== */
  function newMessageSheet() {
    if (!meId()) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="New message"><div class="bm-grab"></div><h2>New message</h2>'
      + (S.cap.groups !== false ? '<button type="button" class="bm-act" id="bmNewGroup">' + IC.users + '<span>New group</span></button>' : '')
      + '<label class="bm-search bm-glass-in">' + IC.search + '<input type="search" id="bmNewQ" placeholder="Search people by name or @username" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Search people"></label><div class="bm-people" id="bmNewList" aria-live="polite"></div><button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
    var list = $('#bmNewList', R.sheet), q = $('#bmNewQ', R.sheet), seq = 0, timer = 0;
    var show = function (arr, empty) { list.innerHTML = arr.length ? peopleHTML(arr) : '<div class="bm-empty small"><p>' + esc(empty) + '</p></div>'; };
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
      if (e.target.closest('#bmNewGroup')) { newGroupSheet(); return; }
      var b = e.target.closest('[data-peer]'); if (b) { var id = b.dataset.peer; closeSheet(); openChat(id); }
    };
    setTimeout(function () { try { q.focus(); } catch (_) {} }, 120);
  }
  /* shared picker used by "new group" and "add members" */
  function pickerSheet(o) {
    var pick = new Set(), seq = 0, timer = 0, me = meId(), exclude = new Set(o.exclude || []);
    exclude.add(me);
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="' + esc(o.title) + '"><div class="bm-grab"></div><h2>' + esc(o.title) + '</h2>' + (o.head || '')
      + '<div class="bm-chips2" id="bmPickChips" aria-live="polite"></div><label class="bm-search bm-glass-in">' + IC.search + '<input type="search" id="bmPickQ" placeholder="Search people by name or @username" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Search people"></label><div class="bm-people" id="bmPickList"></div>'
      + '<button type="button" class="bm-act bm-primary-act" id="bmPickGo" disabled><span>' + esc(o.cta) + '</span></button><button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
    var list = $('#bmPickList', R.sheet), chips = $('#bmPickChips', R.sheet), go = $('#bmPickGo', R.sheet), cur = [];
    var upd = function () {
      chips.innerHTML = Array.from(pick).map(function (id) { return '<button type="button" class="bm-chip2" data-rm="' + esc(id) + '" aria-label="Remove ' + esc(nameOf(id)) + '">' + esc(nameOf(id).split(' ')[0]) + ' ' + IC.close + '</button>'; }).join('');
      go.disabled = !(o.ready ? o.ready(pick) : pick.size);
    };
    var draw = function (arr, empty) { cur = arr; list.innerHTML = arr.length ? peopleHTML(arr, pick) : '<div class="bm-empty small"><p>' + esc(empty) + '</p></div>'; };
    (async function () {
      var f = window.bmnFollowing; var ids = f && f.size ? Array.from(f).slice(0, 40) : [];
      await ensureProfiles(ids);
      draw(ids.filter(function (id) { return !exclude.has(id) && prof(id).id; }).map(function (id) { return prof(id); }), 'Search for people to add.');
    })();
    $('#bmPickQ', R.sheet).oninput = function (e) {
      clearTimeout(timer); var v = sanitizeQ(e.target.value); if (v.length < 2) return; var my = ++seq;
      timer = setTimeout(async function () { try { var r = (await searchPeople(v)).filter(function (p) { return !exclude.has(p.id); }); if (my === seq) draw(r, 'No one found.'); } catch (_) { if (my === seq) draw([], 'Search is unavailable right now.'); } }, 260);
    };
    R.sheet.oninput = function (e) { if (o.onInput && e.target.closest('[data-in]')) o.onInput(e, pick, upd); };
    R.sheet.onclick = async function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var rm = e.target.closest('[data-rm]'); if (rm) { pick.delete(rm.dataset.rm); upd(); draw(cur, 'Search for people to add.'); return; }
      var row = e.target.closest('.bm-person[data-peer]'); if (row) { var id = row.dataset.peer; pick.has(id) ? pick.delete(id) : pick.add(id); upd(); draw(cur, 'Search for people to add.'); return; }
      if (o.onClick && o.onClick(e, pick, upd)) return;
      if (e.target.closest('#bmPickGo') && !go.disabled) { go.disabled = true; var ok = await o.go(Array.from(pick), R.sheet); if (ok === false) upd(); }
    };
    upd(); setTimeout(function () { try { $('#bmPickQ', R.sheet).focus(); } catch (_) {} }, 150);
  }
  function newGroupSheet() {
    var photo = null;
    pickerSheet({ title: 'New group', cta: 'Create group',
      head: '<div class="bm-gform"><button type="button" class="bm-gphoto" id="bmGPhoto" aria-label="Choose group photo">' + IC.photo + '</button><input id="bmGName" data-in="name" class="bm-field" maxlength="80" placeholder="Group name" autocomplete="off" aria-label="Group name"></div>',
      ready: function (pick) { var n = $('#bmGName', R.sheet); return pick.size >= 1 && n && n.value.trim().length >= 1; },
      onInput: function (e, pick, upd) { upd(); },
      onClick: function (e) { if (e.target.closest('#bmGPhoto')) { R.gFile.onchange = function () { var f = R.gFile.files && R.gFile.files[0]; R.gFile.value = ''; if (!f || !/^image\//.test(f.type)) return; photo = f; var b = $('#bmGPhoto', R.sheet); if (b) { b.style.backgroundImage = 'url(' + URL.createObjectURL(f) + ')'; b.classList.add('has'); } }; R.gFile.click(); return true; } return false; },
      go: async function (ids) {
        var s = sb(), me = meId(), name = $('#bmGName', R.sheet).value.trim(), path = null;
        try {
          if (photo) { var blob = await imageToBlob(photo, 640, 0.8); path = me + '/groups/' + Date.now() + '-' + Math.random().toString(36).slice(2, 8) + '.jpg'; var up = await s.storage.from('community-media').upload(path, blob, { cacheControl: '2592000', upsert: false, contentType: 'image/jpeg' }); if (up.error) throw up.error; }
          var r = await s.rpc('bmn_create_group', { p_name: name, p_description: null, p_member_ids: ids, p_avatar: path ? IMGP + path : null });
          if (r.error) { if (path) { try { await s.storage.from('community-media').remove([path]); } catch (_) {} } throw r.error; }
          closeSheet(); await loadConversations({ silent: true }); openGroup(r.data);
        } catch (e) { toast(rpcMsg(e)); return false; }
      } });
  }

  /* ======================================================================
   * Group info and admin controls
   * ====================================================================== */
  var DISAPPEAR = [[0, 'Off'], [86400, '24 hours'], [604800, '7 days'], [7776000, '90 days']];
  async function groupInfoSheet() {
    var gid = S.gid, g = S.groups.get(gid); if (!g) return;
    var members = await fetchMembers(gid), admin = isAdmin(), owner = g.my_role === 'owner';
    var rank = { owner: 0, admin: 1, member: 2 };
    members = members.slice().sort(function (a, b) { return (rank[a.role] - rank[b.role]) || (a.user_id === meId() ? -1 : 0); });
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="Group info"><div class="bm-grab"></div>'
      + '<div class="bm-ginfo">' + groupAvatarHTML(g, 'bm-big') + '<h2>' + esc(g.name) + '</h2>' + (g.description ? '<p class="bm-p">' + esc(g.description) + '</p>' : '') + '<small>' + plural(g.member_count, 'member') + (g.disappearing_seconds ? ' · messages disappear after ' + esc((DISAPPEAR.find(function (d) { return d[0] === g.disappearing_seconds; }) || [0, Math.round(g.disappearing_seconds / 3600) + ' hours'])[1]) : '') + (g.only_admins_post ? ' · only admins can post' : '') + '</small></div>'
      + '<div class="bm-gscroll">'
      + '<button type="button" class="bm-act" data-g="mute">' + (isMuted('g:' + gid) ? IC.bell : IC.mute) + '<span>' + (isMuted('g:' + gid) ? 'Unmute' : 'Mute') + ' notifications</span></button>'
      + (admin ? '<button type="button" class="bm-act" data-g="edit">' + IC.edit + '<span>Edit group</span></button>' : '')
      + (admin || g.members_can_add ? '<button type="button" class="bm-act" data-g="add">' + IC.plus + '<span>Add members</span></button>' : '')
      + '<div class="bm-sec">Members</div>'
      + members.map(function (m) { return '<button type="button" class="bm-row bm-person" data-m="' + esc(m.user_id) + '">' + avatarHTML(m.user_id) + '<span class="bm-meta"><span class="bm-top"><strong>' + esc(m.user_id === meId() ? 'You' : nameOf(m.user_id)) + '</strong>' + (m.role !== 'member' ? '<em class="bm-role">' + (m.role === 'owner' ? 'Owner' : 'Admin') + '</em>' : '') + '</span><span class="bm-bot"><small>' + esc(handleOf(m.user_id) || 'BMN member') + '</small></span></span></button>'; }).join('')
      + '<button type="button" class="bm-act danger" data-g="leave">' + IC.leave + '<span>Leave group</span></button></div>'
      + '<button type="button" class="bm-act cancel" data-cancel="1"><span>Done</span></button></div>';
    R.sheet.onclick = function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var a = e.target.closest('[data-g]'); if (a) {
        var k = a.dataset.g;
        if (k === 'mute') { closeSheet(); rowAction('g:' + gid, 'mute'); }
        else if (k === 'edit') editGroupSheet(); else if (k === 'add') addMembersSheet(); else if (k === 'leave') { closeSheet(); leaveGroup(gid); }
        return;
      }
      var m = e.target.closest('[data-m]'); if (m) memberSheet(m.dataset.m);
    };
    hydrateAvatars(R.sheet);
  }
  function memberSheet(uid) {
    var gid = S.gid, g = S.groups.get(gid), me = meId(), mem = (S.members.get(gid) || []).find(function (m) { return m.user_id === uid; }); if (!g || !mem) return;
    var role = g.my_role, items = [], s = sb();
    var run = function (fn, okMsg) { return async function () { try { var r = await fn(); if (r.error) throw r.error; await fetchMembers(gid); await loadConversations({ silent: true }); await refreshThread(); toast(okMsg); } catch (e) { toast(rpcMsg(e)); } }; };
    if (uid !== me) items.push({ label: 'View profile', icon: IC.user, run: function () { close(true); try { window.LGTT && window.LGTT.openProfile(uid); } catch (_) {} } });
    if (uid !== me) items.push({ label: 'Message ' + nameOf(uid).split(' ')[0], icon: IC.compose, run: function () { closeSheet(); openChat(uid); } });
    if (role === 'owner' && uid !== me) {
      if (mem.role === 'member') items.push({ label: 'Make admin', icon: IC.users, run: run(function () { return s.rpc('bmn_set_group_role', { p_group: gid, p_user: uid, p_role: 'admin' }); }, 'Now an admin.') });
      if (mem.role === 'admin') items.push({ label: 'Remove as admin', icon: IC.users, run: run(function () { return s.rpc('bmn_set_group_role', { p_group: gid, p_user: uid, p_role: 'member' }); }, 'No longer an admin.') });
      items.push({ label: 'Make group owner', icon: IC.users, run: function () { confirmSheet('Transfer ownership?', nameOf(uid) + ' becomes the owner and you become an admin.', 'Transfer').then(function (ok) { if (ok) run(function () { return s.rpc('bmn_set_group_role', { p_group: gid, p_user: uid, p_role: 'owner' }); }, 'Ownership transferred.')(); }); } });
    }
    if (uid !== me && (role === 'owner' || (role === 'admin' && mem.role === 'member'))) items.push({ label: 'Remove from group', danger: true, icon: IC.trash, run: function () { confirmSheet('Remove ' + nameOf(uid) + '?', 'They will no longer see new messages in this group.', 'Remove').then(function (ok) { if (ok) run(function () { return s.rpc('bmn_remove_group_member', { p_group: gid, p_user: uid }); }, 'Member removed.')(); }); } });
    if (!items.length) return;
    sheet(uid === me ? 'You' : nameOf(uid), items);
  }
  function addMembersSheet() {
    var gid = S.gid, have = (S.members.get(gid) || []).map(function (m) { return m.user_id; });
    pickerSheet({ title: 'Add members', cta: 'Add to group', exclude: have, go: async function (ids) {
      try { var r = await sb().rpc('bmn_add_group_members', { p_group: gid, p_user_ids: ids }); if (r.error) throw r.error; closeSheet(); await fetchMembers(gid); await loadConversations({ silent: true }); await refreshThread(); toast((r.data || 0) < ids.length ? 'Added ' + (r.data || 0) + ' of ' + ids.length + '. Others can’t be added right now.' : 'Members added.'); }
      catch (e) { toast(rpcMsg(e)); return false; }
    } });
  }
  function editGroupSheet() {
    var gid = S.gid, g = S.groups.get(gid); if (!g) return;
    var st = { name: g.name, description: g.description || '', only: g.only_admins_post, add: g.members_can_add, dis: g.disappearing_seconds || 0, photo: null };
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="Edit group"><div class="bm-grab"></div><h2>Edit group</h2><div class="bm-gscroll">'
      + '<div class="bm-gform"><button type="button" class="bm-gphoto" id="bmGPhoto" aria-label="Change group photo">' + groupAvatarHTML(g, 'bm-big') + '</button><input id="bmGName" class="bm-field" maxlength="80" value="' + esc(g.name) + '" aria-label="Group name"></div>'
      + '<textarea id="bmGDesc" class="bm-field bm-area" maxlength="500" rows="3" placeholder="Description (optional)" aria-label="Group description">' + esc(g.description || '') + '</textarea>'
      + '<div class="bm-sec">Controls</div>'
      + '<div class="bm-setrow"><span>Only admins can send messages</span><button type="button" role="switch" class="bm-sw2" data-tog="only" aria-checked="' + String(st.only) + '"></button></div>'
      + '<div class="bm-setrow"><span>Members can add people</span><button type="button" role="switch" class="bm-sw2" data-tog="add" aria-checked="' + String(st.add) + '"></button></div>'
      + '<div class="bm-sec">Disappearing messages</div><div class="bm-seg" role="radiogroup" aria-label="Disappearing messages">' + DISAPPEAR.map(function (d) { return '<button type="button" role="radio" data-dis="' + d[0] + '" aria-checked="' + String(st.dis === d[0]) + '">' + d[1] + '</button>'; }).join('') + '</div>'
      + '<p class="bm-p">Applies to new messages in this group. Admins only.</p></div>'
      + '<button type="button" class="bm-act bm-primary-act" id="bmGSave"><span>Save</span></button><button type="button" class="bm-act cancel" data-cancel="1"><span>Cancel</span></button></div>';
    hydrateAvatars(R.sheet);
    R.sheet.onclick = async function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var t = e.target.closest('[data-tog]'); if (t) { var k = t.dataset.tog; st[k] = !st[k]; t.setAttribute('aria-checked', String(st[k])); return; }
      var d = e.target.closest('[data-dis]'); if (d) { st.dis = +d.dataset.dis; $$('[data-dis]', R.sheet).forEach(function (b) { b.setAttribute('aria-checked', String(b === d)); }); return; }
      if (e.target.closest('#bmGPhoto')) { R.gFile.onchange = function () { var f = R.gFile.files && R.gFile.files[0]; R.gFile.value = ''; if (!f || !/^image\//.test(f.type)) return; st.photo = f; var b = $('#bmGPhoto', R.sheet); if (b) { b.innerHTML = ''; b.style.backgroundImage = 'url(' + URL.createObjectURL(f) + ')'; b.classList.add('has'); } }; R.gFile.click(); return; }
      if (e.target.closest('#bmGSave')) {
        var name = $('#bmGName', R.sheet).value.trim(), desc = $('#bmGDesc', R.sheet).value.trim(), s = sb(), me = meId(), path = null;
        if (!name) { toast('A group needs a name.'); return; }
        try {
          if (st.photo) { var blob = await imageToBlob(st.photo, 640, 0.8); path = me + '/groups/' + Date.now() + '-' + Math.random().toString(36).slice(2, 8) + '.jpg'; var up = await s.storage.from('community-media').upload(path, blob, { cacheControl: '2592000', upsert: false, contentType: 'image/jpeg' }); if (up.error) throw up.error; }
          var args = { p_group: gid };
          if (name !== g.name) args.p_name = name; if (desc !== (g.description || '')) args.p_description = desc; if (path) args.p_avatar = IMGP + path;
          if (st.only !== g.only_admins_post) args.p_only_admins_post = st.only; if (st.add !== g.members_can_add) args.p_members_can_add = st.add; if (st.dis !== (g.disappearing_seconds || 0)) args.p_disappearing_seconds = st.dis;
          if (Object.keys(args).length > 1) { var r = await s.rpc('bmn_update_group', args); if (r.error) throw r.error; }
          closeSheet(); await loadConversations({ silent: true }); await refreshThread(); paintHeader(); toast('Group updated.');
        } catch (er) { toast(rpcMsg(er)); }
      }
    };
  }

  /* ======================================================================
   * Settings: appearance, privacy, media, blocked accounts
   * ====================================================================== */
  var ACCENT_SW = { bmn: ['#2563eb', '#5b4bd8'], ocean: ['#0369a1', '#1d4ed8'], forest: ['#047857', '#0f766e'], sunset: ['#c2410c', '#be123c'], rose: ['#be185d', '#9d174d'] };
  function settingsSheet() {
    if (!meId()) { if (window.requestCommunityAuth) window.requestCommunityAuth('inbox'); return; }
    var P1 = S.cap.set1 !== false, P2 = S.cap.set2 !== false, st = S.set;
    var seg = function (key, opts, val, off) { return '<div class="bm-seg' + (off ? ' off' : '') + '" role="radiogroup">' + opts.map(function (o) { return '<button type="button" role="radio" data-set="' + key + '" data-val="' + o[0] + '" aria-checked="' + String(val === o[0]) + '"' + (off ? ' disabled' : '') + '>' + o[1] + '</button>'; }).join('') + '</div>'; };
    var tog = function (key, label, val, off) { return '<div class="bm-setrow' + (off ? ' off' : '') + '"><span>' + label + '</span><button type="button" role="switch" class="bm-sw2" data-tog="' + key + '" aria-checked="' + String(!!val) + '"' + (off ? ' disabled' : '') + '></button></div>'; };
    var ad = st.auto_download || {};
    R.sheet.hidden = false;
    R.sheet.innerHTML = '<div class="bm-scrim"></div><div class="bm-sheetbox bm-glass bm-tall" role="dialog" aria-modal="true" aria-label="Messaging settings"><div class="bm-grab"></div><h2>Messaging settings</h2><div class="bm-gscroll">'
      + '<div class="bm-sec">Appearance</div>' + seg('theme', [['system', 'System'], ['dark', 'Dark'], ['light', 'Light']], st.theme)
      + '<div class="bm-swatches" role="radiogroup" aria-label="Accent colour">' + ACCENTS.map(function (a) { return '<button type="button" role="radio" class="bm-swatch" data-set="accent" data-val="' + a + '" aria-checked="' + String(st.accent === a) + '" aria-label="' + a + ' accent" style="background:linear-gradient(135deg,' + ACCENT_SW[a][0] + ',' + ACCENT_SW[a][1] + ')"></button>'; }).join('') + '</div>'
      + '<p class="bm-p">System follows your device. Saved on this device' + (P2 ? ' and your account.' : '.') + '</p>'
      + '<div class="bm-sec">Privacy</div>'
      + tog('read_receipts', 'Read receipts', st.read_receipts, !P1) + tog('show_activity_status', 'Show when I’m active', st.show_activity_status, !P1) + tog('typing_indicator', 'Typing indicators', st.typing_indicator, !P2)
      + '<div class="bm-lbl">Last seen</div>' + seg('last_seen', [['everyone', 'Everyone'], ['followers', 'Followers'], ['nobody', 'Nobody']], st.last_seen, !P2)
      + '<div class="bm-lbl">Who can message me</div>' + seg('who_can_message', [['everyone', 'Everyone'], ['followers', 'People I follow'], ['nobody', 'Nobody']], ['everyone', 'followers', 'nobody'].indexOf(st.who_can_message) >= 0 ? st.who_can_message : (st.who_can_message === 'following' ? 'followers' : 'everyone'), !P1)
      + (S.cap.groups !== false ? '<div class="bm-lbl">Who can add me to groups</div>' + seg('group_invites', [['everyone', 'Everyone'], ['followers', 'Followers'], ['nobody', 'Nobody']], st.group_invites, !P2) : '')
      + (!P1 || !P2 ? '<p class="bm-p">Some privacy controls turn on after the BMN messaging update is installed.</p>' : '<p class="bm-p">If you turn off read receipts or activity status, you won’t see theirs either.</p>')
      + '<div class="bm-sec">Media auto-download</div>'
      + '<div class="bm-lbl">Photos</div>' + seg('ad_photos', [['always', 'Always'], ['wifi', 'Wi-Fi only'], ['never', 'Never']], ad.photos || 'wifi')
      + (S.cap.actions !== false ? '<div class="bm-sec">Blocked accounts</div><div id="bmBlocked" class="bm-blocked"></div>' : '')
      + '</div><button type="button" class="bm-act cancel" data-cancel="1"><span>Done</span></button></div>';
    var drawBlocked = async function () {
      var box = $('#bmBlocked', R.sheet); if (!box) return;
      await ensureProfiles(Array.from(S.blocked));
      box.innerHTML = S.blocked.size ? Array.from(S.blocked).map(function (id) { return '<div class="bm-setrow">' + avatarHTML(id, 'bm-mini') + '<span>' + esc(nameOf(id)) + '</span><button type="button" class="bm-btn" data-unblock="' + esc(id) + '">Unblock</button></div>'; }).join('') : '<p class="bm-p">You haven’t blocked anyone.</p>';
    };
    fetchBlocked().then(drawBlocked);
    R.sheet.onclick = async function (e) {
      if (e.target.classList.contains('bm-scrim') || e.target.closest('[data-cancel]')) { closeSheet(); return; }
      var b = e.target.closest('[data-set]');
      if (b && !b.disabled) {
        var key = b.dataset.set, val = b.dataset.val, patch = {};
        if (key === 'ad_photos') patch.auto_download = Object.assign({}, S.set.auto_download, { photos: val }); else patch[key] = val;
        $$('[data-set="' + key + '"]', R.sheet).forEach(function (x) { x.setAttribute('aria-checked', String(x === b)); });
        var ok = await saveSettings(patch); if (!ok) toast('Saved on this device. It could not be saved to your account yet.'); return;
      }
      var t = e.target.closest('[data-tog]');
      if (t && !t.disabled) { var k = t.dataset.tog, v = t.getAttribute('aria-checked') !== 'true'; t.setAttribute('aria-checked', String(v)); var p = {}; p[k] = v; var ok2 = await saveSettings(p); if (!ok2) { t.setAttribute('aria-checked', String(!v)); S.set[k] = !v; toast('Could not save that setting. Try again.'); } return; }
      var u = e.target.closest('[data-unblock]'); if (u) { await setBlock(u.dataset.unblock, false); drawBlocked(); }
    };
  }

  /* ======================================================================
   * Wallpaper (per conversation, this device only; same storage keys as before)
   * ====================================================================== */
  var WP = [['Default', ''], ['Midnight', 'linear-gradient(160deg,#0b1020,#1a2347)'], ['Storm', 'linear-gradient(160deg,#1c2b4a,#3b5b8f)'], ['Violet', 'linear-gradient(160deg,#1b1038,#5b3a9e)'], ['Cyan', 'linear-gradient(160deg,#06222e,#0e7490)'], ['Pearl', 'linear-gradient(160deg,#e8edf7,#b9c4dc)'], ['Ember', 'linear-gradient(160deg,#2a0f1a,#8a3b4f)'], ['Forest', 'linear-gradient(160deg,#08201a,#1f6b53)'],
    ['Doodle', 'url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%27120%27 height=%27120%27%3E%3Cg fill=%27none%27 stroke=%27%23ffffff%27 stroke-opacity=%27.07%27 stroke-width=%271.6%27 stroke-linecap=%27round%27%3E%3Ccircle cx=%2724%27 cy=%2724%27 r=%278%27/%3E%3Cpath d=%27M70 18l10 10M80 18L70 28%27/%3E%3Cpath d=%27M20 80q8-12 16 0t16 0%27/%3E%3Cpath d=%27M84 76l8 14H76z%27/%3E%3Crect x=%2750%27 y=%2754%27 width=%2714%27 height=%2714%27 rx=%273%27/%3E%3C/g%3E%3C/svg%3E"),linear-gradient(160deg,#0b1020,#1a2347)']];
  var wpKey = function (id) { return 'bmn-chat-wp:' + id; };
  var wpGet = function (id) { try { return localStorage.getItem(wpKey(id)) || ''; } catch (_) { return ''; } };
  var wpSet = function (id, v) { try { v ? localStorage.setItem(wpKey(id), v) : localStorage.removeItem(wpKey(id)); return true; } catch (_) { return false; } };
  function applyWall() {
    if (!R.wall) return; var id = S.gid || S.peer, v = id ? wpGet(id) : '';
    R.wall.style.backgroundImage = v && v.indexOf('data:') === 0 ? 'url("' + v + '")' : (v || '');
    R.wall.style.backgroundSize = v && v.indexOf('url(') === 0 ? '120px 120px,cover' : 'cover';
    R.wall.style.backgroundRepeat = v && v.indexOf('url(') === 0 ? 'repeat,no-repeat' : 'no-repeat';
    R.wall.classList.toggle('on', !!v);
  }
  function wallpaperSheet() {
    var id = S.gid || S.peer; if (!id) return;
    var cur = wpGet(id);
    var grid = '<p class="bm-p">Saved on this device only. It is not synced to your account.</p><div class="bm-wp-grid">' + WP.map(function (p) { return '<button type="button" class="bm-wp" data-v="' + esc(p[1]) + '" title="' + esc(p[0]) + '" aria-label="' + esc(p[0]) + ' wallpaper" aria-pressed="' + String(p[1] === cur) + '" style="background:' + (p[1] ? esc(p[1]) : 'rgba(128,128,128,.25)') + '"></button>'; }).join('') + '</div>';
    sheet('Chat wallpaper', [{ label: 'Upload image', run: function () { R.wpFile.click(); } }, { label: 'Reset to default', run: function () { wpSet(id, ''); applyWall(); } }], grid);
    var base = R.sheet.onclick;
    R.sheet.onclick = function (e) {
      var b = e.target.closest('.bm-wp');
      if (!b) { base(e); return; }
      if (!wpSet(id, b.dataset.v)) note('Wallpaper could not be saved on this device.', true);
      applyWall(); $$('.bm-wp', R.sheet).forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
    };
  }
  function onWallFile() {
    var f = R.wpFile.files && R.wpFile.files[0]; R.wpFile.value = ''; var id = S.gid || S.peer; if (!f || !id) return;
    if (!/^image\//.test(f.type)) { note('Please choose an image file.', true); return; }
    var img = new Image(), url = URL.createObjectURL(f);
    img.onload = function () {
      var k = Math.min(1, 1100 / Math.max(img.width, img.height)), c = D.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k); c.getContext('2d').drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
      var out = ''; try { out = c.toDataURL('image/jpeg', 0.72); } catch (_) {}
      if (!out || !wpSet(id, out)) { note('That image is too large to save as a wallpaper on this device.', true); return; }
      if ((S.gid || S.peer) === id) applyWall(); note('');
    };
    img.onerror = function () { URL.revokeObjectURL(url); note('That image could not be read.', true); };
    img.src = url;
  }

  /* ======================================================================
   * Composer
   * ====================================================================== */
  function autosize() { R.input.style.height = 'auto'; R.input.style.height = Math.min(R.input.scrollHeight, 132) + 'px'; }
  function syncSend() { var has = !!R.input.value.trim(); R.form.classList.toggle('has-text', has); R.send.disabled = !has; R.quick.hidden = has || !!S.edit || !!S.reply; }
  function keyboard() {
    if (!window.visualViewport) return;
    var vv = window.visualViewport;
    var upd = function () {
      var kb = Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop));
      D.documentElement.style.setProperty('--bmn-kb', kb > 80 ? kb + 'px' : '0px');
      if (R.root) R.root.classList.toggle('kb', kb > 80);
      if (kb > 80 && S.open && (S.peer || S.gid) && R.msgs) R.msgs.scrollTop = R.msgs.scrollHeight;
    };
    vv.addEventListener('resize', upd); vv.addEventListener('scroll', upd);
  }

  /* ======================================================================
   * Gestures (touch / pen): swipe a message right to reply, long-press for the menu,
   * swipe a conversation row, drag from the left edge to go back (the chat follows the finger)
   * ====================================================================== */
  function wireGestures() {
    var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    /* ---- messages ---- */
    var g = null, lpT = 0;
    var clearLP = function () { clearTimeout(lpT); };
    R.msgs.addEventListener('pointerdown', function (e) {
      if (e.pointerType === 'mouse' || e.button > 0) return;
      var el = e.target.closest('.bm-msg[data-id]'); if (!el || e.target.closest('a,.bm-rx,.bm-quote,.bm-imgbtn[data-hold]')) { g = null; return; }
      g = { el: el, id: el.dataset.id, x: e.clientX, y: e.clientY, dx: 0, mode: '', done: false };
      clearLP(); if (!S.sel) lpT = setTimeout(function () { if (g && g.mode === '') { g.mode = 'lp'; S.suppress = true; openCtx(g.id, g.el); } }, 460);
    }, { passive: true });
    R.msgs.addEventListener('pointermove', function (e) {
      if (!g || g.done) return;
      var dx = e.clientX - g.x, dy = e.clientY - g.y;
      if (g.mode === '') {
        if (Math.abs(dy) > 9 && Math.abs(dy) > Math.abs(dx)) { g.done = true; clearLP(); return; }
        if (dx > 12 && dx > Math.abs(dy) * 1.4 && !S.sel && S.cap.actions !== false) { g.mode = 'swipe'; clearLP(); try { R.msgs.setPointerCapture(e.pointerId); } catch (_) {} }
        else if (Math.abs(dx) > 12) { g.done = true; clearLP(); return; }
      }
      if (g.mode === 'swipe') {
        g.dx = Math.max(0, Math.min(dx, 96)); var bub = $('.bm-col', g.el); if (bub) bub.style.transform = 'translateX(' + (g.dx * 0.8) + 'px)';
        g.el.style.setProperty('--bm-sw', Math.min(1, g.dx / 56)); g.el.classList.add('swiping');
        if (g.dx >= 56 && !g.hit) { g.hit = true; haptic('tap'); } else if (g.dx < 56) g.hit = false;
      }
    }, { passive: true });
    var endMsg = function () {
      clearLP(); if (!g) return;
      if (g.mode === 'swipe') {
        var bub = $('.bm-col', g.el); if (bub) { bub.style.transition = reduce ? '' : 'transform .22s cubic-bezier(.32,.72,0,1)'; bub.style.transform = ''; setTimeout(function () { bub.style.transition = ''; }, 260); }
        g.el.classList.remove('swiping'); S.suppress = true; setTimeout(function () { S.suppress = false; }, 350);
        if (g.dx >= 56) { var m = rowById(g.id); if (m && !isUnsent(m) && !m._pending) startReply(m); }
      }
      g = null;
    };
    R.msgs.addEventListener('pointerup', endMsg); R.msgs.addEventListener('pointercancel', endMsg);
    R.msgs.addEventListener('contextmenu', function (e) { var el = e.target.closest('.bm-msg[data-id]'); if (!el) return; e.preventDefault(); openCtx(el.dataset.id, el); });
    R.msgs.addEventListener('scroll', function () { clearLP(); });

    /* ---- conversation rows ---- */
    var sw = null, openSw = null, lp2 = 0;
    var swW = function (el) { var r = $('.bm-sw-r', el); return r ? r.offsetWidth : 0; };
    var setX = function (el, x, anim) { var row = $('.bm-row', el); if (!row) return; row.style.transition = anim && !reduce ? 'transform .26s cubic-bezier(.32,.72,0,1)' : 'none'; row.style.transform = x ? 'translateX(' + x + 'px)' : ''; el.classList.toggle('open-r', x < 0); el.classList.toggle('open-l', x > 0); };
    var closeSw = function () { if (openSw) { setX(openSw, 0, true); openSw = null; } };
    R.closeSw = closeSw;
    R.rows.addEventListener('pointerdown', function (e) {
      if (e.pointerType === 'mouse' || e.button > 0) return;
      var el = e.target.closest('.bm-sw'); if (!el) return;
      if (openSw && openSw !== el && !e.target.closest('.bm-swb')) closeSw();
      if (e.target.closest('.bm-swb')) return;
      sw = { el: el, x: e.clientX, y: e.clientY, base: el === openSw ? -swW(el) : 0, mode: '', pos: 0 };
      clearTimeout(lp2); lp2 = setTimeout(function () { if (sw && sw.mode === '') { sw.mode = 'lp'; S.suppress = true; haptic('tap'); rowMenu(el.dataset.key); } }, 520);
    }, { passive: true });
    R.rows.addEventListener('pointermove', function (e) {
      if (!sw) return; var dx = e.clientX - sw.x, dy = e.clientY - sw.y;
      if (sw.mode === '') {
        if (Math.abs(dy) > 9 && Math.abs(dy) > Math.abs(dx)) { clearTimeout(lp2); sw = null; return; }
        if (Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.3) { sw.mode = 'drag'; clearTimeout(lp2); try { R.rows.setPointerCapture(e.pointerId); } catch (_) {} S.suppress = true; }
      }
      if (sw.mode === 'drag') { var W = swW(sw.el); sw.pos = Math.max(-W - 28, Math.min(88, sw.base + dx)); setX(sw.el, sw.pos, false); }
    }, { passive: true });
    var endRow = function () {
      clearTimeout(lp2); if (!sw) return;
      if (sw.mode === 'drag') {
        var W = swW(sw.el), key = sw.el.dataset.key, el = sw.el;
        if (sw.pos > 64) { setX(el, 0, true); openSw = null; rowAction(key, 'pin'); }
        else if (sw.pos < -W * 0.45) { setX(el, -W, true); openSw = el; }
        else { setX(el, 0, true); if (openSw === el) openSw = null; }
        setTimeout(function () { S.suppress = false; }, 350);
      }
      sw = null;
    };
    R.rows.addEventListener('pointerup', endRow); R.rows.addEventListener('pointercancel', endRow);
    R.rows.addEventListener('scroll', function () { clearTimeout(lp2); }, true);
    R.rows.addEventListener('contextmenu', function (e) { var el = e.target.closest('.bm-sw'); if (!el) return; e.preventDefault(); rowMenu(el.dataset.key); });

    /* ---- edge swipe back (iPhone style) ---- */
    var eg = null;
    R.chat.addEventListener('pointerdown', function (e) {
      if (e.pointerType === 'mouse' || R.root.dataset.view !== 'chat') return;
      var rr = R.root.getBoundingClientRect(); if (e.clientX - rr.left > 24 || S.sel) return;
      eg = { x: e.clientX, y: e.clientY, t: Date.now(), w: rr.width, dx: 0, mode: '' };
    }, { passive: true });
    R.chat.addEventListener('pointermove', function (e) {
      if (!eg) return; var dx = e.clientX - eg.x, dy = e.clientY - eg.y;
      if (eg.mode === '') { if (Math.abs(dy) > 12 && Math.abs(dy) > dx) { eg = null; return; } if (dx > 8 && dx > Math.abs(dy)) { eg.mode = 'drag'; try { R.chat.setPointerCapture(e.pointerId); } catch (_) {} R.root.classList.add('dragging'); } }
      if (eg.mode === 'drag') {
        eg.dx = Math.max(0, dx); R.chat.style.transition = 'none'; R.list.style.transition = 'none';
        R.chat.style.transform = 'translateX(' + eg.dx + 'px)'; var p = Math.min(1, eg.dx / eg.w);
        R.list.style.transform = 'translateX(' + (-24 + 24 * p) + '%)'; R.list.style.opacity = String(0.4 + 0.6 * p);
      }
    }, { passive: true });
    var endEdge = function () {
      if (!eg) return;
      if (eg.mode === 'drag') {
        var v = eg.dx / Math.max(1, Date.now() - eg.t), go = eg.dx > eg.w * 0.33 || v > 0.55;
        R.root.classList.remove('dragging'); R.chat.style.transition = ''; R.list.style.transition = '';
        if (go) backToList(); else { R.chat.style.transform = ''; R.list.style.transform = ''; R.list.style.opacity = ''; }
      }
      eg = null;
    };
    R.chat.addEventListener('pointerup', endEdge); R.chat.addEventListener('pointercancel', endEdge);
  }

  /* ======================================================================
   * Build + wiring
   * ====================================================================== */
  function build() {
    if (S.built) return;
    var root = D.createElement('section');
    root.id = 'bmnMsg'; root.dataset.view = 'list'; root.setAttribute('aria-label', 'Messages');
    root.innerHTML =
      '<section class="bm-list" aria-label="Conversations">'
      + '<header class="bm-bar"><button type="button" class="bm-circle bm-glass" id="bmClose" aria-label="Close messages">' + IC.back + '</button>'
      + '<div class="bm-title bm-glass"><h1>Messages</h1><small id="bmSub" aria-live="polite"></small></div>'
      + '<button type="button" class="bm-circle bm-glass" id="bmSettings" aria-label="Messaging settings">' + IC.gear + '</button>'
      + '<button type="button" class="bm-circle bm-glass" id="bmSelf" aria-label="Saved messages (message yourself)">' + IC.self + '</button>'
      + '<button type="button" class="bm-circle bm-glass bm-accent" id="bmNew" aria-label="New message">' + IC.compose + '</button></header>'
      + '<div class="bm-scroll" id="bmListScroll"><div class="bm-filter"><label class="bm-search bm-glass">' + IC.search + '<input id="bmSearch" type="search" placeholder="Search messages or people" autocomplete="off" aria-label="Search messages or people"></label>'
      + '<div class="bm-chips bm-glass" id="bmChips" role="group" aria-label="Filter conversations"></div></div>'
      + '<div class="bm-rows" id="bmRows" role="list"></div><div id="bmPeople"></div></div></section>'
      + '<section class="bm-chat" id="bmChat" aria-label="Conversation" aria-hidden="true"><div class="bm-wall" id="bmWall" aria-hidden="true"></div>'
      + '<header class="bm-chead"><button type="button" class="bm-circle bm-glass bm-backc" id="bmBack" aria-label="Back to messages">' + IC.back + '<b id="bmBackN" hidden></b></button>'
      + '<button type="button" class="bm-pill bm-glass" id="bmWho" aria-haspopup="dialog" aria-label="Conversation options"><strong id="bmName"></strong><small id="bmSub2"></small></button>'
      + '<button type="button" class="bm-circle bm-glass bm-avc" id="bmAv" aria-label="Conversation options"></button></header>'
      + '<div class="bm-pinbar" id="bmPin" hidden></div>'
      + '<div class="bm-msgs" id="bmMsgs" role="log" aria-live="polite" aria-relevant="additions" tabindex="-1"></div>'
      + '<div class="bm-reqbar" id="bmReqBar" hidden></div>'
      + '<form class="bm-composer" id="bmForm" autocomplete="off">'
      + '<button type="button" class="bm-fab bm-glass" id="bmFab" hidden aria-label="Jump to latest messages">' + IC.down + '<b id="bmFabN" hidden></b></button>'
      + '<div class="bm-note" id="bmNote" role="status" aria-live="polite"></div>'
      + '<div id="bmReply" hidden></div><div class="bm-lock" id="bmLock" hidden></div>'
      + '<div class="bm-quick" id="bmQuick" role="group" aria-label="Quick reactions"><button type="button" data-q="❤️" aria-label="Send heart">❤️</button><button type="button" data-q="\u{1F602}" aria-label="Send laughing">\u{1F602}</button><button type="button" data-q="\u{1F44D}" aria-label="Send thumbs up">\u{1F44D}</button><button type="button" data-q="\u{1F44B}" aria-label="Send wave">\u{1F44B}</button></div>'
      + '<div class="bm-cbar"><button type="button" class="bm-circle bm-glass" id="bmAttach" aria-label="Send a photo">' + IC.photo + '</button>'
      + '<div class="bm-input bm-glass"><textarea id="bmInput" rows="1" maxlength="' + MAX_LEN + '" placeholder="Message" aria-label="Message" enterkeyhint="send"></textarea></div>'
      + '<button type="submit" class="bm-circle bm-send" id="bmSend" disabled aria-label="Send message">' + IC.send + '</button></div></form>'
      + '<div class="bm-selbar bm-glass" id="bmSelBar" hidden></div>'
      + '<input type="file" id="bmFile" accept="image/*" hidden><input type="file" id="bmWpFile" accept="image/*" hidden><input type="file" id="bmGFile" accept="image/*" hidden></section>'
      + '<div class="bm-sheet" id="bmSheet" hidden></div><div class="bm-ctx" id="bmCtx" hidden></div>';
    (D.getElementById('lgttStage') || D.body).appendChild(root);
    R = { root: root, list: $('.bm-list', root), rows: $('#bmRows', root), people: $('#bmPeople', root), search: $('#bmSearch', root), chips: $('#bmChips', root), sub: $('#bmSub', root), chat: $('#bmChat', root), wall: $('#bmWall', root),
      msgs: $('#bmMsgs', root), fab: $('#bmFab', root), fabN: $('#bmFabN', root), note: $('#bmNote', root), form: $('#bmForm', root), input: $('#bmInput', root), send: $('#bmSend', root),
      quick: $('#bmQuick', root), name: $('#bmName', root), sub2: $('#bmSub2', root), av: $('#bmAv', root), who: $('#bmWho', root), backN: $('#bmBackN', root), sheet: $('#bmSheet', root), ctx: $('#bmCtx', root),
      file: $('#bmFile', root), wpFile: $('#bmWpFile', root), gFile: $('#bmGFile', root), pinbar: $('#bmPin', root), reqbar: $('#bmReqBar', root), reply: $('#bmReply', root), lock: $('#bmLock', root), selbar: $('#bmSelBar', root) };
    S.built = true; applyTheme();

    $('#bmClose', root).onclick = function () { close(); };
    $('#bmSelf', root).onclick = function () { openChat(meId()); };
    $('#bmNew', root).onclick = newMessageSheet;
    $('#bmSettings', root).onclick = settingsSheet;
    $('#bmBack', root).onclick = backToList;
    R.who.onclick = chatMenu; R.av.onclick = chatMenu;
    R.search.oninput = onSearchInput;
    R.chips.addEventListener('click', function (e) { var b = e.target.closest('[data-chip]'); if (!b) return; S.filter = b.dataset.chip; S.arch = false; renderList(); });
    R.rows.addEventListener('click', function (e) {
      if (S.suppress) { S.suppress = false; return; }
      var sb2 = e.target.closest('[data-sw]'); if (sb2) { var k = sb2.closest('.bm-sw').dataset.key; R.closeSw && R.closeSw(); rowAction(k, sb2.dataset.sw); return; }
      var b = e.target.closest('[data-act]');
      if (b) { var a = b.dataset.act; if (a === 'signin') window.requestCommunityAuth && window.requestCommunityAuth('inbox'); else if (a === 'new') newMessageSheet(); else if (a === 'new-group') newGroupSheet(); else if (a === 'retry-list') loadConversations(); else if (a === 'req') { S.filter = 'requests'; S.arch = false; renderList(); } else if (a === 'req-back') { S.filter = 'all'; renderList(); } else if (a === 'arch') { S.arch = true; renderList(); } else if (a === 'arch-back') { S.arch = false; renderList(); } return; }
      if (R.closeSw) R.closeSw();
      var r = e.target.closest('.bm-row[data-gid]'); if (r) { openGroup(r.dataset.gid); return; }
      r = e.target.closest('.bm-row[data-peer]'); if (r) openChat(r.dataset.peer);
    });
    R.people.addEventListener('click', function (e) { var r = e.target.closest('.bm-row[data-peer]'); if (r) openChat(r.dataset.peer); });
    R.msgs.addEventListener('click', function (e) {
      if (S.suppress) { S.suppress = false; return; }
      var a = e.target.closest('[data-act]');
      if (a) { if (a.dataset.act === 'older') loadOlder(); else if (a.dataset.act === 'retry-thread') (S.gid ? openGroup(S.gid) : openChat(S.peer)); return; }
      var rx = e.target.closest('.bm-rx'); if (rx) { var mm = rowById(rx.dataset.id); if (mm) doReact(mm, rx.dataset.rx); return; }
      var q = e.target.closest('[data-jump]'); if (q) { jumpTo(q.dataset.jump); return; }
      var held = e.target.closest('.bm-imgbtn[data-hold]'); if (held) { loadHeldImage(held); return; }
      var msg = e.target.closest('.bm-msg[data-id]');
      if (S.sel && msg) { toggleSel(msg.dataset.id); return; }
      var ib = e.target.closest('.bm-imgbtn'); if (ib) { var img = $('img', ib); if (img && img.src) lightbox(img.src); return; }
      var sh = e.target.closest('[data-share]'); if (sh) { close(true); return; }
      var f = e.target.closest('.bm-msg.failed'); if (f) retry(f.dataset.id);
    });
    R.msgs.addEventListener('dblclick', function (e) { var el = e.target.closest('.bm-msg[data-id]'); if (!el || S.sel || e.target.closest('a,button')) return; var m = rowById(el.dataset.id); if (m && !isUnsent(m) && !isSys(m) && S.cap.actions !== false) doReact(m, EMOJIS[0]); });
    R.msgs.addEventListener('keydown', function (e) { if ((e.key === 'Enter' || e.key === ' ') && e.target.classList && e.target.classList.contains('failed')) { e.preventDefault(); retry(e.target.dataset.id); } });
    R.pinbar.addEventListener('click', function (e) { var b = e.target.closest('[data-jump]'); if (b) jumpTo(b.dataset.jump); });
    R.reqbar.addEventListener('click', function (e) {
      var b = e.target.closest('[data-req]'); if (!b || !S.peer) return; var peer = S.peer;
      if (b.dataset.req === 'accept') respondRequest(peer, true);
      else if (b.dataset.req === 'decline') respondRequest(peer, false);
      else if (b.dataset.req === 'block') confirmSheet('Block ' + nameOf(peer) + '?', 'They won’t be able to message you again.', 'Block').then(async function (ok) { if (!ok) return; await setBlock(peer, true); await respondRequest(peer, false); });
    });
    R.reply.addEventListener('click', function (e) { if (e.target.closest('[data-act="cancel-reply"]')) { var wasEdit = !!S.edit; S.reply = null; S.edit = null; if (wasEdit) { restoreDraft(); } paintComposerState(); syncSend(); } });
    R.selbar.addEventListener('click', function (e) { var b = e.target.closest('[data-sel]'); if (b && !b.disabled) selAction(b.dataset.sel); });
    var ticking = false;
    R.msgs.addEventListener('scroll', function () {
      if (!ticking) { ticking = true; requestAnimationFrame(function () { ticking = false; updateFab(); if (R.msgs.scrollTop < 90 && S.hasMore) loadOlder(); }); }
    }, { passive: true });
    R.fab.onclick = function () { S.newBelow = 0; R.msgs.scrollTo({ top: R.msgs.scrollHeight, behavior: 'smooth' }); };
    R.input.addEventListener('input', function () { autosize(); syncSend(); onDraftInput(); if (R.input.value.trim()) sendTyping(); });
    R.input.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && window.matchMedia && matchMedia('(pointer:fine)').matches) { e.preventDefault(); submit(); } });
    R.input.addEventListener('focus', function () { setTimeout(function () { R.msgs.scrollTop = R.msgs.scrollHeight; }, 320); });
    R.form.onsubmit = function (e) { e.preventDefault(); submit(); };
    R.quick.addEventListener('click', function (e) { var b = e.target.closest('[data-q]'); if (!b || !(S.peer || S.gid) || !meId() || R.form.classList.contains('locked')) return; queue(b.dataset.q); });
    $('#bmAttach', root).onclick = function () { R.file.click(); };
    R.file.onchange = function () { var f = R.file.files && R.file.files[0]; R.file.value = ''; sendImage(f); };
    R.wpFile.onchange = onWallFile;
    wireGestures(); keyboard();
  }

  /* ---------- open / close (public) ---------- */
  function currentView() { var v = (D.getElementById('lgttStage') || {}).dataset; v = v && v.view || 'feed'; return v === 'discover' || v === 'profile' ? v : 'feed'; }
  function open(keepChat) {
    build();
    var stage = D.getElementById('lgttStage');
    if (stage && R.root.parentNode !== stage) stage.appendChild(R.root);
    R.root.classList.add('open'); S.open = true; applyTheme();
    if (stage) stage.classList.add('bmn-inbox-open');
    D.body.classList.add('bmn-real-inbox-open');
    try { window.LGTT && window.LGTT.resume && window.LGTT.resume(); } catch (_) {}
    if (!keepChat) { S.peer = null; S.gid = null; R.root.dataset.view = 'list'; R.chat.setAttribute('aria-hidden', 'true'); if (stage) stage.classList.remove('bmn-chat-open'); R.search.value = ''; S.query = ''; S.filter = 'all'; S.arch = false; R.people.innerHTML = ''; closeSheet(); closeCtx(); }
    renderList(); loadConversations(); setupRT();
  }
  function close(quiet) {
    var q = quiet === true;
    if (!R.root) return;
    saveDraftNow(); teardownTyping();
    R.root.classList.remove('open'); S.open = false; S.peer = null; S.gid = null; S.rows = []; S.sel = null; S.reply = null; S.edit = null;
    var stage = D.getElementById('lgttStage');
    if (stage) { stage.classList.remove('bmn-inbox-open'); stage.classList.remove('bmn-chat-open'); }
    D.body.classList.remove('bmn-real-inbox-open');
    R.root.dataset.view = 'list'; R.chat.setAttribute('aria-hidden', 'true'); R.chat.style.transform = ''; R.list.style.transform = ''; R.list.style.opacity = ''; closeSheet(); closeCtx();
    try { window.LGTT && window.LGTT.resume && window.LGTT.resume(); } catch (_) {}
    if (!q) { try { window.bmnSetDock && window.bmnSetDock(currentView()); } catch (_) {} }
  }

  /* Escape: the page has a capture-phase Escape handler on document that would close the whole Community overlay.
     A capture listener on window runs first, so Escape steps back one level inside Messages (menu, sheet, photo, selection, chat, list). */
  window.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' || !S.open || !R.root) return;
    if (D.querySelector('#bmnSheetHost[data-open="1"]')) return;
    e.stopPropagation(); e.preventDefault();
    if (R.ctx && !R.ctx.hidden) { closeCtx(); return; }
    if (!R.sheet.hidden) { closeSheet(); return; }
    var lb = $('.bm-lightbox', R.root); if (lb) { lb.remove(); return; }
    if (S.sel) { S.sel = null; setSelUI(); renderThread(); return; }
    if (S.reply || S.edit) { S.reply = null; S.edit = null; paintComposerState(); return; }
    if (S.peer || S.gid) backToList(); else close();
  }, true);

  /* start: background unread tracking runs as soon as a member is signed in */
  setInterval(poll, POLL_MS);
  D.addEventListener('visibilitychange', function () { if (D.visibilityState === 'visible') { S.tick = 0; poll(); if (S.open && (S.peer || S.gid)) scheduleMarkRead(); } else saveDraftNow(); });
  window.addEventListener('online', function () { poll(); if (S.open && (S.peer || S.gid)) refreshThread(); });
  window.addEventListener('pagehide', saveDraftNow);
  setTimeout(poll, 1500);

  window.BMNMessaging = {
    open: open, close: close, openChat: openChat, openGroup: openGroup, openSettings: function () { open(); settingsSheet(); }, refresh: function () { return loadConversations(); }, unread: function () { return S.unreadTotal; },
    _state: S
  };
  window.BMNRealInbox = { open: function () { open(); }, close: close, openChat: openChat, openGroup: openGroup, refresh: function () { return loadConversations(); } };
})();
