// Injected before the page scripts: replaces the CDN supabase-js with a thin client that talks to dbserver.js.
(function () {
  const API = 'http://localhost:8130';
  const uid = window.__MOCK_UID;
  const post = async (path, body) => { const r = await fetch(API + path, { method: 'POST', body: JSON.stringify(body) }); return r.json(); };
  const user = uid ? { id: uid, email: uid.slice(0, 4) + '@test.local' } : null;
  const session = user ? { user, access_token: 'test-token' } : null;
  window.__mockStats = { queries: 0, rpcs: 0 };
  function builder(table) {
    const q = { table, op: 'select', select: '*', filters: [], orders: [] };
    const b = new Proxy({}, { get(_, k) {
      if (k === 'then') return (res, rej) => { window.__mockStats.queries++; return post('/query', { q, uid }).then(res, rej); };
      return (...a) => {
        switch (k) {
          case 'select': if (q.op === 'select') q.select = a[0] || '*'; else q.select = a[0] || '*'; break;
          case 'insert': q.op = 'insert'; q.values = a[0]; q.select = null; break;
          case 'update': q.op = 'update'; q.values = a[0]; break;
          case 'delete': q.op = 'delete'; break;
          case 'eq': case 'neq': case 'lt': case 'lte': case 'gt': case 'gte': q.filters.push({ k, col: a[0], v: a[1] }); break;
          case 'is': q.filters.push({ k: 'is', col: a[0], v: a[1] }); break;
          case 'in': q.filters.push({ k: 'in', col: a[0], v: a[1] }); break;
          case 'ilike': q.filters.push({ k: 'ilike', col: a[0], v: a[1] }); break;
          case 'or': q.filters.push({ k: 'or', v: a[0] }); break;
          case 'order': q.orders.push({ col: a[0], asc: !(a[1] && a[1].ascending === false) }); break;
          case 'limit': q.limit = a[0]; break;
          case 'single': case 'maybeSingle': q.single = true; break;
        }
        return b;
      };
    } });
    return b;
  }
  const channels = [];
  let since = 0, started = false;
  async function pump() {
    try {
      const r = await post('/events', { since }); if (r.seq != null && !started) { started = true; }
      (r.events || []).forEach(ev => { since = Math.max(since, ev.n); channels.forEach(ch => ch.handlers.forEach(h => {
        if (h.cfg.table !== ev.table) return;
        const m = /^(\w+)=eq\.(.+)$/.exec(h.cfg.filter || ''); if (m && String(ev.new[m[1]]) !== m[2]) return;
        // RLS applies to realtime too: only participants receive the row
        if (ev.table === 'messages' && ev.new.sender_id !== uid && ev.new.recipient_id !== uid) return;
        try { h.cb({ eventType: ev.eventType, new: ev.new, schema: 'public', table: ev.table }); } catch (e) { console.error('rt handler', e); }
      })); });
      if (r.seq != null && !r.rt && !since) {}
    } catch (e) {}
  }
  (async () => { const r = await post('/events', { since: 0 }); since = r.seq || 0; setInterval(pump, 250); })();
  const client = {
    __mock: true,
    auth: {
      getSession: async () => ({ data: { session }, error: null }),
      getUser: async () => (user ? { data: { user }, error: null } : { data: { user: null }, error: { status: 401, message: 'Auth session missing' } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: async () => ({ error: null }), signInWithPassword: async () => ({ error: { message: 'mock' } }), signUp: async () => ({ error: { message: 'mock' } })
    },
    from: builder,
    rpc: (name, args) => { window.__mockStats.rpcs++; return post('/rpc', { name, args, uid }); },
    channel(name) {
      const ch = { name, handlers: [], on(type, cfg, cb) { ch.handlers.push({ cfg, cb }); return ch; }, subscribe(cb) { channels.push(ch); cb && setTimeout(() => cb('SUBSCRIBED'), 0); return ch; }, unsubscribe() { const i = channels.indexOf(ch); if (i >= 0) channels.splice(i, 1); } };
      return ch;
    },
    removeChannel(ch) { ch && ch.unsubscribe && ch.unsubscribe(); },
    storage: { from: (bucket) => ({
      upload: async (path, blob) => { const r = await post('/upload', { path, size: blob.size }); return r.error ? r : { data: r.data, error: null }; },
      createSignedUrls: async (paths) => ({ data: paths.map(p => ({ path: p, signedUrl: API + '/img/' + encodeURIComponent(p) })), error: null }),
      createSignedUrl: async (p) => ({ data: { signedUrl: API + '/img/' + encodeURIComponent(p) }, error: null }),
      getPublicUrl: (p) => ({ data: { publicUrl: API + '/img/' + encodeURIComponent(p) } }),
      remove: async (paths) => post('/remove', { paths })
    }) }
  };
  window.supabase = { createClient: () => client };
})();
