// In-memory Supabase stand-in with RLS emulation for the `messages` table. TEST FIXTURE ONLY (never shipped).
const http = require('http');
const crypto = require('crypto');
const U = { A: 'aaaaaaaa-0000-4000-8000-000000000001', B: 'bbbbbbbb-0000-4000-8000-000000000002', C: 'cccccccc-0000-4000-8000-000000000003', D: 'dddddddd-0000-4000-8000-000000000004' };
function fresh() {
  return {
    tables: {
      profiles: [
        { id: U.A, username: 'alice_test', display_name: 'Alice Test' }, { id: U.B, username: 'bob_test', display_name: 'Bob Test' },
        { id: U.C, username: 'cara_test', display_name: 'Cara Test' }, { id: U.D, username: 'dan_test', display_name: 'Dan Founder', is_founder: true }],
      messages: [], notifications: [], follows: [{ follower_id: U.A, following_id: U.B }]
    },
    events: [], seq: 0, flags: { rt: true, failInsert: false, rpcInbox: false, latency: 0, markReadRpc: true, offline: false }, storage: {}, log: []
  };
}
let DB = fresh();
const now = () => new Date().toISOString();
const SELF_COLS = new Set();
function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
function parseTerm(t) { const m = /^([a-z_]+)\.([a-z]+)\.(.*)$/.exec(t); return m ? { col: m[1], op: m[2], val: m[3] } : null; }
function splitTop(s) { const out = []; let d = 0, cur = ''; for (const ch of s) { if (ch === '(') d++; if (ch === ')') d--; if (ch === ',' && d === 0) { out.push(cur); cur = ''; } else cur += ch; } if (cur) out.push(cur); return out; }
function evalTerm(row, f) {
  const v = row[f.col];
  switch (f.op) {
    case 'eq': return String(v) === f.val;
    case 'neq': return String(v) !== f.val;
    case 'is': return f.val === 'null' ? v == null : v === (f.val === 'true');
    case 'lt': return v < f.val; case 'lte': return v <= f.val; case 'gt': return v > f.val; case 'gte': return v >= f.val;
    case 'ilike': { const re = new RegExp('^' + f.val.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*') + '$', 'i'); return re.test(String(v == null ? '' : v)); }
    case 'in': return f.val.replace(/^\(|\)$/g, '').split(',').map(x => x.replace(/^"|"$/g, '')).includes(String(v));
    default: return true;
  }
}
function evalOr(row, str) {
  return splitTop(str).some(term => {
    const m = /^and\((.*)\)$/.exec(term);
    if (m) return splitTop(m[1]).every(t => { const f = parseTerm(t); return f ? evalTerm(row, f) : true; });
    const f = parseTerm(term); return f ? evalTerm(row, f) : false;
  });
}
function applyFilters(rows, filters) {
  return rows.filter(r => filters.every(f => {
    if (f.k === 'or') return evalOr(r, f.v);
    if (f.k === 'in') return f.v.map(String).includes(String(r[f.col]));
    if (f.k === 'is') return f.v === null ? r[f.col] == null : r[f.col] === f.v;
    if (f.k === 'ilike') return evalTerm(r, { col: f.col, op: 'ilike', val: f.v });
    return evalTerm(r, { col: f.col, op: f.k, val: String(f.v) });
  }));
}
// RLS emulation for messages: SELECT = participant && not soft-deleted for me; INSERT = sender is me; UPDATE/DELETE = no policy (0 rows)
function rlsVisible(table, rows, uid) {
  if (table !== 'messages') return rows;
  return rows.filter(m => (m.sender_id === uid && !m.deleted_by_sender) || (m.recipient_id === uid && !m.deleted_by_recipient));
}
function emit(table, eventType, row) { DB.events.push({ n: ++DB.seq, table, eventType, new: row }); }
function pick(row, cols) { if (!cols || cols === '*') return row; const o = {}; cols.split(',').map(s => s.trim()).forEach(c => { o[c] = row[c]; }); return o; }
const KNOWN_MSG_COLS = ['id', 'sender_id', 'recipient_id', 'content', 'created_at', 'read_at', 'deleted_by_sender', 'deleted_by_recipient'];
function execQuery(q, uid) {
  const t = DB.tables[q.table] || (DB.tables[q.table] = []);
  if (DB.flags.offline) return { error: { message: 'Failed to fetch' } };
  if (q.table === 'messages' && q.select && q.select !== '*') {
    for (const c of q.select.split(',').map(s => s.trim())) if (!KNOWN_MSG_COLS.includes(c)) return { error: { message: 'column messages.' + c + ' does not exist', code: '42703' } };
  }
  if (q.op === 'select') {
    let rows = applyFilters(rlsVisible(q.table, t, uid), q.filters);
    (q.orders || []).slice().reverse().forEach(o => { rows = rows.slice().sort((a, b) => (o.asc ? 1 : -1) * (cmp(a[o.col], b[o.col]) || cmp(a.id, b.id))); });
    if (q.limit != null) rows = rows.slice(0, q.limit);
    rows = rows.map(r => pick(r, q.select));
    if (q.single) return rows.length === 1 ? { data: rows[0] } : { error: { message: 'JSON object requested, multiple (or no) rows returned', code: 'PGRST116' } };
    return { data: rows };
  }
  if (q.op === 'insert') {
    const objs = Array.isArray(q.values) ? q.values : [q.values]; const made = [];
    for (const o of objs) {
      if (q.table === 'messages') {
        if (DB.flags.failInsert) return { error: { message: 'Failed to fetch' } };
        if (o.sender_id !== uid) return { error: { code: '42501', message: 'new row violates row-level security policy for table "messages"' } };
        if (!DB.tables.profiles.some(p => p.id === o.recipient_id)) return { error: { code: '23503', message: 'insert or update on table "messages" violates foreign key constraint' } };
        if (!o.content || !String(o.content).trim()) return { error: { code: '23514', message: 'violates check constraint' } };
      }
      const row = Object.assign({ id: crypto.randomUUID(), created_at: now() }, q.table === 'messages' ? { read_at: null, deleted_by_sender: false, deleted_by_recipient: false } : {}, o);
      t.push(row); made.push(row); emit(q.table, 'INSERT', row);
    }
    if (!q.select) return { data: null };
    const rows = made.map(r => pick(r, q.select));
    return q.single ? { data: rows[0] } : { data: rows };
  }
  if (q.op === 'update') {
    if (q.table === 'messages') { DB.log.push('direct UPDATE on messages blocked by RLS (0 rows)'); return { data: q.select ? [] : null }; }
    const rows = applyFilters(t, q.filters); rows.forEach(r => Object.assign(r, q.values)); return { data: null };
  }
  if (q.op === 'delete') { if (q.table === 'messages') return { data: null }; DB.tables[q.table] = t.filter(r => !applyFilters([r], q.filters).length); return { data: null }; }
  return { data: null };
}
function rpc(name, args, uid) {
  if (DB.flags.offline) return { error: { message: 'Failed to fetch' } };
  if (name === 'bmn_mark_messages_read') {
    if (!DB.flags.markReadRpc) return { error: { code: '42883', message: 'function bmn_mark_messages_read does not exist' } };
    let n = 0; DB.tables.messages.forEach(m => { if (m.recipient_id === uid && m.sender_id === args.p_sender_id && !m.read_at) { m.read_at = now(); n++; emit('messages', 'UPDATE', m); } });
    DB.log.push('mark_read by ' + uid.slice(0,4) + ' of ' + String(args.p_sender_id).slice(0,4) + ' n=' + n + ' @' + Date.now()%100000);
    return { data: n };
  }
  if (name === 'bmn_clear_conversation') {
    if (args.p_peer === uid) return { error: { code: 'P0001', message: 'Cannot clear a conversation with yourself' } };
    DB.tables.messages.forEach(m => {
      if (m.sender_id === uid && m.recipient_id === args.p_peer) { m.deleted_by_sender = true; emit('messages', 'UPDATE', m); }
      if (m.recipient_id === uid && m.sender_id === args.p_peer) { m.deleted_by_recipient = true; emit('messages', 'UPDATE', m); }
    });
    return { data: null };
  }
  if (name === 'bmn_inbox_conversations') {
    if (!DB.flags.rpcInbox) return { error: { code: 'PGRST202', message: 'Could not find the function public.bmn_inbox_conversations' } };
    const vis = rlsVisible('messages', DB.tables.messages, uid).sort((a, b) => cmp(b.created_at, a.created_at)); const m = new Map();
    vis.forEach(x => { const peer = x.sender_id === uid ? x.recipient_id : x.sender_id; if (!m.has(peer)) m.set(peer, { peer_id: peer, last_message_id: x.id, last_content: x.content, last_sender_id: x.sender_id, last_created_at: x.created_at, unread_count: 0 }); if (x.recipient_id === uid && x.sender_id !== uid && !x.read_at) m.get(peer).unread_count++; });
    return { data: [...m.values()] };
  }
  return { error: { message: 'unknown rpc ' + name } };
}
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><defs><linearGradient id="g"><stop offset="0" stop-color="#f90"/><stop offset="1" stop-color="#09f"/></linearGradient></defs><rect width="300" height="200" fill="url(#g)"/></svg>';
http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', '*'); res.setHeader('Access-Control-Allow-Methods', '*');
  if (req.method === 'OPTIONS') { res.end(); return; }
  const url = new URL(req.url, 'http://x');
  if (url.pathname.startsWith('/img/')) { res.setHeader('content-type', 'image/svg+xml'); res.end(svg); return; }
  let body = ''; req.on('data', c => body += c); req.on('end', () => {
    const reply = o => { res.setHeader('content-type', 'application/json'); setTimeout(() => res.end(JSON.stringify(o)), DB.flags.latency); };
    const j = body ? JSON.parse(body) : {};
    if (url.pathname === '/reset') { DB = fresh(); return reply({ ok: true, U }); }
    if (url.pathname === '/flags') { Object.assign(DB.flags, j); return reply(DB.flags); }
    if (url.pathname === '/state') return reply({ tables: DB.tables, log: DB.log, storage: Object.keys(DB.storage), flags: DB.flags });
    if (url.pathname === '/seed') { (j.messages || []).forEach(m => DB.tables.messages.push(Object.assign({ id: crypto.randomUUID(), created_at: now(), read_at: null, deleted_by_sender: false, deleted_by_recipient: false }, m))); return reply({ n: DB.tables.messages.length }); }
    if (url.pathname === '/query') return reply(execQuery(j.q, j.uid));
    if (url.pathname === '/rpc') return reply(rpc(j.name, j.args || {}, j.uid));
    if (url.pathname === '/events') { if (!DB.flags.rt) return reply({ events: [], seq: DB.seq, rt: false }); return reply({ events: DB.events.filter(e => e.n > j.since), seq: DB.seq, rt: true }); }
    if (url.pathname === '/upload') { DB.storage[j.path] = j.size; return reply({ data: { path: j.path } }); }
    if (url.pathname === '/remove') { (j.paths || []).forEach(p => delete DB.storage[p]); return reply({ data: [] }); }
    res.statusCode = 404; reply({ error: 'nf' });
  });
}).listen(8130, () => console.log('db up'));
