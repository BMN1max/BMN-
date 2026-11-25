/* BMN Board: a text-first, Twitter/X-style discussion page INSIDE BMN Community.
 *
 * One account, one profile system. Board has no accounts or profiles of its own: authors are the existing BMN profiles,
 * every name / photo / @mention opens the normal Community profile (LGTT.openProfile), follows / blocks / mutes use the
 * existing `follows` and `user_blocks` tables, verification comes from `bmn_verified_users`, reports go to `content_reports`.
 * Board posts live in their own board_* tables and never appear in the video feeds.
 *
 * Data: Supabase tables board_posts, board_likes, board_reposts, board_bookmarks, board_notifications (read) and the
 * SECURITY DEFINER functions board_create_post / board_edit_post / board_delete_post / board_set_like / board_set_repost /
 * board_set_bookmark / board_record_view / board_report_post / board_mark_notifications_read, plus the read functions
 * board_feed / board_ancestors / board_tag_posts / board_search_posts / board_trending / board_suggested_people.
 * Nothing here is demo data: if the B1 migration has not been applied the page says so instead of inventing posts.
 *
 * Public API: window.BMNBoard = { open, close, openPost(id), openTag(tag), refresh }
 * Entry point: the existing "B" button in the Community header (index.html calls BMNBoard.open()).
 */
