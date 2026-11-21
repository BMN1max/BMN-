/* BMN Platform Intelligence — frontend (Batch 2).
   1) For signed-in users: a tiny privacy-preserving session beacon (POST /api/pi/session). The server stores keyed hashes only.
   2) For the BMN owner only: an "Intelligence" console (moderation queue, account risk, verification review, alerts, audit, controls).
   The owner check here only decides whether the button is SHOWN. Every API call is verified again on the server (owner-only), so
   editing this file or localStorage gives nobody access. No secrets live in this file. */
(function () {
  'use strict';
  if (window.__bmnIntelligenceLoaded) return; window.__bmnIntelligenceLoaded = true;

  var API = function () { return String(window.BMN_API_BASE_URL || window.BMN_R2_API_URL || '').replace(/\/+$/, ''); };
  var esc = function (v) { return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var store = { get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
                sget: function (k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }, sset: function (k, v) { try { sessionStorage.setItem(k, v); } catch (e) {} } };

  async function token() {
    try { var r = await window.bmnSupabase.auth.getSession(); return (r && r.data && r.data.session && r.data.session.access_token) || (window.bmnSession && window.bmnSession.access_token) || null; }
    catch (e) { return (window.bmnSession && window.bmnSession.access_token) || null; }
  }

  /* ---------------------------------------------------------------- session beacon */
  function deviceId() {
    var id = store.get('bmn_pi_dev');
    if (!id || !/^[A-Za-z0-9_-]{16,80}$/.test(id)) {
      var a = new Uint8Array(18); (window.crypto || {}).getRandomValues ? crypto.getRandomValues(a) : a.forEach(function (_, i) { a[i] = Math.floor(Math.random() * 256); });
      id = 'd' + Array.prototype.map.call(a, function (b) { return b.toString(16).padStart(2, '0'); }).join(''); store.set('bmn_pi_dev', id);
    }
    return id;
  }
  async function beacon() {
    try {
      if (!window.bmnSession || !API()) return;
      var last = Number(store.sget('bmn_pi_beacon') || 0); if (Date.now() - last < 30 * 60 * 1000) return;
      var t = await token(); if (!t) return; store.sset('bmn_pi_beacon', String(Date.now()));
      await fetch(API() + '/api/pi/session', { method: 'POST', headers: { Authorization: 'Bearer ' + t, 'X-BMN-Device': deviceId() }, keepalive: true });
    } catch (e) { /* never affects the app */ }
  }

  /* ---------------------------------------------------------------- API helper */
  async function api(method, path, body, query) {
    var t = await token(); if (!t) throw new Error('Sign in again.');
    var qs = query ? '?' + Object.keys(query).filter(function (k) { return query[k] != null; }).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(query[k]); }).join('&') : '';
    var res = await fetch(API() + '/api/pi/owner' + path + qs, { method: method, headers: Object.assign({ Authorization: 'Bearer ' + t }, body ? { 'Content-Type': 'application/json' } : {}), body: body ? JSON.stringify(body) : undefined, cache: 'no-store' });
    var j = await res.json().catch(function () { return {}; });
    if (!res.ok) throw new Error(j.error || 'Request failed (' + res.status + ').');
    return j.data;
  }

  /* ---------------------------------------------------------------- styles */
  var CSS = '#bmnPi{position:fixed;inset:0;z-index:2147483000;display:none;flex-direction:column;background:rgba(10,12,20,.94);-webkit-backdrop-filter:blur(22px) saturate(1.3);backdrop-filter:blur(22px) saturate(1.3);color:#eef1f8;font:15px/1.45 -apple-system,system-ui,sans-serif}#bmnPi.open{display:flex}' +
    '#bmnPi *{box-sizing:border-box}.pi-head{display:flex;align-items:center;gap:10px;padding:calc(env(safe-area-inset-top,0px) + 12px) 16px 8px}.pi-head h2{margin:0;font-size:19px;flex:1}.pi-x{border:0;background:rgba(255,255,255,.1);color:inherit;border-radius:12px;padding:8px 14px;font-size:15px}' +
    '.pi-tabs{display:flex;gap:6px;overflow-x:auto;padding:4px 16px 10px;-webkit-overflow-scrolling:touch}.pi-tabs button{flex:none;border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.06);color:inherit;border-radius:999px;padding:7px 13px;font-size:14px}.pi-tabs button[aria-selected=true]{background:rgba(111,166,255,.28);border-color:rgba(111,166,255,.6)}' +
    '.pi-body{flex:1;overflow-y:auto;padding:4px 16px calc(env(safe-area-inset-bottom,0px) + 28px);-webkit-overflow-scrolling:touch}.pi-card{border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.06);border-radius:16px;padding:12px 14px;margin:0 0 10px}.pi-card h3{margin:0 0 6px;font-size:15px}.pi-row{display:flex;gap:8px;align-items:center;justify-content:space-between;flex-wrap:wrap}' +
    '.pi-muted{opacity:.7;font-size:13px}.pi-pill{display:inline-block;border-radius:999px;padding:2px 9px;font-size:12px;background:rgba(255,255,255,.12);margin-right:4px}.pi-pill.high,.pi-pill.critical{background:rgba(255,92,92,.28)}.pi-pill.medium{background:rgba(255,190,70,.28)}.pi-pill.low,.pi-pill.on{background:rgba(80,200,140,.28)}' +
    '.pi-btn{border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.1);color:inherit;border-radius:12px;padding:8px 12px;font-size:14px;margin:6px 6px 0 0}.pi-btn.primary{background:rgba(111,166,255,.35);border-color:rgba(111,166,255,.7)}.pi-btn.danger{background:rgba(255,92,92,.22);border-color:rgba(255,92,92,.5)}.pi-btn:disabled{opacity:.5}' +
    '.pi-note{border-left:3px solid #6fa6ff;padding:8px 12px;background:rgba(111,166,255,.1);border-radius:8px;margin:0 0 12px;font-size:13px}.pi-err{color:#ff9a9a}.pi-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:8px}.pi-stat b{display:block;font-size:22px}' +
    '.pi-opener{margin-left:6px}' +
    /* The site hides every direct child of <body> except #lgtt while the community app is open (html.bmn-community-app body>:not(#lgtt){display:none!important}). Without this rule the console would be invisible. Higher specificity, so it wins. */
    'html.bmn-community-app body>#bmnPi.open{display:flex!important;visibility:visible!important;pointer-events:auto!important;opacity:1!important}';
  function injectCss() { if (document.getElementById('bmnPiCss')) return; var s = document.createElement('style'); s.id = 'bmnPiCss'; s.textContent = CSS; document.head.appendChild(s); }

  /* ---------------------------------------------------------------- UI */
  var TABS = [['overview', 'Overview'], ['cases', 'Moderation'], ['accounts', 'Accounts'], ['verification', 'Verification'], ['alerts', 'Alerts'], ['appeals', 'Appeals'], ['audit', 'Audit'], ['controls', 'Controls']];
  var root, bodyEl, current = 'overview';
  var fmt = function (d) { try { return new Date(d).toLocaleString(); } catch (e) { return ''; } };
  var pill = function (t, cls) { return '<span class="pi-pill ' + esc(cls || '') + '">' + esc(t) + '</span>'; };
  var human = function (s) { return esc(String(s || '').replace(/_/g, ' ')); };

  function build() {
    if (root) return; injectCss();
    root = document.createElement('div'); root.id = 'bmnPi'; root.setAttribute('role', 'dialog'); root.setAttribute('aria-modal', 'true'); root.setAttribute('aria-label', 'BMN Intelligence console');
    root.innerHTML = '<div class="pi-head"><h2>Intelligence</h2><button class="pi-x" type="button" data-pi-close>Close</button></div><div class="pi-tabs" role="tablist">' +
      TABS.map(function (t) { return '<button type="button" role="tab" data-pi-tab="' + t[0] + '" aria-selected="false">' + t[1] + '</button>'; }).join('') + '</div><div class="pi-body" id="bmnPiBody" aria-live="polite"></div>';
    document.body.appendChild(root); bodyEl = root.querySelector('#bmnPiBody');
    root.addEventListener('click', onClick);
    window.addEventListener('keydown', function (e) { if (e.key === 'Escape' && root.classList.contains('open')) close(); }, true);   // capture: the app has handlers that stop key events from bubbling
  }
  function open(tab) { build(); root.classList.add('open'); document.documentElement.style.overflow = 'hidden'; show(tab || current); }
  function close() { if (!root) return; root.classList.remove('open'); document.documentElement.style.overflow = ''; }
  async function show(tab) {
    current = tab; root.querySelectorAll('[data-pi-tab]').forEach(function (b) { b.setAttribute('aria-selected', b.dataset.piTab === tab ? 'true' : 'false'); });
    bodyEl.innerHTML = '<p class="pi-muted">Loading…</p>';
    try { bodyEl.innerHTML = await VIEWS[tab](); } catch (e) { bodyEl.innerHTML = '<p class="pi-err" role="alert">' + esc(e.message || 'Could not load.') + '</p><button class="pi-btn" data-pi-tab="' + tab + '">Try again</button>'; }
  }

  var SHADOW = '<div class="pi-note"><b>Safe mode.</b> Automation only <i>recommends</i>. It cannot ban or delete accounts, remove content permanently, or revoke verification: those always need your decision. Decisions are recorded in the audit log.</div>';
  var VIEWS = {
    async overview() {
      var o = await api('GET', '/overview'), h = await api('GET', '/health').catch(function () { return null; });
      var f = o.flags || {}, on = Object.keys(f).filter(function (k) { return f[k]; });
      return SHADOW + (o.halted ? '<div class="pi-note pi-err"><b>Emergency halt is ON.</b> All automation is stopped.</div>' : '') +
        '<div class="pi-grid"><div class="pi-card pi-stat"><b>' + esc((o.cases || {}).awaiting_review || 0) + '</b>cases waiting</div><div class="pi-card pi-stat"><b>' + esc((o.cases || {}).urgent || 0) + '</b>urgent</div><div class="pi-card pi-stat"><b>' + esc((o.accounts || {}).high_risk || 0) + '</b>high-risk accounts</div><div class="pi-card pi-stat"><b>' + esc((o.verification || {}).pending || 0) + '</b>verifications pending</div><div class="pi-card pi-stat"><b>' + esc(o.alerts_open || 0) + '</b>open alerts</div><div class="pi-card pi-stat"><b>' + esc((o.appeals || {}).pending || 0) + '</b>appeals pending</div></div>' +
        '<div class="pi-card"><h3>Automation</h3><p class="pi-muted">' + (on.length ? 'Switched on: ' + on.map(human).join(', ') : 'Everything is switched OFF. Nothing is being analysed.') + '</p><p class="pi-muted">Mode: ' + (o.enforcement_available ? 'enforcement available' : '<b>shadow</b> (decisions are recorded, nothing is applied automatically)') + '</p></div>' +
        '<div class="pi-card"><h3>System health</h3>' + (h ? '<p class="pi-muted">Workers active: ' + esc(h.workers_active) + ' · Dead jobs (24h): ' + esc(h.dead_jobs_24h) + ' · Oldest queued: ' + esc(h.oldest_queued_seconds) + 's</p>' : '<p class="pi-muted">Unavailable.</p>') +
        ((o.workers || []).map(function (w) { return '<p class="pi-muted">' + esc(w.worker_id) + ' · seen ' + esc(w.seen_seconds_ago) + 's ago · ok ' + esc(w.jobs_succeeded) + ' / failed ' + esc(w.jobs_failed) + '</p>'; }).join('')) + '</div>';
    },
    async cases() {
      var l = await api('GET', '/cases', null, { status: 'awaiting_review' });
      return SHADOW + (l.length ? l.map(function (c) { return '<div class="pi-card"><div class="pi-row"><h3>' + human(c.primary_category || 'review') + ' · ' + esc(c.subject_type) + '</h3><span>' + pill('P' + c.priority) + pill('risk ' + Math.round((c.risk_score || 0) * 100) + '%', c.risk_score >= .8 ? 'high' : c.risk_score >= .5 ? 'medium' : 'low') + '</span></div>' +
        '<p style="overflow-wrap:anywhere;margin:4px 0">' + esc(c.preview || '(no preview)') + '</p><p class="pi-muted">@' + esc(c.subject_username || '?') + ' · ' + esc(fmt(c.opened_at)) + ' · source ' + human(c.source) + '</p>' +
        '<button class="pi-btn" data-pi-case="' + esc(c.id) + '" data-r="no_violation">No violation</button><button class="pi-btn danger" data-pi-case="' + esc(c.id) + '" data-r="violation_confirmed">Confirm violation…</button><button class="pi-btn" data-pi-case="' + esc(c.id) + '" data-r="insufficient_information">Need more info</button></div>'; }).join('') : '<p class="pi-muted">No cases are waiting for review.</p>');
    },
    async accounts() {
      var a = await api('GET', '/accounts', null, { min_level: 'medium' }), inv = await api('GET', '/investigations', null, { status: 'open' }), r = await api('GET', '/restrictions', null, { active_only: 'true' });
      return SHADOW + '<h3>Accounts at risk</h3>' + (a.length ? a.map(function (x) { return '<div class="pi-card"><div class="pi-row"><h3>@' + esc(x.username || x.user_id) + '</h3>' + pill(x.risk_level, x.risk_level) + '</div><p class="pi-muted">' + esc(x.explanation || '') + '</p><p class="pi-muted">' + (x.reason_codes || []).map(human).join(', ') + ' · ' + esc(fmt(x.assessed_at)) + '</p></div>'; }).join('') : '<p class="pi-muted">No accounts at medium risk or above.</p>') +
        '<h3>Open investigations</h3>' + (inv.length ? inv.map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>@' + esc(x.username || '?') + '</b>' + pill(x.severity, x.severity) + '</div><p class="pi-muted">' + esc(x.summary || '') + '</p><button class="pi-btn" data-pi-inv="' + esc(x.id) + '" data-s="in_review">Mark in review</button><button class="pi-btn primary" data-pi-inv="' + esc(x.id) + '" data-s="closed">Close…</button></div>'; }).join('') : '<p class="pi-muted">None open.</p>') +
        '<h3>Active temporary restrictions</h3>' + (r.length ? r.map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>@' + esc(x.username || '?') + '</b>' + pill(x.mode) + '</div><p class="pi-muted">' + human(x.restriction_type) + ' · ' + human(x.reason_code) + ' · expires ' + esc(fmt(x.expires_at)) + (x.mode === 'shadow' ? ' · <b>recorded only, not applied</b>' : '') + '</p><button class="pi-btn" data-pi-lift="' + esc(x.id) + '">Lift now…</button></div>'; }).join('') : '<p class="pi-muted">None.</p>');
    },
    async verification() {
      var v = await api('GET', '/verification');
      var pend = (v.pending || []).map(function (x) { var ev = x.evaluation || {}; var sd = x.system_decision || {};
        return '<div class="pi-card"><div class="pi-row"><h3>@' + esc(x.username || x.user_id) + '</h3>' + pill(ev.outcome ? String(ev.outcome).replace(/_/g, ' ') : 'not evaluated') + '</div><p style="overflow-wrap:anywhere">' + esc(x.request_reason || '') + '</p>' +
          (x.evidence_url ? '<p class="pi-muted" style="overflow-wrap:anywhere">Evidence: ' + esc(x.evidence_url) + '</p>' : '') + (sd.reason ? '<p class="pi-muted">' + esc(sd.reason) + '</p>' : '') +
          (Array.isArray(ev.checks) ? '<p class="pi-muted">' + ev.checks.map(function (c) { return (c.result === 'pass' ? '✓ ' : '✗ ') + String(c.check || '').replace(/_/g, ' '); }).join(' · ') + '</p>' : '') +
          '<button class="pi-btn primary" data-pi-ver="' + esc(x.request_id) + '" data-d="approved">Approve…</button><button class="pi-btn danger" data-pi-ver="' + esc(x.request_id) + '" data-d="rejected">Reject…</button><button class="pi-btn" data-pi-eval="' + esc(x.request_id) + '">Re-run checks</button></div>'; }).join('');
      var rec = (v.recent_decisions || []).slice(0, 10).map(function (d) { return '<p class="pi-muted">' + esc(fmt(d.created_at)) + ' · ' + esc(d.decision) + ' · ' + esc(d.decided_by_type) + ' · ' + esc(d.reason) + '</p>'; }).join('');
      return '<div class="pi-note">Automation can only approve when <b>every</b> required check passes and you have switched automatic approval on. It never rejects or revokes. Anything uncertain lands here.</div><h3>Waiting for you</h3>' + (pend || '<p class="pi-muted">No pending requests.</p>') + '<h3>Recent decisions</h3>' + (rec || '<p class="pi-muted">None yet.</p>');
    },
    async alerts() {
      var a = await api('GET', '/alerts'), e = await api('GET', '/events', null, { only_open: 'true' });
      return '<h3>System alerts</h3>' + (a.length ? a.map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>' + human(x.kind) + '</b>' + pill(x.severity, x.severity) + '</div><p>' + esc(x.message) + '</p><p class="pi-muted">' + esc(fmt(x.last_seen_at)) + (x.occurrences > 1 ? ' · seen ' + esc(x.occurrences) + '×' : '') + '</p>' + (x.acknowledged_at ? '' : '<button class="pi-btn" data-pi-ack-alert="' + esc(x.id) + '">Acknowledge</button>') + '</div>'; }).join('') : '<p class="pi-muted">No open alerts.</p>') +
        '<h3>Security events</h3>' + (e.length ? e.map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>' + human(x.event_type) + ' · @' + esc(x.username || '?') + '</b>' + pill(x.severity, x.severity) + '</div><p class="pi-muted">' + esc(fmt(x.occurred_at)) + '</p><button class="pi-btn" data-pi-ack-event="' + esc(x.id) + '">Acknowledge</button></div>'; }).join('') : '<p class="pi-muted">No unacknowledged events.</p>');
    },
    async appeals() {
      var a = await api('GET', '/appeals', null, { status: 'pending' });
      return a.length ? a.map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>@' + esc(x.username || '?') + '</b>' + pill(x.status) + '</div><p style="overflow-wrap:anywhere">' + esc(x.statement || '') + '</p><p class="pi-muted">Action: ' + human((x.action || {}).action_type) + ' · ' + esc(fmt(x.created_at)) + '</p><button class="pi-btn primary" data-pi-appeal="' + esc(x.id) + '" data-d="overturned">Overturn…</button><button class="pi-btn" data-pi-appeal="' + esc(x.id) + '" data-d="upheld">Uphold…</button></div>'; }).join('') : '<p class="pi-muted">No pending appeals.</p>';
    },
    async audit() {
      var a = await api('GET', '/audit', null, { limit: 100 });
      return a.length ? a.map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>' + human(x.action) + '</b><span class="pi-muted">' + esc(fmt(x.occurred_at)) + '</span></div><p class="pi-muted">' + esc(x.actor_type) + ' · ' + esc(x.target_type) + ' ' + esc(String(x.target_id || '').slice(0, 40)) + '</p>' + (x.reason ? '<p style="overflow-wrap:anywhere">' + esc(x.reason) + '</p>' : '') + '</div>'; }).join('') : '<p class="pi-muted">Nothing recorded yet.</p>';
    },
    async controls() {
      var p = await api('GET', '/policy'), flags = p.flags || [];
      return SHADOW + '<h3>Feature switches</h3><p class="pi-muted">Everything starts OFF. Switch on one step at a time and watch the Overview and Audit tabs.</p>' +
        flags.map(function (f) { return '<div class="pi-card"><div class="pi-row"><b>' + human(f.key) + '</b>' + pill(f.enabled ? 'ON' : 'off', f.enabled ? 'on' : '') + '</div><p class="pi-muted">' + esc(f.description || '') + '</p><button class="pi-btn ' + (f.enabled ? 'danger' : 'primary') + '" data-pi-flag="' + esc(f.key) + '" data-on="' + (f.enabled ? '0' : '1') + '">' + (f.enabled ? 'Switch off…' : 'Switch on…') + '</button></div>'; }).join('') +
        '<h3>Category policies</h3>' + (p.policies || []).map(function (x) { return '<div class="pi-card"><div class="pi-row"><b>' + human(x.category) + '</b>' + pill(x.enabled ? 'enabled' : 'off', x.enabled ? 'on' : '') + '</div><p class="pi-muted">Review at ' + esc(x.review_threshold == null ? '—' : x.review_threshold) + ' · auto at ' + esc(x.auto_action_threshold == null ? '—' : x.auto_action_threshold) + ' · max automatic action: ' + human(x.max_auto_action) + (x.always_human_review ? ' · always human review' : '') + ' · v' + esc(x.version) + '</p><button class="pi-btn" data-pi-pol="' + esc(x.category) + '" data-en="' + (x.enabled ? '0' : '1') + '">' + (x.enabled ? 'Disable…' : 'Enable with defaults…') + '</button></div>'; }).join('') +
        '<h3>Rule sets</h3><p class="pi-muted">Published versions: ' + ((p.rule_sets || []).map(function (r) { return esc(r.rule_key) + ' v' + esc(r.version) + (r.status === 'active' ? ' (active)' : ''); }).join(', ') || 'none — built-in version 1 is in use') + '. Thresholds and limits are published through the API (see README) so every version is kept for the audit trail.</p>';
    }
  };

  function note(msg, required) { var n = prompt(msg); if (n === null) return null; n = n.trim(); if (required && !n) { alert('A note is required.'); return null; } return n; }
  async function act(btn, fn) { btn.disabled = true; try { await fn(); await show(current); } catch (e) { alert(e.message || 'Failed.'); btn.disabled = false; } }

  function onClick(e) {
    var b = e.target.closest('button'); if (!b) return;
    if (b.hasAttribute('data-pi-close')) return close();
    if (b.dataset.piTab) return show(b.dataset.piTab);
    var d = b.dataset;
    if (d.piCase) { var viol = d.r === 'violation_confirmed', n = note(viol ? 'Decision note (required):' : 'Note (required):', true); if (!n) return;
      var body = { resolution: d.r, note: n, action_type: 'no_action' };
      if (viol) { var w = confirm('Send the user a warning that explains the decision?\nOK = warn the user, Cancel = record the decision without a warning.'); if (w) { var why = note('What reason should the user be shown?', true); if (!why) return; body.action_type = 'warn'; body.user_visible_reason = why; } }
      return act(b, function () { return api('POST', '/cases/' + d.piCase + '/resolve', body); }); }
    if (d.piInv) { var n2 = note('Note (required):', true); if (!n2) return; var res = d.s === 'closed' ? note('Resolution (optional):', false) : null; return act(b, function () { return api('POST', '/investigations/' + d.piInv, { status: d.s, note: n2, resolution: res || undefined }); }); }
    if (d.piLift) { var n3 = note('Why are you lifting this restriction?', true); if (!n3) return; return act(b, function () { return api('POST', '/restrictions/' + d.piLift + '/lift', { reason: n3 }); }); }
    if (d.piVer) { var n4 = note((d.d === 'approved' ? 'Approval' : 'Rejection') + ' note (required; the creator may see it):', true); if (!n4) return; return act(b, function () { return api('POST', '/verification/' + d.piVer + '/decide', { decision: d.d, note: n4 }); }); }
    if (d.piEval) return act(b, function () { return api('POST', '/verification/' + d.piEval + '/evaluate'); });
    if (d.piAckAlert) return act(b, function () { return api('POST', '/alerts/' + d.piAckAlert + '/ack'); });
    if (d.piAckEvent) return act(b, function () { return api('POST', '/events/' + d.piAckEvent + '/ack'); });
    if (d.piAppeal) { var n5 = note('Decision note (required):', true); if (!n5) return; return act(b, function () { return api('POST', '/appeals/' + d.piAppeal + '/decide', { decision: d.d, note: n5 }); }); }
    if (d.piFlag) { var on = d.on === '1'; if (!confirm((on ? 'Switch ON ' : 'Switch OFF ') + d.piFlag.replace(/_/g, ' ') + '?\n\nThis is recorded in the audit log.')) return; var r = note('Reason (required):', true); if (!r) return;
      return act(b, function () { return api('POST', '/flags/' + d.piFlag, { enabled: on, reason: r }); }); }
    if (d.piPol) { var en = d.en === '1'; var r2 = note('Reason (required):', true); if (!r2) return;
      var payload = en ? { enabled: true, review_threshold: 0.6, auto_action_threshold: 0.85, max_auto_action: 'flag', reason: r2 } : { enabled: false, reason: r2 };
      return act(b, function () { return api('POST', '/policy/' + d.piPol, payload); }); }
  }

  /* ---------------------------------------------------------------- owner entry points */
  var ownerKnown = null, ownerChecked = 0;
  async function checkOwner() {
    var uid = window.bmnSession && window.bmnSession.user && window.bmnSession.user.id;
    if (!uid || !window.bmnSupabase) { ownerKnown = null; removeButton(); return; }
    if (ownerKnown && ownerKnown.uid === uid) { if (ownerKnown.owner) addButton(); return; }
    if (Date.now() - ownerChecked < 4000) return; ownerChecked = Date.now();
    var isOwner = false;
    try { var r = await window.bmnSupabase.rpc('is_bmn_owner'); var dta = r && r.data; isOwner = !r.error && (dta === true || (dta && dta.is_bmn_owner === true)); } catch (e) {}
    ownerKnown = { uid: uid, owner: isOwner }; if (isOwner) addButton(); else removeButton();
  }
  function addButton() {
    var actions = document.querySelector('#lgttProfHead .lgtt-prof-actions'); if (!actions || actions.querySelector('#bmnPiOpen')) return;
    var b = document.createElement('button'); b.type = 'button'; b.id = 'bmnPiOpen'; b.className = 'lgtt-btn lgtt-pill pi-opener'; b.textContent = 'Intelligence'; b.setAttribute('aria-label', 'Open BMN Intelligence console');
    b.addEventListener('click', function () { open('overview'); }); actions.appendChild(b);
  }
  function removeButton() { var b = document.getElementById('bmnPiOpen'); if (b) b.remove(); if (root) close(); }

  window.bmnOpenIntelligence = function () { if (ownerKnown && ownerKnown.owner) open('overview'); };
  function tick() { beacon(); checkOwner(); }
  setInterval(tick, 3000); setTimeout(tick, 400); window.addEventListener('load', function () { setTimeout(tick, 800); });
  window.__bmnIntelligence = { _views: VIEWS, _api: api };   // exposed for tests only; the server is the real gate
})();
