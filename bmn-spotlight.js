/* BMN Global Spotlight — frontend (Batch 3).
   1) Everyone: a Spotlight card on Discover (next to search) and, if the owner chose it, under the profile header. Content comes ONLY from the
      database (public.bmn_spotlight_active). Nothing is hardcoded here: no holidays, no events, no dates.
   2) Owner only: a "Spotlight" manager (create, edit, schedule, publish, pause, delete, audit).
   The owner check here only decides whether the button is SHOWN; every owner RPC is checked again in the database (public.is_bmn_owner()).
   If the database migration 003_bmn_spotlight has not been applied, the RPC fails and this file shows nothing and changes nothing.
   No secrets live in this file. Uses the existing window.bmnSupabase client. */
(function () {
  'use strict';
  if (window.__bmnSpotlightLoaded) return; window.__bmnSpotlightLoaded = true;

  var esc = function (v) { return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var KINDS = { holiday: 'Holiday', seasonal: 'Seasonal', entertainment: 'Entertainment', global_event: 'Global event', announcement: 'Announcement', campaign: 'Campaign' };
  var ACCENTS = { gold: '#f5b942', red: '#ff5d5d', blue: '#4da3ff', violet: '#a77bff', green: '#3ecf8e', pink: '#ff6fb5' };
  var offset = 0;            // server time minus device time, so a wrong phone clock cannot show a wrong countdown
  var feed = { search: [], profile: [] };
  var cdTimer = null;

  function sb() { return window.bmnSupabase && typeof window.bmnSupabase.rpc === 'function' ? window.bmnSupabase : null; }
  function now() { return Date.now() + offset; }

  /* A link is rendered only if it is https:// or an in-app path that starts with a single "/". The database enforces the same rule. */
  function safeLink(u) {
    u = String(u || '').trim();
    if (/^https:\/\/[^\s]+$/.test(u) && u.length <= 500) return u;
    if (/^\/[^\/\s][^\s]*$/.test(u) && u.length <= 500) return u;
    return '';
  }

  /* ---------------------------------------------------------------- styles (no backdrop-filter, no animation loops: cheap on phones) */
  var CSS = '' +
    '.bmn-sp{display:flex;align-items:center;gap:12px;margin:10px 16px 4px;padding:12px 14px;border-radius:16px;color:#fff;text-decoration:none;position:relative;overflow:hidden;' +
    'background:linear-gradient(120deg,color-mix(in srgb,var(--sp,#f5b942) 34%,rgba(18,20,30,.92)),rgba(18,20,30,.92) 70%);border:1px solid color-mix(in srgb,var(--sp,#f5b942) 55%,transparent);box-shadow:0 4px 18px rgba(0,0,0,.25)}' +
    '.bmn-sp[href]{cursor:pointer}.bmn-sp:focus-visible{outline:2px solid var(--sp,#f5b942);outline-offset:2px}' +
    '.bmn-sp-em{font-size:26px;line-height:1;flex:none}.bmn-sp-tx{min-width:0;flex:1}' +
    '.bmn-sp-k{font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;opacity:.78;font-weight:700}' +
    '.bmn-sp-t{font-size:15px;font-weight:800;line-height:1.25;overflow-wrap:anywhere}.bmn-sp-s{font-size:12.5px;opacity:.85;margin-top:2px;overflow-wrap:anywhere}' +
    '.bmn-sp-cd{font-variant-numeric:tabular-nums;font-size:12.5px;font-weight:700;margin-top:4px;color:var(--sp,#f5b942)}' +
    '.bmn-sp-cta{flex:none;font-size:12.5px;font-weight:800;padding:7px 12px;border-radius:999px;background:var(--sp,#f5b942);color:#111}' +
    '.bmn-sp-stack{display:flex;flex-direction:column}' +
    '#bmnSpMgr{position:fixed;inset:0;z-index:2147483000;display:none;background:rgba(6,7,12,.72);color:#f2f4f8;font:14px/1.4 -apple-system,system-ui,Segoe UI,Roboto,sans-serif}#bmnSpMgr.open{display:block}' +
    '#bmnSpMgr .sp-panel{position:absolute;inset:0;max-width:720px;margin:0 auto;background:#12141e;display:flex;flex-direction:column}' +
    '#bmnSpMgr .sp-head{display:flex;align-items:center;gap:10px;padding:calc(env(safe-area-inset-top,0px) + 12px) 16px 10px;border-bottom:1px solid rgba(255,255,255,.08)}' +
    '#bmnSpMgr h2{margin:0;font-size:18px;flex:1}#bmnSpMgr .sp-body{flex:1;overflow:auto;-webkit-overflow-scrolling:touch;padding:12px 16px calc(env(safe-area-inset-bottom,0px) + 24px)}' +
    '#bmnSpMgr button{font:inherit;color:inherit;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.16);border-radius:10px;padding:8px 12px;min-height:40px}' +
    '#bmnSpMgr button.pri{background:#f5b942;color:#111;border-color:#f5b942;font-weight:800}#bmnSpMgr button.dng{color:#ff8a8a}#bmnSpMgr button:disabled{opacity:.5}' +
    '#bmnSpMgr .sp-row{border:1px solid rgba(255,255,255,.1);border-radius:12px;padding:10px 12px;margin:0 0 10px;background:rgba(255,255,255,.04)}' +
    '#bmnSpMgr .sp-row b{overflow-wrap:anywhere}#bmnSpMgr .sp-meta{opacity:.75;font-size:12.5px;margin:2px 0 8px}#bmnSpMgr .sp-acts{display:flex;flex-wrap:wrap;gap:8px}' +
    '#bmnSpMgr .sp-st{display:inline-block;font-size:11px;font-weight:800;padding:2px 8px;border-radius:999px;margin-left:6px;background:#444;text-transform:uppercase}' +
    '#bmnSpMgr .st-live{background:#1f8f5f}#bmnSpMgr .st-scheduled{background:#2f6fb8}#bmnSpMgr .st-paused{background:#9a6b12}#bmnSpMgr .st-ended{background:#555}' +
    '#bmnSpMgr label{display:block;margin:10px 0 4px;font-weight:700;font-size:12.5px}#bmnSpMgr input[type=text],#bmnSpMgr input[type=datetime-local],#bmnSpMgr input[type=number],#bmnSpMgr select{width:100%;box-sizing:border-box;font:inherit;font-size:16px;color:#fff;background:#1c1f2c;border:1px solid rgba(255,255,255,.18);border-radius:10px;padding:10px}' +
    '#bmnSpMgr .sp-chk{display:flex;gap:8px;align-items:center;font-weight:600}#bmnSpMgr .sp-chk input{width:20px;height:20px}#bmnSpMgr .sp-hint{opacity:.7;font-size:12px;margin-top:3px}' +
    '#bmnSpMgr .sp-err{color:#ff8a8a;margin:10px 0;font-weight:700}#bmnSpMgr .sp-ok{color:#6fe3a8;margin:10px 0;font-weight:700}#bmnSpMgr .sp-empty{opacity:.75;padding:18px 4px}' +
    '#bmnSpMgr .bmn-sp{margin:6px 0}.bmn-spot-open{margin-left:6px}' +
    /* The site hides every direct child of <body> except #lgtt while the community app is open; this higher-specificity rule keeps the manager visible. */
    'html.bmn-community-app body>#bmnSpMgr.open{display:block!important;visibility:visible!important;pointer-events:auto!important;opacity:1!important}';
  var styled = false;
  function injectCss() { if (styled) return; styled = true; var s = document.createElement('style'); s.id = 'bmn-spotlight-css'; s.textContent = CSS; document.head.appendChild(s); }

  /* ---------------------------------------------------------------- card rendering */
  function fmtCountdown(ms) {
    var s = Math.max(0, Math.floor(ms / 1000)), d = Math.floor(s / 86400); s -= d * 86400;
    var h = Math.floor(s / 3600); s -= h * 3600; var m = Math.floor(s / 60); s -= m * 60;
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return (d ? d + 'd ' : '') + p(h) + ':' + p(m) + ':' + p(s);
  }
  function cardHtml(it) {
    var link = safeLink(it.link_url), ext = /^https:/.test(link);
    var accent = ACCENTS[it.accent] || ACCENTS.gold;
    var cd = it.countdown_to && Date.parse(it.countdown_to) > now()
      ? '<div class="bmn-sp-cd" data-sp-cd="' + esc(it.countdown_to) + '">' + esc(it.countdown_label || 'Starts in') + ' <span></span></div>' : '';
    var inner = (it.emoji ? '<div class="bmn-sp-em" aria-hidden="true">' + esc(it.emoji) + '</div>' : '') +
      '<div class="bmn-sp-tx"><div class="bmn-sp-k">' + esc(KINDS[it.kind] || 'Spotlight') + '</div><div class="bmn-sp-t">' + esc(it.title) + '</div>' +
      (it.subtitle ? '<div class="bmn-sp-s">' + esc(it.subtitle) + '</div>' : '') + cd + '</div>' +
      (link && it.cta_label ? '<span class="bmn-sp-cta">' + esc(it.cta_label) + '</span>' : '');
    if (link) return '<a class="bmn-sp" style="--sp:' + accent + '" href="' + esc(link) + '"' + (ext ? ' target="_blank" rel="noopener noreferrer"' : '') + (it.cta_label ? '' : ' aria-label="' + esc(it.title) + '"') + '>' + inner + '</a>';
    return '<div class="bmn-sp" style="--sp:' + accent + '" role="note">' + inner + '</div>';   // no link = information only, not a button
  }
  function stackHtml(items) { return items.map(cardHtml).join(''); }

  function mount(surface) {
    var host = document.getElementById(surface === 'search' ? 'bmnSpotSearch' : 'bmnSpotProfile');
    var items = feed[surface] || [];
    if (!items.length) { if (host) host.remove(); return; }
    if (!host) {
      var anchor = surface === 'search' ? document.querySelector('#lgttDiscScroll .lgtt-page-h') : document.getElementById('lgttProfHead');
      if (!anchor || !anchor.parentNode) return;
      host = document.createElement('div'); host.id = surface === 'search' ? 'bmnSpotSearch' : 'bmnSpotProfile'; host.className = 'bmn-sp-stack'; host.setAttribute('aria-label', 'BMN Spotlight');
      anchor.parentNode.insertBefore(host, anchor.nextSibling);
    }
    var html = stackHtml(items); if (host.__html !== html) { host.innerHTML = html; host.__html = html; }
    startCountdowns();
  }
  function tickCountdowns() {
    var els = document.querySelectorAll('[data-sp-cd]'), any = false, expired = false;
    for (var i = 0; i < els.length; i++) {
      var left = Date.parse(els[i].getAttribute('data-sp-cd')) - now();
      if (left <= 0) { expired = true; continue; }
      any = true; var span = els[i].querySelector('span'); var t = fmtCountdown(left); if (span && span.textContent !== t) span.textContent = t;
    }
    if (expired) { refresh(); }
    if (!any && cdTimer) { clearInterval(cdTimer); cdTimer = null; }
  }
  function startCountdowns() { tickCountdowns(); if (!cdTimer && document.querySelector('[data-sp-cd]')) cdTimer = setInterval(function () { if (!document.hidden) tickCountdowns(); }, 1000); }

  /* ---------------------------------------------------------------- public feed */
  var failedOnce = false, lastFetch = 0, inflight = null;
  async function load(surface) {
    var c = sb(); if (!c) return;
    try {
      var r = await c.rpc('bmn_spotlight_active', { p_surface: surface });
      if (r.error) throw r.error;
      var d = r.data || {}; if (d.now) { var t = Date.parse(d.now); if (!isNaN(t)) offset = t - Date.now(); }
      feed[surface] = Array.isArray(d.items) ? d.items.filter(function (x) { return x && x.id && x.title; }) : [];
    } catch (e) {
      feed[surface] = []; if (!failedOnce) { failedOnce = true; try { console.info('[BMN Spotlight] not available (database migration not applied or offline).'); } catch (_) {} }
    }
  }
  function refresh() {
    if (inflight) return inflight;
    inflight = Promise.all([load('search'), load('profile')]).then(function () { lastFetch = Date.now(); mount('search'); mount('profile'); }).then(function () { inflight = null; }, function () { inflight = null; });
    return inflight;
  }

  /* ---------------------------------------------------------------- owner manager */
  var owner = null, root = null, items = [], view = 'list', editing = null, msg = null;
  function toLocal(iso) { if (!iso) return ''; var d = new Date(iso); if (isNaN(d)) return ''; var p = function (n) { return (n < 10 ? '0' : '') + n; }; return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' + p(d.getHours()) + ':' + p(d.getMinutes()); }
  function fromLocal(v) { if (!v) return null; var d = new Date(v); return isNaN(d) ? undefined : d.toISOString(); }
  function fmtWhen(iso) { if (!iso) return ''; var d = new Date(iso); return isNaN(d) ? '' : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }); }

  function build() {
    if (root) return; injectCss();
    root = document.createElement('div'); root.id = 'bmnSpMgr'; root.setAttribute('role', 'dialog'); root.setAttribute('aria-modal', 'true'); root.setAttribute('aria-label', 'BMN Spotlight manager');
    root.innerHTML = '<div class="sp-panel"><div class="sp-head"><h2 id="bmnSpTitle">Spotlight</h2><button type="button" data-sp="close" aria-label="Close Spotlight manager">Close</button></div><div class="sp-body" id="bmnSpBody"></div></div>';
    root.addEventListener('click', onClick);
    window.addEventListener('keydown', function (e) { if (e.key === 'Escape' && root.classList.contains('open')) closeMgr(); }, true);   // capture: the app has handlers that stop key events from bubbling
    document.body.appendChild(root);
  }
  function openMgr() { build(); root.classList.add('open'); document.documentElement.style.overflow = 'hidden'; view = 'list'; msg = null; loadList(); }
  function closeMgr() { if (!root) return; root.classList.remove('open'); document.documentElement.style.overflow = ''; }
  function body() { return document.getElementById('bmnSpBody'); }
  function setMsg(kind, text) { msg = text ? { kind: kind, text: text } : null; }
  function msgHtml() { return msg ? '<div class="' + (msg.kind === 'err' ? 'sp-err' : 'sp-ok') + '" role="status">' + esc(msg.text) + '</div>' : ''; }

  async function rpc(name, args) {
    var c = sb(); if (!c) throw new Error('Not connected. Reload the app.');
    var r = await c.rpc(name, args || {}); if (r.error) throw new Error(r.error.message || 'Request failed'); return r.data;
  }
  async function loadList() {
    document.getElementById('bmnSpTitle').textContent = 'Spotlight';
    body().innerHTML = '<div class="sp-empty">Loading…</div>';
    try { items = await rpc('bmn_spotlight_owner_list'); if (!Array.isArray(items)) items = []; renderList(); }
    catch (e) {
      body().innerHTML = '<div class="sp-err">' + esc(/does not exist|schema cache|Could not find/i.test(e.message) ? 'Spotlight is not installed in the database yet. Apply migration 003_bmn_spotlight first.' : e.message) + '</div>';
    }
  }
  function renderList() {
    var h = msgHtml() + '<div class="sp-acts" style="margin-bottom:12px"><button type="button" class="pri" data-sp="new">New Spotlight</button><button type="button" data-sp="audit">Audit log</button></div>';
    if (!items.length) h += '<div class="sp-empty">No Spotlight items yet. Nothing is shown to users until you create one and publish it.</div>';
    items.forEach(function (it) {
      var win = (it.starts_at || it.ends_at) ? (fmtWhen(it.starts_at) || 'now') + ' → ' + (fmtWhen(it.ends_at) || 'no end') : 'No schedule (shown while published)';
      h += '<div class="sp-row" data-id="' + esc(it.id) + '"><div><b>' + esc(it.title) + '</b><span class="sp-st st-' + esc(it.state) + '">' + esc(it.state) + '</span></div>' +
        '<div class="sp-meta">' + esc(KINDS[it.kind] || it.kind) + ' · ' + esc(win) + ' · ' + (it.show_in_search ? 'Discover' : '') + (it.show_in_search && it.show_on_profiles ? ' + ' : '') + (it.show_on_profiles ? 'Profiles' : '') + (!it.show_in_search && !it.show_on_profiles ? 'hidden everywhere' : '') + '</div><div class="sp-acts">' +
        '<button type="button" data-sp="edit" data-id="' + esc(it.id) + '">Edit</button>' +
        (it.status !== 'published' ? '<button type="button" class="pri" data-sp="status" data-s="published" data-id="' + esc(it.id) + '">Publish</button>' : '<button type="button" data-sp="status" data-s="paused" data-id="' + esc(it.id) + '">Pause</button>') +
        (it.status === 'published' ? '<button type="button" data-sp="status" data-s="draft" data-id="' + esc(it.id) + '">Unpublish</button>' : '') +
        '<button type="button" class="dng" data-sp="delete" data-id="' + esc(it.id) + '">Delete</button></div></div>';
    });
    body().innerHTML = h;
  }
  function opt(map, cur) { return Object.keys(map).map(function (k) { return '<option value="' + k + '"' + (k === cur ? ' selected' : '') + '>' + esc(typeof map[k] === 'string' && map[k][0] === '#' ? k : map[k]) + '</option>'; }).join(''); }
  function renderForm(it) {
    editing = it || null; var v = it || { kind: 'announcement', accent: 'gold', show_in_search: true, show_on_profiles: false, priority: 0 };
    document.getElementById('bmnSpTitle').textContent = it ? 'Edit Spotlight' : 'New Spotlight';
    body().innerHTML = msgHtml() +
      '<div id="bmnSpPrev"></div>' +
      '<label for="spKind">Type</label><select id="spKind">' + opt(KINDS, v.kind) + '</select>' +
      '<label for="spTitle">Title (required, max 80)</label><input type="text" id="spTitle" maxlength="80" value="' + esc(v.title || '') + '">' +
      '<label for="spSub">Subtitle (optional, max 160)</label><input type="text" id="spSub" maxlength="160" value="' + esc(v.subtitle || '') + '">' +
      '<label for="spEmoji">Emoji (optional)</label><input type="text" id="spEmoji" maxlength="8" value="' + esc(v.emoji || '') + '">' +
      '<label for="spAccent">Colour</label><select id="spAccent">' + opt(ACCENTS, v.accent) + '</select>' +
      '<label for="spLink">Link (optional): https://… or an in-app path like /discover</label><input type="text" id="spLink" maxlength="500" inputmode="url" autocapitalize="off" autocorrect="off" value="' + esc(v.link_url || '') + '">' +
      '<label for="spCta">Button text (optional, shown only when there is a link)</label><input type="text" id="spCta" maxlength="24" value="' + esc(v.cta_label || '') + '">' +
      '<label for="spStart">Starts (optional, your local time)</label><input type="datetime-local" id="spStart" value="' + esc(toLocal(v.starts_at)) + '">' +
      '<label for="spEnd">Ends (optional, your local time)</label><input type="datetime-local" id="spEnd" value="' + esc(toLocal(v.ends_at)) + '">' +
      '<label for="spCd">Countdown to (optional)</label><input type="datetime-local" id="spCd" value="' + esc(toLocal(v.countdown_to)) + '">' +
      '<label for="spCdl">Countdown label (optional, e.g. Starts in)</label><input type="text" id="spCdl" maxlength="40" value="' + esc(v.countdown_label || '') + '">' +
      '<label for="spPri">Priority (-100 to 100, higher shows first)</label><input type="number" id="spPri" min="-100" max="100" step="1" value="' + esc(v.priority || 0) + '">' +
      '<label class="sp-chk"><input type="checkbox" id="spInSearch"' + (v.show_in_search ? ' checked' : '') + '> Show on Discover (next to search)</label>' +
      '<label class="sp-chk"><input type="checkbox" id="spOnProf"' + (v.show_on_profiles ? ' checked' : '') + '> Show on profiles</label>' +
      '<div class="sp-hint">Saving keeps the current publish state. New items start as drafts and are invisible to users until you press Publish.</div>' +
      '<div class="sp-acts" style="margin-top:16px"><button type="button" class="pri" data-sp="save" id="spSave">Save</button><button type="button" data-sp="back">Cancel</button></div>';
    ['spKind', 'spTitle', 'spSub', 'spEmoji', 'spAccent', 'spLink', 'spCta', 'spCd', 'spCdl'].forEach(function (id) { var el = document.getElementById(id); el.addEventListener('input', preview); el.addEventListener('change', preview); });
    preview(); var t = document.getElementById('spTitle'); if (t) t.focus();
  }
  function val(id) { var el = document.getElementById(id); return el ? el.value : ''; }
  function preview() {
    var p = document.getElementById('bmnSpPrev'); if (!p) return;
    var it = { kind: val('spKind'), title: val('spTitle') || 'Title preview', subtitle: val('spSub'), emoji: val('spEmoji'), accent: val('spAccent'), link_url: val('spLink'), cta_label: val('spCta'), countdown_to: fromLocal(val('spCd')) || null, countdown_label: val('spCdl') };
    p.innerHTML = '<div class="sp-hint">Preview</div>' + cardHtml(it); startCountdowns();
  }
  function collect() {
    var s = fromLocal(val('spStart')), e = fromLocal(val('spEnd')), c = fromLocal(val('spCd'));
    if (s === undefined || e === undefined || c === undefined) throw new Error('One of the dates is not valid.');
    var title = val('spTitle').trim(); if (!title) throw new Error('A title is required.');
    var link = val('spLink').trim(); if (link && !safeLink(link)) throw new Error('The link must start with https:// or be an in-app path starting with a single "/".');
    if (s && e && Date.parse(e) <= Date.parse(s)) throw new Error('The end must be after the start.');
    var pr = parseInt(val('spPri') || '0', 10); if (isNaN(pr) || pr < -100 || pr > 100) throw new Error('Priority must be between -100 and 100.');
    return { kind: val('spKind'), title: title, subtitle: val('spSub').trim() || null, emoji: val('spEmoji').trim() || null, accent: val('spAccent'), link_url: link || null, cta_label: val('spCta').trim() || null,
      starts_at: s, ends_at: e, countdown_to: c, countdown_label: val('spCdl').trim() || null, priority: pr,
      show_in_search: document.getElementById('spInSearch').checked, show_on_profiles: document.getElementById('spOnProf').checked };
  }
  async function renderAudit() {
    document.getElementById('bmnSpTitle').textContent = 'Spotlight audit log'; body().innerHTML = '<div class="sp-empty">Loading…</div>';
    try {
      var rows = await rpc('bmn_spotlight_owner_audit', { p_limit: 100 });
      body().innerHTML = '<div class="sp-acts" style="margin-bottom:12px"><button type="button" data-sp="back">Back</button></div>' + (!rows || !rows.length ? '<div class="sp-empty">No changes recorded yet.</div>' :
        rows.map(function (a) { return '<div class="sp-row"><b>' + esc(String(a.action || '').replace(/_/g, ' ')) + '</b> — ' + esc((a.detail && a.detail.title) || '') + '<div class="sp-meta">' + esc(fmtWhen(a.at)) + '</div></div>'; }).join(''));
    } catch (e) { body().innerHTML = '<div class="sp-err">' + esc(e.message) + '</div>'; }
  }
  async function onClick(ev) {
    var b = ev.target.closest && ev.target.closest('[data-sp]'); if (!b) return;
    var a = b.getAttribute('data-sp'), id = b.getAttribute('data-id');
    if (a === 'close') return closeMgr();
    if (a === 'back') { setMsg(); return loadList(); }
    if (a === 'new') { setMsg(); return renderForm(null); }
    if (a === 'audit') return renderAudit();
    if (a === 'edit') { setMsg(); return renderForm(items.filter(function (x) { return x.id === id; })[0]); }
    b.disabled = true;
    try {
      if (a === 'save') {
        var data = collect(); var saved = await rpc('bmn_spotlight_owner_save', { p_id: editing ? editing.id : null, p_data: data });
        setMsg('ok', 'Saved' + (saved && saved.status === 'draft' ? ' as a draft. Press Publish when you are ready.' : '.')); await refresh(); return loadList();
      }
      if (a === 'status') { await rpc('bmn_spotlight_owner_set_status', { p_id: id, p_status: b.getAttribute('data-s') }); setMsg('ok', 'Updated.'); await refresh(); return loadList(); }
      if (a === 'delete') {
        var it = items.filter(function (x) { return x.id === id; })[0];
        if (!confirm('Delete "' + (it ? it.title : 'this item') + '" permanently? The audit log keeps a record.')) { b.disabled = false; return; }
        await rpc('bmn_spotlight_owner_delete', { p_id: id }); setMsg('ok', 'Deleted.'); await refresh(); return loadList();
      }
    } catch (e) { setMsg('err', e.message); b.disabled = false; if (a === 'save') { var keep = null; try { keep = collectLoose(); } catch (_) {} renderForm(keep ? Object.assign({}, editing || {}, keep) : editing); } else { renderList(); } }
  }
  function collectLoose() { return { kind: val('spKind'), title: val('spTitle'), subtitle: val('spSub'), emoji: val('spEmoji'), accent: val('spAccent'), link_url: val('spLink'), cta_label: val('spCta'), starts_at: fromLocal(val('spStart')) || null, ends_at: fromLocal(val('spEnd')) || null, countdown_to: fromLocal(val('spCd')) || null, countdown_label: val('spCdl'), priority: parseInt(val('spPri') || '0', 10) || 0, show_in_search: document.getElementById('spInSearch').checked, show_on_profiles: document.getElementById('spOnProf').checked }; }

  /* ---------------------------------------------------------------- owner entry point */
  async function checkOwner() {
    var uid = window.bmnSession && window.bmnSession.user && window.bmnSession.user.id;
    if (!uid || !sb()) { owner = null; var old = document.getElementById('bmnSpotOpen'); if (old) old.remove(); return; }
    if (!owner || owner.uid !== uid) {
      var ok = false;
      try { var r = await sb().rpc('is_bmn_owner'); var d = r && r.data; ok = !r.error && (d === true || (d && d.is_bmn_owner === true)); } catch (e) {}
      owner = { uid: uid, owner: ok };
    }
    if (owner.owner) addButton(); else { var o2 = document.getElementById('bmnSpotOpen'); if (o2) o2.remove(); }
  }
  function addButton() {
    var actions = document.querySelector('#lgttProfHead .lgtt-prof-actions'); if (!actions || actions.querySelector('#bmnSpotOpen')) return;
    injectCss();
    var b = document.createElement('button'); b.type = 'button'; b.id = 'bmnSpotOpen'; b.className = 'lgtt-btn lgtt-pill bmn-spot-open'; b.textContent = 'Spotlight'; b.setAttribute('aria-label', 'Open BMN Spotlight manager');
    b.addEventListener('click', openMgr); actions.appendChild(b);
  }
  function watchProfile(tries) {
    var head = document.getElementById('lgttProfHead');
    if (!head) { if (tries < 40) setTimeout(function () { watchProfile(tries + 1); }, 500); return; }
    var queued = false;
    new MutationObserver(function () { if (queued) return; queued = true; setTimeout(function () { queued = false; mount('profile'); checkOwner(); }, 120); }).observe(head, { childList: true });
    mount('profile'); checkOwner();
  }

  function init() {
    injectCss(); watchProfile(0);
    // window.bmnSupabase is created asynchronously by the app; wait for it (max ~20 s), then load the feed once.
    var n = 0, w = setInterval(function () { if (sb()) { clearInterval(w); refresh(); } else if (++n > 80) clearInterval(w); }, 250);
    var tries = 0; var t = setInterval(function () { checkOwner(); if (++tries > 20 || owner) clearInterval(t); }, 1500);   // wait for sign-in, then stop
    document.addEventListener('visibilitychange', function () { if (!document.hidden && Date.now() - lastFetch > 5 * 60 * 1000) refresh(); });
    setInterval(function () { if (!document.hidden && Date.now() - lastFetch > 10 * 60 * 1000) refresh(); }, 5 * 60 * 1000);
  }
  window.bmnOpenSpotlight = function () { if (owner && owner.owner) openMgr(); };
  window.__bmnSpotlight = { _refresh: refresh, _feed: feed, _cardHtml: cardHtml, _safeLink: safeLink };   // exposed for tests only; the database is the real gate
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