(function () {
  'use strict';
  if (window.BMNBoard) return;

  var D = document;
  var $ = function (s, r) { return (r || D).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || D).querySelectorAll(s)); };
  var esc = function (v) { return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var sb = function () { return window.bmnSupabase || null; };
  var sess = function () { return (window.bmnSession && window.bmnSession.user) || null; };
  var meId = function () { var u = sess(); return u ? u.id : null; };
  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  var MAX = 500, PAGE = 20, EDIT_MS = 24 * 3600 * 1000, MAX_MEDIA = 4;
  var COLS = 'id,author_id,body,parent_id,root_id,quote_id,media,status,like_count,repost_count,reply_count,quote_count,view_count,created_at,edited_at,deleted_at';
  var REASONS = [['harassment', 'Harassment or bullying'], ['spam', 'Spam'], ['scam', 'Scam or fraud'], ['hate', 'Hate speech'], ['violence', 'Violence or threats'], ['sexual_content', 'Sexual content'], ['nudity', 'Nudity'], ['copyright', 'Copyright'], ['other', 'Something else']];
  var NOTE_TEXT = { like: 'liked your post', repost: 'reposted your post', quote: 'quoted your post', reply: 'replied to your post', mention: 'mentioned you in a post' };
  var NOTE_ICON = { like: 'heart', repost: 'repost', quote: 'quote', reply: 'reply', mention: 'at' };

  var IC = {
    back: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    home: '<svg viewBox="0 0 24 24"><path d="M4 11l8-7 8 7v8a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    compass: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M15.5 8.5l-2 5-5 2 2-5z" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/></svg>',
    search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M16 16l4.5 4.5" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>',
    bell: '<svg viewBox="0 0 24 24"><path d="M6 17V11a6 6 0 0 1 12 0v6l1.5 2h-15z M10 21h4" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round" stroke-linecap="round"/></svg>',
    mark: '<svg viewBox="0 0 24 24"><path d="M6 4h8a4 4 0 0 1 2.4 7.2A4.2 4.2 0 0 1 14.5 20H6z M10 8v3h3.6a1.5 1.5 0 0 0 0-3z M10 14v3h4a1.5 1.5 0 0 0 0-3z" fill="currentColor" fill-rule="evenodd"/></svg>',
    bookmark: '<svg viewBox="0 0 24 24"><path d="M7 4h10a1 1 0 0 1 1 1v15l-6-4-6 4V5a1 1 0 0 1 1-1z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    bookmarkOn: '<svg viewBox="0 0 24 24"><path d="M7 4h10a1 1 0 0 1 1 1v15l-6-4-6 4V5a1 1 0 0 1 1-1z" fill="currentColor" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    reply: '<svg viewBox="0 0 24 24"><path d="M20 12a8 7 0 0 1-11.6 6.6L4 20l1.4-3.9A7 7 0 0 1 4 12a8 7 0 0 1 16 0z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    repost: '<svg viewBox="0 0 24 24"><path d="M4 11V9a3 3 0 0 1 3-3h11l-3-3 M20 13v2a3 3 0 0 1-3 3H6l3 3" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    heart: '<svg viewBox="0 0 24 24"><path d="M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.4 4.3 4.3 0 0 1 19.5 10C19.5 15.4 12 20 12 20z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    heartOn: '<svg viewBox="0 0 24 24"><path d="M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.4 4.3 4.3 0 0 1 19.5 10C19.5 15.4 12 20 12 20z" fill="currentColor" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    share: '<svg viewBox="0 0 24 24"><path d="M12 15V4 M8 8l4-4 4 4 M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    more: '<svg viewBox="0 0 24 24"><circle cx="5" cy="12" r="1.8" fill="currentColor"/><circle cx="12" cy="12" r="1.8" fill="currentColor"/><circle cx="19" cy="12" r="1.8" fill="currentColor"/></svg>',
    quote: '<svg viewBox="0 0 24 24"><path d="M7 7h4v4c0 3-1.5 5-4 6 M15 7h4v4c0 3-1.5 5-4 6" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    at: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M15.5 12v1.5a2.5 2.5 0 0 0 5 0V12a8.5 8.5 0 1 0-3.5 6.9" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>',
    pen: '<svg viewBox="0 0 24 24"><path d="M4 20l1-4L16.5 4.5a2 2 0 0 1 2.8 0l.2.2a2 2 0 0 1 0 2.8L8 19z M14 7l3 3" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/></svg>',
    photo: '<svg viewBox="0 0 24 24"><rect x="3.5" y="5" width="17" height="14" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.9"/><circle cx="9" cy="10.5" r="1.6" fill="currentColor"/><path d="M4 17l5-4.5 4 3.5 3-2.5 4 3.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/></svg>',
    video: '<svg viewBox="0 0 24 24"><rect x="3.5" y="6" width="12.5" height="12" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M16 10.5l4.5-2.5v8L16 13.5" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    close: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
    views: '<svg viewBox="0 0 24 24"><path d="M5 20V10 M12 20V4 M19 20v-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    refresh: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.6-5.9 M20 4v5h-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
  };

  var S = {
    built: false, open: false, view: { type: 'home' }, stack: [], mode: 'for_you',
    posts: new Map(), missing: new Set(), mine: { likes: new Set(), reposts: new Set(), bookmarks: new Set() }, mineLoaded: new Set(),
    verified: new Map(), urls: new Map(), feeds: {}, unread: 0, viewed: new Set(), pendingView: new Map(), cap: null,
    fromBoard: false, busy: {}, notifs: null, comp: null, q: '', qTab: 'posts', scroll: {}, io: null, vio: null, pollT: 0, following: null
  };
  var R = {};

  /* ---------- helpers ---------- */
  function haptic(k) { try { window.LGTT && window.LGTT.haptic && window.LGTT.haptic(k); } catch (_) {} }
  function prof(id) { return (window.bmnProfiles && window.bmnProfiles[id]) || {}; }
  function nameOf(id) { var p = prof(id); return p.display_name || p.full_name || p.username || 'BMN member'; }
  function handleOf(id) { var p = prof(id); return p.username ? '@' + p.username : ''; }
  function avatarUrl(id) { var p = prof(id); return p.avatar_display_url || (/^https?:/i.test(p.avatar_url || '') ? p.avatar_url : '') || ''; }
  function hue(id) { var h = 0, s = String(id || ''); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360; return h; }
  function avatarHTML(id, cls) {
    var u = avatarUrl(id), ini = esc((nameOf(id).trim()[0] || 'B').toUpperCase());
    return '<button type="button" class="bd-av ' + (cls || '') + '" data-prof="' + esc(id) + '" style="--h:' + hue(id) + '" aria-label="Open ' + esc(nameOf(id)) + ' profile">' + (u ? '<img src="' + esc(u) + '" alt="" loading="lazy" decoding="async">' : ini) + '</button>';
  }
  function badgeHTML(id) {
    var lvl = S.verified.get(id); var owner = window.bmnFounderOwnerIds && window.bmnFounderOwnerIds.has && window.bmnFounderOwnerIds.has(id);
    if (!lvl && !owner) return '';
    return '<span class="bd-ver ' + (lvl === 'gold' || owner ? 'gold' : '') + '" title="Verified" aria-label="Verified">' + IC.check + '</span>';
  }
  function short(n) { n = Number(n) || 0; if (n < 1000) return String(n); if (n < 10000) return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'K'; if (n < 1e6) return Math.round(n / 1000) + 'K'; return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M'; }
  function ago(ts) {
    var t = new Date(ts).getTime(); if (!t) return ''; var s = Math.max(0, (Date.now() - t) / 1000);
    if (s < 45) return 'now'; if (s < 3600) return Math.round(s / 60) + 'm'; if (s < 86400) return Math.round(s / 3600) + 'h'; if (s < 7 * 86400) return Math.round(s / 86400) + 'd';
    var d = new Date(t), now = new Date(); return d.toLocaleDateString(undefined, d.getFullYear() === now.getFullYear() ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' });
  }
  function fullTime(ts) { var d = new Date(ts); return isNaN(d) ? '' : d.toLocaleString(undefined, { hour: 'numeric', minute: '2-digit', month: 'short', day: 'numeric', year: 'numeric' }); }
  function theme() { var m = 'system'; try { m = localStorage.getItem('bmn-theme-mode') || localStorage.getItem('bmn-theme') || 'system'; } catch (_) {} if (m === 'light' || m === 'dark') return m; return window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'; }
  function applyTheme() { if (R.root) R.root.dataset.bdTheme = theme(); }
  function note(t, bad) {
    if (!R.toast) return; R.toast.textContent = t || ''; R.toast.classList.toggle('bad', !!bad); R.toast.classList.toggle('show', !!t);
    clearTimeout(note._t); if (t) note._t = setTimeout(function () { R.toast.classList.remove('show'); }, 3600);
  }
  function errText(e) {
    var m = (e && (e.message || e.error_description)) || 'Something went wrong.';
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'No connection. Check your network and try again.';
    if (/could not find the function|schema cache|relation .* does not exist|PGRST20[24]/i.test(m)) return 'BMN Board is not switched on yet on this server.';
    return m;
  }
  function needAuth(what) {
    if (meId()) return false;
    note('Sign in to ' + what + '.', true);
    try { window.requestCommunityAuth && window.requestCommunityAuth('board'); } catch (_) {}
    return true;
  }
  async function rpc(name, args) { var s = sb(); if (!s) throw new Error('Still connecting. Try again in a moment.'); var r = await s.rpc(name, args || {}); if (r.error) throw r.error; return r.data; }

  /* ---------- text: safe linkify (hashtags, @mentions, links) ---------- */
  var URL_RE = /\bhttps?:\/\/[^\s<>"']+/gi;
  function linkSeg(raw) {
    var h = esc(raw);
    h = h.replace(/(^|[^A-Za-z0-9_&\/#])#([A-Za-z0-9_]{1,50})/g, function (m, pre, tag) { return /[A-Za-z]/.test(tag) ? pre + '<a class="bd-tag" href="#" data-tag="' + tag.toLowerCase() + '">#' + tag + '</a>' : m; });
    h = h.replace(/(^|[^A-Za-z0-9_@\/.])@([A-Za-z0-9_.]{2,30})/g, function (m, pre, u) { var tail = (u.match(/\.+$/) || [''])[0]; var name = u.slice(0, u.length - tail.length); return name.length < 2 ? m : pre + '<a class="bd-men" href="#" data-user="' + name + '">@' + name + '</a>' + tail; });
    return h;
  }
  function bodyHTML(text) {
    var out = '', last = 0, m; text = String(text || ''); URL_RE.lastIndex = 0;
    while ((m = URL_RE.exec(text))) {
      var url = m[0], trail = (url.match(/[.,!?;:)\]]+$/) || [''])[0]; url = url.slice(0, url.length - trail.length);
      out += linkSeg(text.slice(last, m.index));
      var shown = url.replace(/^https?:\/\//i, ''); if (shown.length > 38) shown = shown.slice(0, 36) + '…';
      out += '<a class="bd-link" href="' + esc(url) + '" target="_blank" rel="noopener noreferrer nofollow ugc">' + esc(shown) + '</a>' + esc(trail);
      last = m.index + m[0].length;
    }
    return out + linkSeg(text.slice(last));
  }

  /* ---------- data ---------- */
  async function ensureProfiles(ids) {
    var s = sb(); if (!s) return; if (!window.bmnProfiles) window.bmnProfiles = {};
    var miss = Array.from(new Set(ids.filter(function (id) { return id && UUID.test(String(id)) && !window.bmnProfiles[id]; })));
    if (!miss.length) return;
    try {
      var r = await s.from('profiles').select('*').in('id', miss);
      if (!r.error) await Promise.all((r.data || []).map(async function (p) {
        window.bmnProfiles[p.id] = Object.assign({}, window.bmnProfiles[p.id] || {}, p);
        var raw = p.avatar_url; if (raw && !/^https?:/i.test(raw) && !p.avatar_display_url && window.resolveStorageUrl) { try { window.bmnProfiles[p.id].avatar_display_url = await window.resolveStorageUrl(raw); } catch (_) {} }
      }));
    } catch (_) {}
  }
  async function loadVerified(ids) {
    var s = sb(); if (!s) return; var miss = Array.from(new Set(ids.filter(function (id) { return id && !S.verified.has(id) && !S.verified.has('x' + id); })));
    if (!miss.length) return;
    try {
      var r = await s.from('bmn_verified_users').select('user_id,badge_level').in('user_id', miss);
      var got = {}; (r.data || []).forEach(function (v) { got[v.user_id] = v.badge_level === 'gold' ? 'gold' : 'standard'; S.verified.set(v.user_id, got[v.user_id]); });
      if (!r.error) miss.forEach(function (id) { if (!got[id]) S.verified.set('x' + id, 1); });
    } catch (_) {}
  }
  async function loadMine(ids) {
    var s = sb(), me = meId(); if (!s || !me) return; ids = ids.filter(function (id) { return id && !S.mineLoaded.has(id); }); if (!ids.length) return;
    try {
      var rs = await Promise.all([
        s.from('board_likes').select('post_id').eq('user_id', me).in('post_id', ids),
        s.from('board_reposts').select('post_id').eq('user_id', me).in('post_id', ids),
        s.from('board_bookmarks').select('post_id').eq('user_id', me).in('post_id', ids)]);
      (rs[0].data || []).forEach(function (r) { S.mine.likes.add(r.post_id); });
      (rs[1].data || []).forEach(function (r) { S.mine.reposts.add(r.post_id); });
      (rs[2].data || []).forEach(function (r) { S.mine.bookmarks.add(r.post_id); });
      ids.forEach(function (id) { S.mineLoaded.add(id); });
    } catch (_) {}
  }
  function mediaUrl(v) { if (!v) return ''; if (/^https:\/\//i.test(v)) return v; return S.urls.get(v) || ''; }
  async function resolveMedia(posts) {
    var need = []; posts.forEach(function (p) { (Array.isArray(p.media) ? p.media : []).forEach(function (m) { [m.url, m.thumb].forEach(function (v) { if (v && !/^https:\/\//i.test(v) && !S.urls.has(v)) need.push(v); }); }); });
    need = Array.from(new Set(need)); if (!need.length) return;
    await Promise.all(need.map(async function (k) { try { var u = window.resolveStorageUrl ? await window.resolveStorageUrl(k) : ''; if (u) S.urls.set(k, u); } catch (_) {} }));
  }
  // Load posts (plus what they quote or reply to) and everything needed to draw them.
  async function hydrate(ids) {
    var s = sb(); ids = Array.from(new Set((ids || []).filter(Boolean))); if (!s || !ids.length) return [];
    var need = ids.filter(function (id) { return !S.posts.has(id); });
    if (need.length) {
      var r = await s.from('board_posts').select(COLS).in('id', need); if (r.error) throw r.error;
      (r.data || []).forEach(function (p) { S.posts.set(p.id, p); });
      need.forEach(function (id) { if (!S.posts.has(id)) S.missing.add(id); });
    }
    var extra = []; ids.forEach(function (id) { var p = S.posts.get(id); if (!p) return; [p.quote_id, p.parent_id].forEach(function (x) { if (x && !S.posts.has(x) && !S.missing.has(x)) extra.push(x); }); });
    extra = Array.from(new Set(extra));
    if (extra.length) {
      var r2 = await s.from('board_posts').select(COLS).in('id', extra);
      (r2.data || []).forEach(function (p) { S.posts.set(p.id, p); }); extra.forEach(function (id) { if (!S.posts.has(id)) S.missing.add(id); });
    }
    var all = ids.concat(extra).map(function (id) { return S.posts.get(id); }).filter(Boolean);
    var authors = all.map(function (p) { return p.author_id; });
    await Promise.all([ensureProfiles(authors), loadVerified(authors), loadMine(all.map(function (p) { return p.id; })), resolveMedia(all)]);
    return ids.map(function (id) { return S.posts.get(id); }).filter(Boolean);
  }
  async function loadFollowing() {
    var s = sb(), me = meId(); if (!s || !me) return new Set();
    if (window.bmnFollowing && window.bmnFollowing.has) return window.bmnFollowing;
    if (S.following) return S.following;
    try { var r = await s.from('follows').select('following_id').eq('follower_id', me); S.following = new Set((r.data || []).map(function (x) { return x.following_id; })); } catch (_) { S.following = new Set(); }
    return S.following;
  }
  function isFollowing(uid) { var f = (window.bmnFollowing && window.bmnFollowing.has) ? window.bmnFollowing : S.following; return !!(f && f.has(uid)); }

  /* ---------- post card ---------- */
  function actBtn(kind, icon, count, on, label, pid) {
    return '<button type="button" class="bd-act ' + kind + (on ? ' on' : '') + '" data-a="' + kind + '" data-pid="' + pid + '" aria-label="' + esc(label) + '"' + (on ? ' aria-pressed="true"' : (kind === 'like' || kind === 'bm' || kind === 'rp' ? ' aria-pressed="false"' : '')) + '>' + icon + (count != null ? '<span class="n">' + (count > 0 ? short(count) : '') + '</span>' : '') + '</button>';
  }
  function quoteHTML(id) {
    var q = S.posts.get(id);
    if (!q || q.deleted_at || q.status !== 'published') return '<div class="bd-quote gone">This post is unavailable</div>';
    var m = Array.isArray(q.media) ? q.media : [];
    return '<div class="bd-quote" data-open="' + q.id + '" role="link" tabindex="0"><div class="bd-qhead">' + avatarHTML(q.author_id, 'xs') + '<b>' + esc(nameOf(q.author_id)) + '</b>' + badgeHTML(q.author_id) + '<span class="bd-h">' + esc(handleOf(q.author_id)) + ' · ' + ago(q.created_at) + '</span></div>'
      + (q.body ? '<div class="bd-qbody">' + bodyHTML(q.body) + '</div>' : '') + (m.length ? '<div class="bd-qmedia">' + IC[m[0].type === 'video' ? 'video' : 'photo'] + ' ' + m.length + ' attachment' + (m.length > 1 ? 's' : '') + '</div>' : '') + '</div>';
  }
  function mediaHTML(p) {
    var m = Array.isArray(p.media) ? p.media : []; if (!m.length) return '';
    return '<div class="bd-media n' + m.length + '">' + m.map(function (it, i) {
      var url = mediaUrl(it.url); if (!url) return '<div class="bd-ph">Media unavailable</div>';
      if (it.type === 'video') { var th = it.thumb ? mediaUrl(it.thumb) : ''; return '<div class="bd-vid"><video src="' + esc(url) + '"' + (th ? ' poster="' + esc(th) + '"' : '') + ' controls playsinline preload="metadata"></video></div>'; }
      return '<button type="button" class="bd-img" data-zoom="' + i + '" data-pid="' + p.id + '" aria-label="Open photo ' + (i + 1) + ' of ' + m.length + '"><img src="' + esc(url) + '" alt="' + esc(it.alt || '') + '" loading="lazy" decoding="async"></button>';
    }).join('') + '</div>';
  }
  function postHTML(p, o) {
    o = o || {}; var me = meId();
    if (p.deleted_at) return '<article class="bd-post gone" data-pid="' + p.id + '"><div class="bd-tomb">This post was deleted.</div></article>';
    var parent = p.parent_id && S.posts.get(p.parent_id), ctx = '';
    if (o.by) ctx += '<div class="bd-ctx">' + IC.repost + '<span>' + (o.by === me ? 'You' : esc(nameOf(o.by))) + ' reposted</span></div>';
    if (o.showReply && p.parent_id) ctx += '<div class="bd-ctx">' + IC.reply + '<span>Replying to ' + (parent && !parent.deleted_at ? '<a class="bd-men" href="#" data-prof="' + esc(parent.author_id) + '">' + esc(handleOf(parent.author_id) || nameOf(parent.author_id)) + '</a>' : 'a post') + '</span></div>';
    var big = o.main ? ' main' : '';
    var meta = o.main
      ? '<div class="bd-time">' + fullTime(p.created_at) + (p.edited_at ? ' · edited' : '') + '</div>'
      : '';
    var stats = o.main ? '<div class="bd-stats">' + [['Replies', p.reply_count], ['Reposts', p.repost_count], ['Quotes', p.quote_count], ['Likes', p.like_count], ['Views', p.view_count]].filter(function (x) { return x[1] > 0 || x[0] === 'Replies'; }).map(function (x) { return '<span><b>' + short(x[1]) + '</b> ' + x[0] + '</span>'; }).join('') + '</div>' : '';
    return '<article class="bd-post' + big + (o.line ? ' line' : '') + (o.thread ? ' thread' : '') + '" data-pid="' + p.id + '" tabindex="0">' + ctx
      + '<div class="bd-row">' + '<div class="bd-left">' + avatarHTML(p.author_id) + '</div>'
      + '<div class="bd-body"><div class="bd-head"><button type="button" class="bd-name" data-prof="' + esc(p.author_id) + '">' + esc(nameOf(p.author_id)) + '</button>' + badgeHTML(p.author_id)
      + '<span class="bd-h">' + esc(handleOf(p.author_id)) + '</span>' + (o.main ? '' : '<span class="bd-dot">·</span><time class="bd-ago" datetime="' + esc(p.created_at) + '" title="' + esc(fullTime(p.created_at)) + '">' + ago(p.created_at) + '</time>' + (p.edited_at ? '<span class="bd-ed" title="Edited">edited</span>' : ''))
      + '<button type="button" class="bd-more" data-a="more" data-pid="' + p.id + '" aria-label="More options">' + IC.more + '</button></div>'
      + (o.main ? '' : '') + '<div class="bd-text">' + bodyHTML(p.body) + '</div>' + mediaHTML(p) + (p.quote_id ? quoteHTML(p.quote_id) : '') + '</div></div>' + meta + stats
      + '<div class="bd-acts">' + actBtn('reply', IC.reply, p.reply_count, false, 'Reply', p.id) + actBtn('rp', IC.repost, p.repost_count, S.mine.reposts.has(p.id), S.mine.reposts.has(p.id) ? 'Reposted. Options' : 'Repost options', p.id)
      + actBtn('like', S.mine.likes.has(p.id) ? IC.heartOn : IC.heart, p.like_count, S.mine.likes.has(p.id), S.mine.likes.has(p.id) ? 'Unlike' : 'Like', p.id)
      + (p.view_count > 0 && !o.main ? '<span class="bd-act views" title="Views" aria-label="' + p.view_count + ' views">' + IC.views + '<span class="n">' + short(p.view_count) + '</span></span>' : '')
      + actBtn('bm', S.mine.bookmarks.has(p.id) ? IC.bookmarkOn : IC.bookmark, null, S.mine.bookmarks.has(p.id), S.mine.bookmarks.has(p.id) ? 'Remove bookmark' : 'Bookmark', p.id)
      + actBtn('share', IC.share, null, false, 'Share', p.id) + '</div></article>';
  }
  function repaint(pid) { // refresh every copy of this post currently on screen
    var p = S.posts.get(pid); if (!p) return;
    $$('.bd-post[data-pid="' + pid + '"]', R.main).forEach(function (el) {
      var o = { main: el.classList.contains('main'), line: el.classList.contains('line'), thread: el.classList.contains('thread'), by: el.dataset.by || null, showReply: el.dataset.sr === '1' };
      var tmp = D.createElement('div'); tmp.innerHTML = postHTML(p, o); var n = tmp.firstChild; if (el.dataset.by) n.dataset.by = el.dataset.by; if (el.dataset.sr) n.dataset.sr = el.dataset.sr; el.replaceWith(n); observeViews(n);
    });
  }

  /* ---------- views (home, discover, search, notifications, bookmarks, thread, tag, mine) ---------- */
  function setBusy(on) { R.root.classList.toggle('busy', !!on); }
  function emptyHTML(icon, title, sub, btn) { return '<div class="bd-empty">' + (icon || '') + '<h3>' + esc(title) + '</h3>' + (sub ? '<p>' + esc(sub) + '</p>' : '') + (btn ? '<button type="button" class="bd-btn" data-go="' + btn[1] + '">' + esc(btn[0]) + '</button>' : '') + '</div>'; }
  function errorHTML(e) { return '<div class="bd-empty err"><h3>Couldn\'t load</h3><p>' + esc(errText(e)) + '</p><button type="button" class="bd-btn" data-go="retry">Try again</button></div>'; }
  function feedState(key) { return S.feeds[key] || (S.feeds[key] = { items: [], end: false, loading: false, offset: 0, last: null, err: null, loaded: false }); }

  function titleFor(v) {
    return ({ home: 'BMN Board', discover: 'Discover', search: 'Search', notifs: 'Notifications', bookmarks: 'Bookmarks', thread: 'Post', tag: '#' + (v.tag || ''), mine: 'My posts' })[v.type] || 'BMN Board';
  }
  function isRoot(v) { return ['home', 'discover', 'search', 'notifs', 'bookmarks'].indexOf(v.type) >= 0; }
  function renderChrome() {
    var v = S.view; R.title.textContent = titleFor(v);
    R.back.setAttribute('aria-label', S.stack.length ? 'Back' : 'Back to Community');
    R.tabs.hidden = v.type !== 'home';
    $$('[data-mode]', R.tabs).forEach(function (b) { var on = b.dataset.mode === S.mode; b.classList.toggle('on', on); b.setAttribute('aria-selected', on ? 'true' : 'false'); });
    var tab = isRoot(v) ? v.type : (S.stack[0] && S.stack[0].type) || 'home';
    $$('[data-nav]', R.nav).forEach(function (b) { var on = b.dataset.nav === tab; b.classList.toggle('on', on); if (on) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
    R.fab.hidden = !(v.type === 'home' || v.type === 'discover' || v.type === 'mine' || v.type === 'tag' || v.type === 'bookmarks');
    var m = meId(); R.me.innerHTML = m ? avatarHTML(m, 'sm').replace('<button', '<span').replace('</button>', '</span>') : '<span class="bd-av sm" style="--h:30">?</span>';
    R.me.setAttribute('aria-label', m ? 'Your menu' : 'Sign in');
    renderBadge();
  }
  function renderBadge() {
    var n = S.unread; var b = $('[data-nav="notifs"] .bd-nb', R.nav); if (b) { b.textContent = n > 9 ? '9+' : String(n); b.hidden = !n; }
    var btn = D.querySelector('#lgttStage [data-act="bmn-home"], [data-act="bmn-home"]'); if (btn) btn.classList.toggle('bd-has-unread', n > 0);
  }
  function setView(v, push) {
    if (push) { S.scroll[S.stack.length + ':' + S.view.type] = R.scroll.scrollTop; S.stack.push(S.view); }
    S.view = v; render(true);
  }
  function goRoot(type) {
    if (S.view.type === type && !S.stack.length) { if (R.scroll.scrollTop > 40) R.scroll.scrollTo({ top: 0, behavior: 'smooth' }); else refresh(); return; }
    S.stack = []; S.view = { type: type }; if (type === 'search') { /* keep last query */ } render(true);
  }
  function back() {
    if (S.stack.length) { var prev = S.stack.pop(); S.view = prev; render(false, S.scroll[S.stack.length + ':' + prev.type]); return; }
    close();
  }
  function render(top, restore) {
    renderChrome(); var v = S.view; R.main.innerHTML = ''; if (S.io) S.io.disconnect(); if (S.vio) S.vio.disconnect();
    var tok = ++S.tok || (S.tok = 1);
    if (v.type === 'home') renderFeedView('home:' + S.mode, function () { return { mode: S.mode }; });
    else if (v.type === 'tag') renderFeedView('tag:' + v.tag, function () { return { tag: v.tag }; });
    else if (v.type === 'mine') renderFeedView('mine', function () { return { mine: true }; });
    else if (v.type === 'discover') renderDiscover();
    else if (v.type === 'search') renderSearch();
    else if (v.type === 'notifs') renderNotifs();
    else if (v.type === 'bookmarks') renderBookmarks();
    else if (v.type === 'thread') renderThread(v.id);
    if (top) R.scroll.scrollTop = 0; else if (restore) setTimeout(function () { R.scroll.scrollTop = restore; }, 30);
  }

  /* --- feed lists --- */
  async function fetchPage(key, spec, st) {
    var s = sb(); var rows;
    if (spec.mode) {
      var args = { p_mode: spec.mode, p_limit: PAGE };
      if (spec.mode === 'for_you') args.p_offset = st.offset; else if (st.last) args.p_before = st.last;
      rows = await rpc('board_feed', args); rows = rows || [];
      return rows.map(function (r) { return { id: r.post_id, at: r.sort_at, by: r.reposted_by || null }; });
    }
    if (spec.tag) { var a = { p_tag: spec.tag, p_limit: PAGE }; if (st.last) a.p_before = st.last; rows = await rpc('board_tag_posts', a); return (rows || []).map(function (r) { return { id: r.post_id, at: r.sort_at }; }); }
    if (spec.search) { var b = { p_q: spec.search, p_limit: PAGE }; if (st.last) b.p_before = st.last; rows = await rpc('board_search_posts', b); return (rows || []).map(function (r) { return { id: r.post_id, at: r.sort_at }; }); }
    if (spec.mine) { var q = s.from('board_posts').select('id,created_at').eq('author_id', meId()).is('deleted_at', null).order('created_at', { ascending: false }).limit(PAGE); if (st.last) q = q.lt('created_at', st.last); var r = await q; if (r.error) throw r.error; return (r.data || []).map(function (x) { return { id: x.id, at: x.created_at }; }); }
    return [];
  }
  function drawItems(box, items, o) {
    var html = items.map(function (it) { var p = S.posts.get(it.id); if (!p) return ''; var h = postHTML(p, { by: it.by, showReply: !!(o && o.showReply) }); if (it.by || (o && o.showReply)) { h = h.replace('<article ', '<article ' + (it.by ? 'data-by="' + esc(it.by) + '" ' : '') + (o && o.showReply ? 'data-sr="1" ' : '')); } return h; }).join('');
    box.insertAdjacentHTML('beforeend', html); $$('.bd-post', box).forEach(observeViews);
  }
  async function loadMore(key, spec, box, more) {
    var st = feedState(key); if (st.loading || st.end) return; st.loading = true; st.err = null; more.innerHTML = '<span class="bd-spin"></span>';
    try {
      var page = await fetchPage(key, spec, st);
      var seen = new Set(st.items.map(function (i) { return i.id; })); page = page.filter(function (i) { return !seen.has(i.id); });
      var posts = await hydrate(page.map(function (i) { return i.id; })); var okIds = new Set(posts.map(function (p) { return p.id; }));
      var vis = page.filter(function (i) { return okIds.has(i.id); });
      if (spec.mode === 'for_you') st.offset += PAGE; if (page.length) st.last = page[page.length - 1].at;
      if (page.length < PAGE && !(spec.mode === 'for_you' && page.length >= PAGE)) st.end = true;
      st.items = st.items.concat(vis); st.loaded = true; drawItems(box, vis, { showReply: false });
      if (!st.items.length) box.innerHTML = emptyFor(key, spec);
      more.innerHTML = st.end ? (st.items.length > 5 ? '<span class="bd-end">You\'re all caught up</span>' : '') : '<button type="button" class="bd-btn ghost" data-go="more">Load more</button>';
      if (!st.end && S.io) S.io.observe(more);
    } catch (e) { st.err = e; more.innerHTML = ''; if (!st.items.length) box.innerHTML = errorHTML(e); else more.innerHTML = '<button type="button" class="bd-btn ghost" data-go="more">Couldn\'t load more. Try again</button>'; note(errText(e), true); }
    finally { st.loading = false; }
  }
  function emptyFor(key, spec) {
    if (spec.mode === 'following') return meId() ? emptyHTML(IC.home, 'Nothing here yet', 'Posts from people you follow will show up here. Follow people from Discover.', ['Find people to follow', 'discover']) : emptyHTML(IC.home, 'Sign in to see your Following timeline', 'Follow people and their posts appear here.', ['Sign in', 'signin']);
    if (spec.tag) return emptyHTML(IC.search, 'No posts with #' + spec.tag, 'Be the first to post about it.');
    if (spec.mine) return emptyHTML(IC.pen, 'You haven\'t posted yet', 'Share what\'s on your mind with the BMN community.', ['Write a post', 'compose']);
    if (spec.search) return emptyHTML(IC.search, 'No posts found', 'Try different words.');
    return emptyHTML(IC.mark, 'No posts yet', 'Be the first to start a conversation on BMN Board.', ['Write a post', 'compose']);
  }
  function renderFeedView(key, specFn, header) {
    var spec = specFn(); var st = feedState(key);
    if (spec.mode === 'following' && !meId()) { R.main.innerHTML = emptyFor(key, spec); return; }
    R.main.innerHTML = (header || '') + '<div class="bd-list" id="bdList"></div><div class="bd-more-row" id="bdMore"></div>';
    var box = $('#bdList', R.main), more = $('#bdMore', R.main);
    R.feedCtx = { key: key, spec: spec, box: box, more: more };
    S.io = 'IntersectionObserver' in window ? new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) { S.io.unobserve(e.target); loadMore(key, spec, box, more); } }); }, { root: R.scroll, rootMargin: '600px 0px' }) : null;
    if (st.loaded && st.items.length) { drawItems(box, st.items); more.innerHTML = st.end ? '<span class="bd-end">You\'re all caught up</span>' : '<button type="button" class="bd-btn ghost" data-go="more">Load more</button>'; if (!st.end && S.io) S.io.observe(more); return; }
    box.innerHTML = skeleton(); st.items = []; st.end = false; st.offset = 0; st.last = null; st.loaded = false;
    box.innerHTML = ''; loadMore(key, spec, box, more);
  }
  function skeleton() { var one = '<div class="bd-sk"><i class="a"></i><div><i class="l w40"></i><i class="l"></i><i class="l w80"></i></div></div>'; return one + one + one; }
  function refresh() {
    var v = S.view;
    if (v.type === 'home') { delete S.feeds['home:' + S.mode]; render(true); }
    else if (v.type === 'tag') { delete S.feeds['tag:' + v.tag]; render(true); }
    else if (v.type === 'mine') { delete S.feeds.mine; render(true); }
    else if (v.type === 'thread') { S.posts.delete(v.id); S.missing.delete(v.id); render(false, R.scroll.scrollTop); }
    else render(true);
    pollUnread();
  }

  /* --- discover --- */
  async function renderDiscover() {
    R.main.innerHTML = '<div class="bd-sec"><h2>Trending hashtags</h2><div id="bdTrend" class="bd-trend">' + skeleton().slice(0, 0) + '<span class="bd-spin"></span></div></div>'
      + '<div class="bd-sec"><h2>People to follow</h2><div id="bdPeople"><span class="bd-spin"></span></div></div>'
      + '<div class="bd-sec"><h2>Popular right now</h2><div id="bdPop"><span class="bd-spin"></span></div></div>';
    var tok = S.tok;
    try {
      var tr = await rpc('board_trending', { p_hours: 72, p_limit: 10 }); if (S.tok !== tok) return; var tb = $('#bdTrend', R.main); if (!tb) return;
      tb.innerHTML = (tr && tr.length) ? tr.map(function (t, i) { return '<button type="button" class="bd-trow" data-tag="' + esc(t.tag) + '"><span class="r">' + (i + 1) + '</span><span class="t"><b>#' + esc(t.tag) + '</b><small>' + short(t.posts) + ' post' + (Number(t.posts) === 1 ? '' : 's') + ' · ' + short(t.authors) + ' ' + (Number(t.authors) === 1 ? 'person' : 'people') + '</small></span></button>'; }).join('') : '<p class="bd-none">No hashtags are trending yet. Use #hashtags in your posts.</p>';
    } catch (e) { var t1 = $('#bdTrend', R.main); if (t1) t1.innerHTML = '<p class="bd-none">' + esc(errText(e)) + '</p>'; }
    try {
      var ppl = meId() ? await rpc('board_suggested_people', { p_limit: 6 }) : []; if (S.tok !== tok) return; var pb = $('#bdPeople', R.main); if (!pb) return;
      var ids = (ppl || []).map(function (x) { return x.user_id; }); await Promise.all([ensureProfiles(ids), loadVerified(ids), loadFollowing()]);
      pb.innerHTML = ids.length ? ids.map(function (id) { return personRow(id, true); }).join('') : '<p class="bd-none">' + (meId() ? 'No suggestions right now. People you don\'t follow yet will appear here once they post.' : 'Sign in to get suggestions.') + '</p>';
    } catch (e) { var p1 = $('#bdPeople', R.main); if (p1) p1.innerHTML = '<p class="bd-none">' + esc(errText(e)) + '</p>'; }
    try {
      var pop = await rpc('board_feed', { p_mode: 'for_you', p_limit: 8, p_offset: 0 }); if (S.tok !== tok) return; var ob = $('#bdPop', R.main); if (!ob) return;
      var items = (pop || []).map(function (r) { return { id: r.post_id, at: r.sort_at }; }); var ps = await hydrate(items.map(function (i) { return i.id; })); if (S.tok !== tok) return;
      ob.innerHTML = ''; if (!ps.length) ob.innerHTML = '<p class="bd-none">No posts yet.</p>'; else { ob.className = 'bd-list'; drawItems(ob, items.filter(function (i) { return S.posts.has(i.id); })); }
    } catch (e) { var o1 = $('#bdPop', R.main); if (o1) o1.innerHTML = '<p class="bd-none">' + esc(errText(e)) + '</p>'; }
  }
  function personRow(id, withFollow) {
    var me = meId();
    return '<div class="bd-person">' + avatarHTML(id) + '<button type="button" class="bd-pinfo" data-prof="' + esc(id) + '"><b>' + esc(nameOf(id)) + '</b>' + badgeHTML(id) + '<small>' + esc(handleOf(id)) + '</small></button>'
      + (withFollow && me && id !== me ? '<button type="button" class="bd-btn sm ' + (isFollowing(id) ? 'ghost' : '') + '" data-follow="' + esc(id) + '">' + (isFollowing(id) ? 'Following' : 'Follow') + '</button>' : '') + '</div>';
  }

  /* --- search --- */
  function renderSearch() {
    R.main.innerHTML = '<div class="bd-sbar"><span class="i">' + IC.search + '</span><input id="bdQ" type="search" inputmode="search" enterkeyhint="search" placeholder="Search posts, people, #hashtags" aria-label="Search BMN Board" autocomplete="off" autocapitalize="off" value="' + esc(S.q) + '"></div>'
      + '<div class="bd-seg" role="tablist"><button type="button" role="tab" data-qt="posts" class="' + (S.qTab === 'posts' ? 'on' : '') + '">Posts</button><button type="button" role="tab" data-qt="people" class="' + (S.qTab === 'people' ? 'on' : '') + '">People</button></div><div id="bdRes"></div>';
    var inp = $('#bdQ', R.main); inp.addEventListener('input', function () { S.q = inp.value; clearTimeout(S.qT); S.qT = setTimeout(runSearch, 350); });
    inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { clearTimeout(S.qT); runSearch(); inp.blur(); } });
    runSearch();
  }
  async function runSearch() {
    var box = $('#bdRes', R.main); if (!box) return; var q = (S.q || '').trim(); var tok = ++S.qTok || (S.qTok = 1);
    if (q.length < 2) { box.innerHTML = emptyHTML(IC.search, 'Search BMN Board', 'Find posts, people and #hashtags.'); return; }
    if (q[0] === '#' && q.length > 1 && S.qTab === 'posts') { box.innerHTML = '<button type="button" class="bd-trow" data-tag="' + esc(q.replace(/^#+/, '').toLowerCase()) + '"><span class="t"><b>Open ' + esc(q) + '</b><small>See everything posted with this hashtag</small></span></button>'; }
    else box.innerHTML = '<span class="bd-spin"></span>';
    try {
      if (S.qTab === 'people') {
        var clean = q.replace(/^@/, '').replace(/[%,()*\\]/g, ' ').trim(); var s = sb();
        var r = await s.from('profiles').select('id,username,display_name,avatar_url').or('username.ilike.%' + clean.replace(/_/g, '\\_') + '%,display_name.ilike.%' + clean.replace(/_/g, '\\_') + '%').limit(20);
        if (S.qTok !== tok) return; if (r.error) throw r.error; var ids = (r.data || []).map(function (p) { return p.id; });
        (r.data || []).forEach(function (p) { window.bmnProfiles = window.bmnProfiles || {}; window.bmnProfiles[p.id] = Object.assign({}, window.bmnProfiles[p.id] || {}, p); });
        await Promise.all([ensureProfiles(ids), loadVerified(ids), loadFollowing()]); if (S.qTok !== tok) return;
        box.innerHTML = ids.length ? ids.map(function (id) { return personRow(id, true); }).join('') : emptyHTML(IC.search, 'No people found', 'Try a different name or username.');
      } else {
        var rows = await rpc('board_search_posts', { p_q: q.replace(/^#/, ''), p_limit: 30 }); if (S.qTok !== tok) return;
        var items = (rows || []).map(function (x) { return { id: x.post_id, at: x.sort_at }; }); var ps = await hydrate(items.map(function (i) { return i.id; })); if (S.qTok !== tok) return;
        var head = q[0] === '#' ? box.innerHTML : ''; box.innerHTML = head + '<div class="bd-list" id="bdSL"></div>';
        if (!ps.length && q[0] !== '#') box.innerHTML = emptyHTML(IC.search, 'No posts found', 'Try different words.'); else drawItems($('#bdSL', box), items.filter(function (i) { return S.posts.has(i.id); }));
      }
    } catch (e) { if (S.qTok === tok) box.innerHTML = errorHTML(e); }
  }

  /* --- notifications --- */
  async function renderNotifs() {
    if (!meId()) { R.main.innerHTML = emptyHTML(IC.bell, 'Sign in to see notifications', 'Likes, reposts, replies and mentions show up here.', ['Sign in', 'signin']); return; }
    R.main.innerHTML = '<div id="bdNL"><span class="bd-spin"></span></div>'; var tok = S.tok;
    try {
      var s = sb(); var r = await s.from('board_notifications').select('id,actor_id,type,post_id,created_at,read_at').order('created_at', { ascending: false }).limit(40); if (r.error) throw r.error;
      var rows = r.data || []; var pids = rows.map(function (n) { return n.post_id; }).filter(Boolean);
      await hydrate(pids); await Promise.all([ensureProfiles(rows.map(function (n) { return n.actor_id; })), loadVerified(rows.map(function (n) { return n.actor_id; }))]); if (S.tok !== tok) return;
      var box = $('#bdNL', R.main); if (!box) return;
      box.innerHTML = rows.length ? rows.map(function (n) {
        var p = n.post_id && S.posts.get(n.post_id); var snip = p && !p.deleted_at ? (p.body || (Array.isArray(p.media) && p.media.length ? 'Attachment' : '')) : '';
        return '<div class="bd-note' + (n.read_at ? '' : ' unread') + '" data-open="' + esc(n.post_id || '') + '" role="link" tabindex="0"><span class="ic ' + n.type + '">' + IC[NOTE_ICON[n.type]] + '</span><div class="tx">' + avatarHTML(n.actor_id, 'sm') + '<p><b>' + esc(nameOf(n.actor_id)) + '</b> ' + esc(NOTE_TEXT[n.type] || 'interacted with you') + ' <time>' + ago(n.created_at) + '</time></p>' + (snip ? '<blockquote>' + esc(snip.slice(0, 140)) + '</blockquote>' : '') + '</div></div>';
      }).join('') : emptyHTML(IC.bell, 'No notifications yet', 'When people like, repost, reply to or mention you, you\'ll see it here.');
      if (rows.some(function (n) { return !n.read_at; })) { try { await rpc('board_mark_notifications_read', {}); S.unread = 0; renderBadge(); } catch (_) {} }
    } catch (e) { var b2 = $('#bdNL', R.main); if (b2) b2.innerHTML = errorHTML(e); }
  }
  async function pollUnread() {
    var s = sb(), me = meId(); if (!s || !me || S.cap === false) return;
    try { var r = await s.from('board_notifications').select('id').is('read_at', null).limit(30); if (r.error) { if (/does not exist|schema cache|PGRST20/i.test(r.error.message || '')) S.cap = false; return; } S.cap = true; S.unread = (r.data || []).length; renderBadge(); } catch (_) {}
  }

  /* --- bookmarks --- */
  async function renderBookmarks() {
    if (!meId()) { R.main.innerHTML = emptyHTML(IC.bookmark, 'Sign in to see your bookmarks', 'Bookmarks are private to you.', ['Sign in', 'signin']); return; }
    R.main.innerHTML = '<div class="bd-list" id="bdBL"><span class="bd-spin"></span></div>'; var tok = S.tok;
    try {
      var s = sb(); var r = await s.from('board_bookmarks').select('post_id,created_at').order('created_at', { ascending: false }).limit(50); if (r.error) throw r.error;
      var ids = (r.data || []).map(function (x) { return x.post_id; }); await hydrate(ids); if (S.tok !== tok) return;
      var items = ids.filter(function (id) { var p = S.posts.get(id); return p && !p.deleted_at; }).map(function (id) { return { id: id }; });
      var box = $('#bdBL', R.main); if (!box) return; box.innerHTML = '';
      if (!items.length) box.innerHTML = emptyHTML(IC.bookmark, 'No bookmarks yet', 'Tap the bookmark on any post to save it here. Only you can see them.'); else drawItems(box, items, { showReply: true });
    } catch (e) { var b3 = $('#bdBL', R.main); if (b3) b3.innerHTML = errorHTML(e); }
  }

  /* --- thread --- */
  async function renderThread(id) {
    R.main.innerHTML = '<div id="bdTH"><span class="bd-spin"></span></div>'; var tok = S.tok;
    try {
      var anc = []; try { var ar = await rpc('board_ancestors', { p_post: id }); anc = (ar || []).map(function (x) { return x.id; }); } catch (_) {}
      var ps = await hydrate(anc.concat([id])); if (S.tok !== tok) return; var main = S.posts.get(id); var box = $('#bdTH', R.main); if (!box) return;
      if (!main || main.status !== 'published' && main.author_id !== meId()) { box.innerHTML = emptyHTML(IC.mark, 'This post is unavailable', 'It may have been deleted, or you may not have access to it.'); return; }
      var h = anc.map(function (aid) { var p = S.posts.get(aid); return p ? postHTML(p, { line: true, thread: true }) : '<div class="bd-post gone line"><div class="bd-tomb">A post in this thread is unavailable.</div></div>'; }).join('');
      h += postHTML(main, { main: true, showReply: false });
      h += '<button type="button" class="bd-replybar" data-a="reply" data-pid="' + id + '"><span class="who">' + (meId() ? avatarHTML(meId(), 'sm').replace('<button', '<span').replace('</button>', '</span>') : '') + '</span><span>' + (main.deleted_at ? 'Post deleted' : 'Post your reply') + '</span></button>';
      h += '<div class="bd-list" id="bdReplies"></div><div class="bd-more-row" id="bdRM"></div>';
      box.innerHTML = h; $$('.bd-post', box).forEach(observeViews); var mainEl = $('.bd-post.main', box); if (mainEl && anc.length) setTimeout(function () { mainEl.scrollIntoView({ block: 'start' }); }, 30);
      if (!main.deleted_at) loadReplies(id, 0);
    } catch (e) { var b4 = $('#bdTH', R.main); if (b4) b4.innerHTML = errorHTML(e); }
  }
  async function loadReplies(id, from) {
    var box = $('#bdReplies', R.main), more = $('#bdRM', R.main); if (!box || !more) return; var s = sb(); more.innerHTML = '<span class="bd-spin"></span>';
    try {
      var r = await s.from('board_posts').select('id,created_at').eq('parent_id', id).is('deleted_at', null).order('created_at', { ascending: true }).limit(200); if (r.error) throw r.error;
      var ids = (r.data || []).map(function (x) { return x.id; }).slice(from, from + PAGE); await hydrate(ids);
      drawItems(box, ids.filter(function (x) { return S.posts.has(x); }).map(function (x) { return { id: x }; }));
      var total = (r.data || []).length; if (from + PAGE < total) more.innerHTML = '<button type="button" class="bd-btn ghost" data-go="morereplies" data-from="' + (from + PAGE) + '" data-id="' + id + '">Show more replies</button>'; else more.innerHTML = total ? '' : '<p class="bd-none c">No replies yet. Start the conversation.</p>';
    } catch (e) { more.innerHTML = '<p class="bd-none c">' + esc(errText(e)) + '</p>'; }
  }

  /* ---------- views counting: one real view per signed-in person, after a post is on screen for a moment ---------- */
  function observeViews(el) {
    if (!meId() || !('IntersectionObserver' in window)) return; var pid = el.dataset && el.dataset.pid; if (!pid) return;
    var p = S.posts.get(pid); if (!p || p.author_id === meId() || p.deleted_at || S.viewed.has(pid)) return;
    if (!S.vio) S.vio = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        var id = e.target.dataset.pid; if (!id) return;
        if (e.isIntersecting && e.intersectionRatio >= 0.6) { if (!S.pendingView.has(id)) S.pendingView.set(id, setTimeout(function () { S.pendingView.delete(id); if (S.viewed.has(id)) return; S.viewed.add(id); rpc('board_record_view', { p_post: id }).then(function () { var q = S.posts.get(id); if (q) { /* counter comes from the server on next load; no local guess */ } }, function () {}); S.vio && S.vio.unobserve(e.target); }, 1200)); }
        else if (S.pendingView.has(id)) { clearTimeout(S.pendingView.get(id)); S.pendingView.delete(id); }
      });
    }, { root: R.scroll, threshold: [0, 0.6] });
    S.vio.observe(el);
  }

  /* ---------- interactions ---------- */
  function bump(p, key, d) { p[key] = Math.max(0, (Number(p[key]) || 0) + d); }
  async function toggleLike(pid) {
    if (needAuth('like posts')) return; var p = S.posts.get(pid); if (!p || S.busy['l' + pid]) return; S.busy['l' + pid] = 1;
    var on = !S.mine.likes.has(pid); if (on) { S.mine.likes.add(pid); bump(p, 'like_count', 1); haptic('tap'); } else { S.mine.likes.delete(pid); bump(p, 'like_count', -1); } repaint(pid);
    try { await rpc('board_set_like', { p_post: pid, p_on: on }); } catch (e) { if (on) { S.mine.likes.delete(pid); bump(p, 'like_count', -1); } else { S.mine.likes.add(pid); bump(p, 'like_count', 1); } repaint(pid); note(errText(e), true); }
    finally { delete S.busy['l' + pid]; }
  }
  async function setRepost(pid, on) {
    if (needAuth('repost')) return; var p = S.posts.get(pid); if (!p || S.busy['r' + pid]) return; S.busy['r' + pid] = 1;
    if (on) { S.mine.reposts.add(pid); bump(p, 'repost_count', 1); } else { S.mine.reposts.delete(pid); bump(p, 'repost_count', -1); } repaint(pid);
    try { await rpc('board_set_repost', { p_post: pid, p_on: on }); note(on ? 'Reposted' : 'Repost removed'); Object.keys(S.feeds).forEach(function (k) { if (/^home:following/.test(k)) delete S.feeds[k]; }); }
    catch (e) { if (on) { S.mine.reposts.delete(pid); bump(p, 'repost_count', -1); } else { S.mine.reposts.add(pid); bump(p, 'repost_count', 1); } repaint(pid); note(errText(e), true); }
    finally { delete S.busy['r' + pid]; }
  }
  async function toggleBookmark(pid) {
    if (needAuth('bookmark posts')) return; var p = S.posts.get(pid); if (!p || S.busy['b' + pid]) return; S.busy['b' + pid] = 1;
    var on = !S.mine.bookmarks.has(pid); if (on) S.mine.bookmarks.add(pid); else S.mine.bookmarks.delete(pid); repaint(pid);
    try { await rpc('board_set_bookmark', { p_post: pid, p_on: on }); note(on ? 'Saved to bookmarks' : 'Removed from bookmarks'); if (S.view.type === 'bookmarks' && !on) { $$('.bd-post[data-pid="' + pid + '"]', R.main).forEach(function (el) { el.remove(); }); } }
    catch (e) { if (on) S.mine.bookmarks.delete(pid); else S.mine.bookmarks.add(pid); repaint(pid); note(errText(e), true); }
    finally { delete S.busy['b' + pid]; }
  }
  function linkFor(pid) { var u = location.href.split('#')[0]; return u + '#board-' + pid; }
  async function share(pid) {
    var p = S.posts.get(pid); if (!p) return; var url = linkFor(pid), text = (p.body || '').slice(0, 120);
    if (navigator.share) { try { await navigator.share({ title: nameOf(p.author_id) + ' on BMN Board', text: text, url: url }); return; } catch (e) { if (e && e.name === 'AbortError') return; } }
    copy(url);
  }
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); note('Link copied'); }
    catch (_) { try { var t = D.createElement('textarea'); t.value = text; t.style.cssText = 'position:fixed;opacity:0'; D.body.appendChild(t); t.select(); D.execCommand('copy'); t.remove(); note('Link copied'); } catch (e) { note('Copy this link: ' + text); } }
  }
  async function toggleFollow(uid, btn) {
    if (needAuth('follow people')) return; var s = sb(), me = meId(); if (!s || uid === me) return; var fol = isFollowing(uid); if (btn) btn.disabled = true;
    try {
      if (fol) { var r = await s.from('follows').delete().eq('follower_id', me).eq('following_id', uid); if (r.error) throw r.error; }
      else { var r2 = await s.from('follows').insert({ follower_id: me, following_id: uid }); if (r2.error) throw r2.error; try { s.from('notifications').insert({ user_id: uid, actor_id: me, type: 'follow', message: 'started following you' }).then(function () {}, function () {}); } catch (_) {} }
      var set = (window.bmnFollowing && window.bmnFollowing.has) ? window.bmnFollowing : (S.following || (S.following = new Set())); if (fol) set.delete(uid); else set.add(uid);
      try { window.LGTT && window.LGTT.onFollowChanged && window.LGTT.onFollowChanged(uid); } catch (_) {}
      $$('[data-follow="' + uid + '"]', R.root).forEach(function (b) { b.textContent = fol ? 'Follow' : 'Following'; b.classList.toggle('ghost', !fol); });
      Object.keys(S.feeds).forEach(function (k) { if (/^home:following/.test(k)) delete S.feeds[k]; });
    } catch (e) { note('Couldn\'t update follow: ' + errText(e), true); }
    finally { if (btn) btn.disabled = false; }
  }
  async function relate(uid, kind) { // block / mute use the same user_blocks table as messaging and the rest of Community
    if (needAuth('do that')) return; var s = sb(), me = meId();
    try {
      var r = await s.from('user_blocks').insert({ user_id: me, target_id: uid, kind: kind }); if (r.error && !/duplicate|23505/.test(r.error.message || r.error.code || '')) throw r.error;
      S.posts.forEach(function (p, id) { if (p.author_id === uid) S.posts.delete(id); }); S.feeds = {}; S.mineLoaded.clear(); note(kind === 'block' ? 'Blocked ' + handleOf(uid) : 'Muted ' + handleOf(uid));
      if (S.view.type === 'thread') { back(); } else render(false, R.scroll.scrollTop);
    } catch (e) { note(errText(e), true); }
  }
  async function removePost(pid) {
    try {
      await rpc('board_delete_post', { p_id: pid }); var p = S.posts.get(pid); if (p) { p.deleted_at = new Date().toISOString(); p.body = ''; p.media = []; }
      Object.keys(S.feeds).forEach(function (k) { S.feeds[k].items = S.feeds[k].items.filter(function (i) { return i.id !== pid; }); });
      note('Post deleted'); haptic('success');
      if (S.view.type === 'thread' && S.view.id === pid) back(); else $$('.bd-post[data-pid="' + pid + '"]', R.main).forEach(function (el) { el.remove(); });
    } catch (e) { note(errText(e), true); }
  }

  /* ---------- bottom sheet ---------- */
  function sheet(title, items, opts) {
    opts = opts || {}; var sh = R.sheet; var prev = D.activeElement;
    sh.innerHTML = '<div class="bd-sh-back" data-close></div><div class="bd-sh" role="dialog" aria-modal="true" aria-label="' + esc(title || 'Options') + '"><div class="bd-grab"></div>' + (title ? '<h3>' + esc(title) + '</h3>' : '') + (opts.sub ? '<p class="sub">' + esc(opts.sub) + '</p>' : '')
      + items.map(function (it, i) { return '<button type="button" class="bd-si' + (it.danger ? ' danger' : '') + (it.primary ? ' primary' : '') + '" data-i="' + i + '">' + (it.icon ? '<span class="ic">' + it.icon + '</span>' : '') + '<span>' + esc(it.label) + '</span></button>'; }).join('')
      + '<button type="button" class="bd-si cancel" data-close>Cancel</button></div>';
    sh.hidden = false; requestAnimationFrame(function () { sh.classList.add('show'); var f = $('.bd-si', sh); f && f.focus(); });
    var tok = sh._tok = (sh._tok || 0) + 1;
    function done() { sh.classList.remove('show'); setTimeout(function () { if (sh._tok !== tok) return; /* a follow-up sheet was opened meanwhile */ sh.hidden = true; sh.innerHTML = ''; }, 180); try { prev && prev.focus && prev.focus(); } catch (_) {} }
    sh.onclick = function (e) { if (e.target.closest('[data-close]')) { done(); return; } var b = e.target.closest('[data-i]'); if (!b) return; var it = items[+b.dataset.i]; done(); setTimeout(function () { it.fn && it.fn(); }, 120); };
    sheet.done = done;
  }
  function confirmSheet(title, sub, label, fn) { sheet(title, [{ label: label, danger: true, fn: fn }], { sub: sub }); }

  function postMenu(pid) {
    var p = S.posts.get(pid); if (!p) return; var me = meId(), own = p.author_id === me; var items = [];
    if (own) {
      if (Date.now() - new Date(p.created_at).getTime() < EDIT_MS && !p.deleted_at) items.push({ label: 'Edit post', icon: IC.pen, fn: function () { openComposer({ mode: 'edit', target: pid }); } });
      items.push({ label: 'Delete post', icon: IC.close, danger: true, fn: function () { confirmSheet('Delete this post?', 'It will be removed for everyone. Replies stay in the thread.', 'Delete', function () { removePost(pid); }); } });
    } else {
      var h = handleOf(p.author_id) || nameOf(p.author_id);
      items.push({ label: (isFollowing(p.author_id) ? 'Unfollow ' : 'Follow ') + h, icon: IC.at, fn: function () { toggleFollow(p.author_id); } });
      items.push({ label: 'Mute ' + h, icon: IC.bell, fn: function () { confirmSheet('Mute ' + h + '?', 'You won\'t see their posts in your timelines. They aren\'t told.', 'Mute', function () { relate(p.author_id, 'mute'); }); } });
      items.push({ label: 'Block ' + h, icon: IC.close, danger: true, fn: function () { confirmSheet('Block ' + h + '?', 'Neither of you will see the other\'s posts, and you can\'t message each other. This is the same block as everywhere in BMN.', 'Block', function () { relate(p.author_id, 'block'); }); } });
      items.push({ label: 'Report post', icon: IC.mark, danger: true, fn: function () { reportSheet(pid); } });
    }
    items.push({ label: 'Copy link', icon: IC.share, fn: function () { copy(linkFor(pid)); } });
    sheet('', items);
  }
  function reportSheet(pid) {
    if (needAuth('report posts')) return;
    sheet('Report this post', REASONS.map(function (r) { return { label: r[1], fn: async function () { try { await rpc('board_report_post', { p_post: pid, p_reason: r[0] }); note('Thanks. Our team will review this post.'); } catch (e) { note(errText(e), true); } } }; }), { sub: 'Why are you reporting it?' });
  }
  function repostMenu(pid) {
    if (needAuth('repost')) return; var on = S.mine.reposts.has(pid);
    sheet('', [{ label: on ? 'Undo repost' : 'Repost', icon: IC.repost, fn: function () { setRepost(pid, !on); } }, { label: 'Quote', icon: IC.quote, fn: function () { openComposer({ mode: 'quote', target: pid }); } }]);
  }

  /* ---------- profile (always the EXISTING Community profile) ---------- */
  function openProfile(uid) {
    if (!uid) return; S.fromBoard = true; hideBoard();
    try { if (window.LGTT && window.LGTT.openProfile) { window.LGTT.openProfile(uid); showBackPill(); return; } } catch (_) {}
    try { if (window.openBMNPublicProfile) { window.openBMNPublicProfile(uid); return; } } catch (_) {}
    S.fromBoard = false; showBoard(); note('Profiles are not available right now.', true);
  }
  async function openUsername(name) {
    var s = sb(); if (!s) return;
    try {
      var r = await s.from('profiles').select('id,username').ilike('username', String(name).replace(/[%\\]/g, '').replace(/_/g, '\\_')).limit(5); var hit = (r.data || []).filter(function (p) { return String(p.username).toLowerCase() === String(name).toLowerCase(); })[0];
      if (hit) openProfile(hit.id); else note('No BMN member @' + name + '.', true);
    } catch (e) { note(errText(e), true); }
  }
  function showBackPill() {
    if (!R.pill) { R.pill = D.createElement('button'); R.pill.type = 'button'; R.pill.className = 'bd-pill'; R.pill.innerHTML = IC.back + '<span>Board</span>'; R.pill.setAttribute('aria-label', 'Back to BMN Board'); R.pill.onclick = function () { S.fromBoard = false; hidePill(); try { window.LGTT && window.LGTT.open({ view: 'feed' }); } catch (_) {} open(); }; (D.getElementById('lgttStage') || D.body).appendChild(R.pill); }
    R.pill.hidden = false; R.pill.dataset.t = theme();
  }
  function hidePill() { if (R.pill) R.pill.hidden = true; }
  function watchStage() {
    var st = D.getElementById('lgttStage'); if (!st || watchStage.done) return; watchStage.done = true;
    new MutationObserver(function () { if (S.fromBoard && st.dataset.view !== 'profile') { S.fromBoard = false; hidePill(); } }).observe(st, { attributes: true, attributeFilter: ['data-view'] });
    D.addEventListener('click', function (e) { if (S.fromBoard && R.pill && !R.pill.hidden && !e.target.closest('.bd-pill') && e.target.closest('.lgtt-dk[data-dock]')) { S.fromBoard = false; hidePill(); } }, true);
  }

  /* ---------- photo viewer ---------- */
  function zoom(pid, idx) {
    var p = S.posts.get(pid); if (!p) return; var imgs = (p.media || []).filter(function (m) { return m.type === 'image'; }).map(function (m) { return { u: mediaUrl(m.url), alt: m.alt || '' }; }).filter(function (m) { return m.u; }); if (!imgs.length) return;
    var i = Math.min(idx, imgs.length - 1); var v = R.viewer; v.hidden = false;
    function draw() { v.innerHTML = '<button type="button" class="bd-vx" data-vc aria-label="Close">' + IC.close + '</button><img src="' + esc(imgs[i].u) + '" alt="' + esc(imgs[i].alt) + '">' + (imgs.length > 1 ? '<button type="button" class="bd-vn l" data-vn="-1" aria-label="Previous photo">' + IC.back + '</button><button type="button" class="bd-vn r" data-vn="1" aria-label="Next photo">' + IC.back + '</button><span class="bd-vc">' + (i + 1) + ' / ' + imgs.length + '</span>' : ''); }
    draw(); v.onclick = function (e) { if (e.target.closest('[data-vc]') || e.target === v) { v.hidden = true; v.innerHTML = ''; return; } var n = e.target.closest('[data-vn]'); if (n) { i = (i + Number(n.dataset.vn) + imgs.length) % imgs.length; draw(); } };
  }

  /* ---------- composer (post, reply, quote, edit) ---------- */
  function draftKey() { return 'bmn-board-draft:' + (meId() || 'anon'); }
  function getDraft() { try { return localStorage.getItem(draftKey()) || ''; } catch (_) { return ''; } }
  function setDraft(t) { try { if (t) localStorage.setItem(draftKey(), t); else localStorage.removeItem(draftKey()); } catch (_) {} }
  function openComposer(o) {
    if (needAuth(o.mode === 'reply' ? 'reply' : o.mode === 'quote' ? 'quote posts' : 'post')) return;
    var target = o.target ? S.posts.get(o.target) : null; var c = S.comp = { mode: o.mode || 'post', target: o.target || null, files: [], busy: false, text: '' };
    if (c.mode === 'edit' && target) c.text = target.body; else if (c.mode === 'post') c.text = getDraft();
    var label = { post: 'Post', reply: 'Reply', quote: 'Post', edit: 'Save' }[c.mode];
    var ctx = '';
    if (c.mode === 'reply' && target) ctx = '<div class="bd-cx">Replying to <b>' + esc(handleOf(target.author_id) || nameOf(target.author_id)) + '</b></div><div class="bd-cxq">' + esc((target.body || 'Attachment').slice(0, 140)) + '</div>';
    if (c.mode === 'quote' && target) ctx = '<div class="bd-cxqq">' + quoteHTML(target.id) + '</div>';
    if (c.mode === 'edit') ctx = '<div class="bd-cx">Editing your post. You can edit for 24 hours after posting.</div>';
    R.comp.innerHTML = '<div class="bd-ch"><button type="button" class="bd-ib" id="bdCX" aria-label="Close">' + IC.close + '</button><span class="bd-ct">' + ({ post: 'New post', reply: 'Reply', quote: 'Quote post', edit: 'Edit post' }[c.mode]) + '</span><button type="button" class="bd-btn" id="bdCS" disabled>' + label + '</button></div>'
      + '<div class="bd-cb">' + ctx + '<div class="bd-cin">' + avatarHTML(meId(), 'sm').replace('<button', '<span').replace('</button>', '</span>') + '<textarea id="bdCT" rows="3" maxlength="' + MAX + '" placeholder="' + (c.mode === 'reply' ? 'Post your reply' : c.mode === 'quote' ? 'Add a comment' : 'What\'s happening?') + '" aria-label="Post text" enterkeyhint="enter"></textarea></div><div id="bdCF" class="bd-cf"></div><div id="bdCE" class="bd-ce" role="alert"></div></div>'
      + '<div class="bd-cbar">' + (c.mode === 'edit' ? '<span></span>' : '<button type="button" class="bd-ib" id="bdCP" aria-label="Add photos">' + IC.photo + '</button><button type="button" class="bd-ib" id="bdCV" aria-label="Add a video">' + IC.video + '</button>') + '<span class="bd-cc" id="bdCC"></span></div>'
      + '<input type="file" id="bdFI" accept="image/*" multiple hidden><input type="file" id="bdFV" accept="video/mp4,video/quicktime,video/webm" hidden>';
    R.comp.hidden = false; requestAnimationFrame(function () { R.comp.classList.add('show'); });
    var ta = $('#bdCT', R.comp); ta.value = c.text; compUpdate();
    ta.addEventListener('input', function () { c.text = ta.value; if (c.mode === 'post') setDraft(c.text); compUpdate(); autosize(ta); }); autosize(ta);
    setTimeout(function () { try { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); } catch (_) {} }, 260);
    $('#bdCX', R.comp).onclick = closeComposer; $('#bdCS', R.comp).onclick = submitComposer;
    if ($('#bdCP', R.comp)) { $('#bdCP', R.comp).onclick = function () { $('#bdFI', R.comp).click(); }; $('#bdCV', R.comp).onclick = function () { $('#bdFV', R.comp).click(); }; $('#bdFI', R.comp).onchange = function (e) { addFiles(e.target.files, 'image'); e.target.value = ''; }; $('#bdFV', R.comp).onchange = function (e) { addFiles(e.target.files, 'video'); e.target.value = ''; }; }
  }
  function autosize(ta) { ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 220) + 'px'; }
  function compUpdate() {
    var c = S.comp; if (!c) return; var left = MAX - c.text.length; var cc = $('#bdCC', R.comp); if (cc) { cc.textContent = left <= 60 ? String(left) : ''; cc.classList.toggle('warn', left <= 20); }
    var ok = !c.busy && (c.text.trim().length > 0 || c.files.length > 0) && left >= 0; if (c.mode === 'edit' && c.target) { var t = S.posts.get(c.target); if (t && c.text.trim() === t.body && !c.files.length) ok = false; if (!c.text.trim() && !(t && t.media && t.media.length)) ok = false; }
    var b = $('#bdCS', R.comp); if (b) b.disabled = !ok;
  }
  function closeComposer(force) {
    var c = S.comp; if (!c) return;
    var dirty = c.mode !== 'post' && (c.text.trim() || c.files.length) && !force && c.mode !== 'edit';
    if (dirty && !c.busy) { sheet('Discard this ' + (c.mode === 'reply' ? 'reply' : 'post') + '?', [{ label: 'Discard', danger: true, fn: function () { closeComposer(true); } }]); return; }
    c.files.forEach(function (f) { try { URL.revokeObjectURL(f.preview); } catch (_) {} });
    R.comp.classList.remove('show'); setTimeout(function () { R.comp.hidden = true; R.comp.innerHTML = ''; }, 200); S.comp = null;
  }
  function renderFiles() {
    var c = S.comp; var box = $('#bdCF', R.comp); if (!box) return;
    box.innerHTML = c.files.map(function (f, i) { return '<div class="bd-cfi">' + (f.type === 'video' ? '<video src="' + esc(f.preview) + '" muted playsinline preload="metadata"></video><span class="vb">' + IC.video + '</span>' : '<img src="' + esc(f.preview) + '" alt="">') + '<button type="button" data-rm="' + i + '" aria-label="Remove attachment">' + IC.close + '</button>' + (f.state ? '<span class="st">' + esc(f.state) + '</span>' : '') + '</div>'; }).join('');
    $$('[data-rm]', box).forEach(function (b) { b.onclick = function () { if (c.busy) return; var f = c.files.splice(+b.dataset.rm, 1)[0]; try { URL.revokeObjectURL(f.preview); } catch (_) {} renderFiles(); compUpdate(); }; });
  }
  function addFiles(list, kind) {
    var c = S.comp; if (!c || c.busy) return; var err = $('#bdCE', R.comp); err.textContent = '';
    var maxImg = (typeof window.BMN_MAX_IMAGE_MB === 'number' ? window.BMN_MAX_IMAGE_MB : 50), maxVid = (typeof window.BMN_MAX_VIDEO_MB === 'number' ? window.BMN_MAX_VIDEO_MB : 200);
    Array.prototype.slice.call(list || []).forEach(function (f) {
      var isV = /^video\//.test(f.type), isI = /^image\//.test(f.type);
      if (!isV && !isI) { err.textContent = 'Only photos and videos can be attached.'; return; }
      if (c.files.length >= MAX_MEDIA) { err.textContent = 'You can attach up to ' + MAX_MEDIA + ' photos or videos.'; return; }
      if (isV && c.files.some(function (x) { return x.type === 'video'; })) { err.textContent = 'Only one video per post.'; return; }
      if (isV && f.size > maxVid * 1048576) { err.textContent = 'That video is over ' + maxVid + ' MB.'; return; }
      if (isI && f.size > maxImg * 1048576) { err.textContent = 'That photo is over ' + maxImg + ' MB.'; return; }
      c.files.push({ file: f, type: isV ? 'video' : 'image', preview: URL.createObjectURL(f), ref: null, state: '' });
    });
    renderFiles(); compUpdate();
  }
  function shrink(file, max, q) {
    return new Promise(function (res) {
      if (!/^image\/(jpeg|png|webp|heic|heif)$/i.test(file.type)) { res({ file: file, w: 0, h: 0 }); return; }
      var img = new Image(), url = URL.createObjectURL(file);
      img.onload = function () {
        try {
          var w = img.naturalWidth, h = img.naturalHeight, k = Math.min(1, max / Math.max(w, h)); var cv = D.createElement('canvas'); cv.width = Math.round(w * k); cv.height = Math.round(h * k); cv.getContext('2d').drawImage(img, 0, 0, cv.width, cv.height);
          cv.toBlob(function (b) { URL.revokeObjectURL(url); if (!b) { res({ file: file, w: w, h: h }); return; } res({ file: new File([b], (file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg' }), w: cv.width, h: cv.height }); }, 'image/jpeg', q);
        } catch (_) { URL.revokeObjectURL(url); res({ file: file, w: 0, h: 0 }); }
      };
      img.onerror = function () { URL.revokeObjectURL(url); res({ file: file, w: 0, h: 0 }); }; img.src = url;
    });
  }
  async function submitComposer() {
    var c = S.comp; if (!c || c.busy) return; var err = $('#bdCE', R.comp); err.textContent = ''; c.busy = true; compUpdate(); var btn = $('#bdCS', R.comp); var label = btn.textContent; btn.textContent = '…';
    try {
      if (c.mode === 'edit') {
        await rpc('board_edit_post', { p_id: c.target, p_body: c.text.trim() }); var p = S.posts.get(c.target); if (p) { p.body = c.text.trim(); p.edited_at = new Date().toISOString(); } repaint(c.target); closeComposer(true); note('Post updated'); return;
      }
      var media = [];
      for (var i = 0; i < c.files.length; i++) {
        var f = c.files[i]; if (!f.ref) {
          f.state = 'Uploading…'; renderFiles(); if (!window.uploadCommunityFile) throw new Error('Media upload is not available right now.');
          var up = f.file, w = 0, h = 0; if (f.type === 'image') { var s1 = await shrink(f.file, 1600, 0.85); up = s1.file; w = s1.w; h = s1.h; }
          var ref = await window.uploadCommunityFile(up, f.type === 'video' ? 'posts' : 'board', function (pct) { f.state = (typeof pct === 'number' ? Math.round(pct) + '%' : 'Uploading…'); var st = $$('.bd-cfi .st', R.comp)[i]; if (st) st.textContent = f.state; });
          if (!ref) throw new Error('Upload failed. Please try again.'); f.ref = String(ref).replace(/^storage:/, ''); f.w = w; f.h = h; f.state = 'Uploaded'; renderFiles();
        }
        var it = { type: f.type, url: f.ref }; if (f.w && f.h) { it.w = f.w; it.h = f.h; } media.push(it);
      }
      var args = { p_body: c.text.trim(), p_media: media }; if (c.mode === 'reply') args.p_parent = c.target; if (c.mode === 'quote') args.p_quote = c.target;
      var id = await rpc('board_create_post', args); if (c.mode === 'post') setDraft('');
      var wasMode = c.mode, tgt = c.target; closeComposer(true); haptic('success'); note(wasMode === 'reply' ? 'Reply posted' : 'Posted');
      await afterPost(id, wasMode, tgt);
    } catch (e) { err.textContent = errText(e); c.files.forEach(function (f) { if (f.state === 'Uploading…') f.state = 'Failed'; }); renderFiles(); }
    finally { if (S.comp === c) { c.busy = false; var b = $('#bdCS', R.comp); if (b) b.textContent = label; compUpdate(); } }
  }
  async function afterPost(id, mode, target) {
    try {
      await hydrate([id]); var p = S.posts.get(id); if (!p) return;
      if (mode === 'reply') { var t = S.posts.get(target); if (t) { bump(t, 'reply_count', 1); repaint(target); }
        if (S.view.type === 'thread') { var box = $('#bdReplies', R.main); if (box) { var nr = $('.bd-none.c', R.main); if (nr) nr.remove(); drawItems(box, [{ id: id }]); } } return; }
      if (mode === 'quote') { var q = S.posts.get(target); if (q) { bump(q, 'quote_count', 1); repaint(target); } }
      ['home:latest', 'home:for_you', 'mine'].forEach(function (k) { var st = S.feeds[k]; if (st && st.loaded) st.items.unshift({ id: id, at: p.created_at }); });
      var fol = S.feeds['home:following']; if (fol && fol.loaded) fol.items.unshift({ id: id, at: p.created_at });
      if (S.view.type === 'home' || S.view.type === 'mine') { if (S.view.type === 'home' && S.mode === 'following' && !fol) { render(true); } else { var ctx = R.feedCtx; if (ctx && ctx.box) { var empty = $('.bd-empty', ctx.box); if (empty) ctx.box.innerHTML = ''; ctx.box.insertAdjacentHTML('afterbegin', postHTML(p, {})); observeViews(ctx.box.firstElementChild); R.scroll.scrollTop = 0; } } }
      else { S.stack = []; S.mode = 'latest'; S.view = { type: 'home' }; render(true); }
    } catch (_) {}
  }

  /* ---------- shell ---------- */
  function build() {
    if (S.built) return;
    var root = D.createElement('section'); root.id = 'bmnBoard'; root.className = 'bd'; root.setAttribute('role', 'region'); root.setAttribute('aria-label', 'BMN Board'); root.hidden = true;
    root.innerHTML = '<header class="bd-top"><button type="button" class="bd-ib bd-glass" id="bdBack">' + IC.back + '</button><h1 class="bd-title" id="bdTitle">BMN Board</h1><button type="button" class="bd-me" id="bdMe"></button><button type="button" class="bd-ib bd-glass" id="bdRef" aria-label="Refresh">' + IC.refresh + '</button></header>'
      + '<div class="bd-tabs" id="bdTabs" role="tablist"><button type="button" role="tab" data-mode="for_you">For You</button><button type="button" role="tab" data-mode="following">Following</button><button type="button" role="tab" data-mode="latest">Latest</button><i class="bd-ind"></i></div>'
      + '<div class="bd-scroll" id="bdScroll" role="main" tabindex="-1"><div id="bdMain"></div></div>'
      + '<button type="button" class="bd-fab" id="bdFab" aria-label="Write a post">' + IC.pen + '</button>'
      + '<nav class="bd-nav bd-glass" id="bdNav" aria-label="Board sections">'
      + '<button type="button" data-nav="home" aria-label="Home">' + IC.home + '<span>Home</span></button><button type="button" data-nav="discover" aria-label="Discover">' + IC.compass + '<span>Discover</span></button><button type="button" data-nav="search" aria-label="Search">' + IC.search + '<span>Search</span></button>'
      + '<button type="button" data-nav="notifs" aria-label="Notifications">' + IC.bell + '<i class="bd-nb" hidden></i><span>Alerts</span></button><button type="button" data-nav="bookmarks" aria-label="Bookmarks">' + IC.bookmark + '<span>Saved</span></button></nav>'
      + '<div class="bd-comp" id="bdComp" hidden></div><div class="bd-sheet" id="bdSheet" hidden></div><div class="bd-viewer" id="bdViewer" hidden></div><div class="bd-toast" id="bdToast" role="status" aria-live="polite"></div>';
    (D.getElementById('lgttStage') || D.body).appendChild(root);
    R = { root: root, back: $('#bdBack', root), title: $('#bdTitle', root), me: $('#bdMe', root), ref: $('#bdRef', root), tabs: $('#bdTabs', root), scroll: $('#bdScroll', root), main: $('#bdMain', root), fab: $('#bdFab', root), nav: $('#bdNav', root), comp: $('#bdComp', root), sheet: $('#bdSheet', root), viewer: $('#bdViewer', root), toast: $('#bdToast', root) };
    S.built = true; applyTheme();
    R.back.onclick = back; R.ref.onclick = function () { R.ref.classList.add('spin'); refresh(); setTimeout(function () { R.ref.classList.remove('spin'); }, 700); };
    R.fab.onclick = function () { openComposer({ mode: 'post' }); };
    R.me.onclick = function () { var me = meId(); if (!me) { needAuth('use your Board menu'); return; } sheet('', [{ label: 'My profile', icon: IC.at, fn: function () { openProfile(me); } }, { label: 'My Board posts', icon: IC.mark, fn: function () { S.stack = []; setView({ type: 'mine' }, false); } }, { label: 'Bookmarks', icon: IC.bookmark, fn: function () { goRoot('bookmarks'); } }, { label: 'Back to Community', icon: IC.back, fn: close }]); };
    R.tabs.addEventListener('click', function (e) { var b = e.target.closest('[data-mode]'); if (!b) return; if (b.dataset.mode === S.mode && S.view.type === 'home') { if (R.scroll.scrollTop > 40) R.scroll.scrollTo({ top: 0, behavior: 'smooth' }); else refresh(); return; } S.mode = b.dataset.mode; S.stack = []; S.view = { type: 'home' }; render(true); });
    R.nav.addEventListener('click', function (e) { var b = e.target.closest('[data-nav]'); if (b) goRoot(b.dataset.nav); });
    R.main.addEventListener('click', onMainClick);
    R.main.addEventListener('keydown', function (e) { if ((e.key === 'Enter' || e.key === ' ') && e.target.matches('.bd-quote,.bd-note')) { e.preventDefault(); e.target.click(); } else if (e.key === 'Enter' && e.target.matches('.bd-post') && !e.target.closest('.bd-post.main')) { openThread(e.target.dataset.pid); } });
    R.main.addEventListener('play', function (e) { if (e.target.tagName === 'VIDEO') $$('video', R.main).forEach(function (v) { if (v !== e.target) v.pause(); }); }, true);
    D.addEventListener('keydown', function (e) { if (e.key !== 'Escape' || !S.open) return; if (!R.viewer.hidden) { R.viewer.hidden = true; return; } if (!R.sheet.hidden) { sheet.done && sheet.done(); return; } if (S.comp) { closeComposer(); return; } back(); });
    if (window.matchMedia) { try { matchMedia('(prefers-color-scheme: light)').addEventListener('change', applyTheme); } catch (_) {} }
    window.addEventListener('storage', applyTheme); window.addEventListener('focus', applyTheme);
    if ('IntersectionObserver' in window) { /* observers are created per render */ }
  }
  function openThread(id) { if (!id) return; setView({ type: 'thread', id: id }, true); }
  function onMainClick(e) {
    var t = e.target;
    var a = t.closest('a.bd-tag'); if (a) { e.preventDefault(); setView({ type: 'tag', tag: a.dataset.tag }, true); return; }
    a = t.closest('a.bd-men'); if (a) { e.preventDefault(); if (a.dataset.prof) openProfile(a.dataset.prof); else openUsername(a.dataset.user); return; }
    if (t.closest('a.bd-link')) return;
    var f = t.closest('[data-follow]'); if (f) { toggleFollow(f.dataset.follow, f); return; }
    var g = t.closest('[data-go]'); if (g) { var k = g.dataset.go; if (k === 'compose') openComposer({ mode: 'post' }); else if (k === 'discover') goRoot('discover'); else if (k === 'signin') { try { window.requestCommunityAuth && window.requestCommunityAuth('board'); } catch (_) {} } else if (k === 'retry') { refresh(); } else if (k === 'more') { var c = R.feedCtx; if (c) loadMore(c.key, c.spec, c.box, c.more); } else if (k === 'morereplies') { loadReplies(g.dataset.id, Number(g.dataset.from)); } return; }
    var pr = t.closest('[data-prof]'); if (pr) { e.preventDefault(); openProfile(pr.dataset.prof); return; }
    var tg = t.closest('[data-tag]'); if (tg && !t.closest('.bd-post')) { setView({ type: 'tag', tag: tg.dataset.tag }, true); return; }
    var qt = t.closest('[data-qt]'); if (qt) { S.qTab = qt.dataset.qt; render(false); return; }
    var z = t.closest('[data-zoom]'); if (z) { zoom(z.dataset.pid, Number(z.dataset.zoom)); return; }
    var act = t.closest('[data-a]');
    if (act) {
      var pid = act.dataset.pid, k2 = act.dataset.a;
      if (k2 === 'like') toggleLike(pid); else if (k2 === 'bm') toggleBookmark(pid); else if (k2 === 'rp') repostMenu(pid); else if (k2 === 'share') share(pid); else if (k2 === 'more') postMenu(pid); else if (k2 === 'reply') openComposer({ mode: 'reply', target: pid });
      return;
    }
    var op = t.closest('[data-open]'); if (op) { if (op.dataset.open) openThread(op.dataset.open); return; }
    if (t.closest('video,.bd-vid')) return;
    var post = t.closest('.bd-post'); if (post && !post.classList.contains('main') && !post.classList.contains('gone')) { if (window.getSelection && String(window.getSelection()).length) return; openThread(post.dataset.pid); }
  }

  /* ---------- open / close ---------- */
  function hideBoard() { if (!R.root) return; R.root.hidden = true; R.root.classList.remove('open'); var st = D.getElementById('lgttStage'); st && st.classList.remove('bmn-inbox-open', 'bmn-board-open'); D.body.classList.remove('bmn-board-open'); try { window.LGTT && window.LGTT.resume && window.LGTT.resume(); } catch (_) {} }
  function showBoard() { R.root.hidden = false; requestAnimationFrame(function () { R.root.classList.add('open'); }); var st = D.getElementById('lgttStage'); st && st.classList.add('bmn-inbox-open', 'bmn-board-open'); D.body.classList.add('bmn-board-open'); try { window.LGTT && window.LGTT.resume && window.LGTT.resume(); } catch (_) {} }
  function open(o) {
    o = o || {}; build(); watchStage();
    try { if (window.LGTT && !D.documentElement.classList.contains('lgtt-open')) window.LGTT.open({ view: 'feed' }); } catch (_) {}
    if (!(D.getElementById('lgttStage') && R.root.parentNode === D.getElementById('lgttStage'))) { var st0 = D.getElementById('lgttStage'); if (st0) st0.appendChild(R.root); }
    S.open = true; S.fromBoard = false; hidePill(); applyTheme(); showBoard();
    if (o.tag) { S.stack = [{ type: 'home' }]; S.view = { type: 'tag', tag: o.tag }; } else if (o.post) { S.stack = [{ type: 'home' }]; S.view = { type: 'thread', id: o.post }; } else if (!S.view || !isRoot(S.view) && !S.stack.length && S.view.type !== 'home') { S.view = { type: 'home' }; }
    if (o.fresh) { S.stack = []; S.view = { type: 'home' }; S.feeds = {}; }
    render(true); pollUnread(); clearInterval(S.pollT); S.pollT = setInterval(function () { if (!D.hidden) pollUnread(); }, 45000);
    try { R.back.focus({ preventScroll: true }); } catch (_) {}
  }
  function close() {
    if (!R.root) return; if (S.comp) closeComposer(true); S.open = false; hideBoard(); clearInterval(S.pollT); S.pollT = setInterval(function () { if (!D.hidden && meId()) pollUnread(); }, 90000);
    $$('video', R.main).forEach(function (v) { try { v.pause(); } catch (_) {} });
  }
  function hashOpen() { var m = /^#board-([0-9a-f-]{36})$/i.exec(location.hash || ''); if (m && UUID.test(m[1])) { open({ post: m[1] }); } }

  window.BMNBoard = {
    open: open, close: close, refresh: refresh, openPost: function (id) { open({ post: id }); }, openTag: function (t) { open({ tag: String(t || '').replace(/^#/, '').toLowerCase() }); },
    _state: S, _bodyHTML: bodyHTML
  };

  // light background polling for the unread dot on the B button (only when signed in and the B1 tables exist)
  function boot() {
    build(); R.root.hidden = true;
    var tries = 0; (function wait() { if (meId() || ++tries > 20) { pollUnread(); S.pollT = setInterval(function () { if (!D.hidden && meId()) pollUnread(); }, 90000); hashOpen(); } else setTimeout(wait, 1000); })();
    window.addEventListener('hashchange', hashOpen);
  }
  if (D.readyState === 'loading') D.addEventListener('DOMContentLoaded', boot); else boot();
})();
