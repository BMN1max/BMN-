// TEST FIXTURE ONLY (never shipped). A tiny PostgREST-like HTTP server in front of a THROWAWAY local PostgreSQL that has the
// baseline + production overlay + migrations M0-M3 applied. Every request runs as role `authenticated` with the caller's uid, so the
// REAL row-level security and SECURITY DEFINER functions decide the outcome (not a hand-written imitation).
// env: PGHOST=/tmp/pgt PGPORT=5499 PGDATABASE=bmn_t PORT=8130
const http = require('http'), cp = require('child_process'), crypto = require('crypto');
const PGHOST = process.env.PGHOST || '/tmp/pgt', PGPORT = process.env.PGPORT || '5499', PGDB = process.env.PGDATABASE || 'bmn_t', PORT = +(process.env.PORT || 8130);
const U = { A: 'aaaaaaaa-0000-4000-8000-000000000001', B: 'bbbbbbbb-0000-4000-8000-000000000002', C: 'cccccccc-0000-4000-8000-000000000003', D: 'dddddddd-0000-4000-8000-000000000004' };
const lit = v => v === null || v === undefined ? 'NULL' : typeof v === 'boolean' ? String(v) : typeof v === 'number' ? String(v) : Array.isArray(v) ? "'{" + v.map(x => '"' + String(x).replace(/(["\\])/g, '\\$1') + '"').join(',') + "}'" : typeof v === 'object' ? "'" + JSON.stringify(v).replace(/'/g, "''") + "'::jsonb" : "'" + String(v).replace(/'/g, "''") + "'";
const id = s => { if (!/^[a-z_][a-z0-9_]*$/i.test(s)) throw new Error('bad ident ' + s); return '"' + s + '"'; };
function psql(sql, asUid) {
  const pre = asUid ? `SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${asUid}',true), set_config('request.jwt.claim.role','authenticated',true);` : `SELECT set_config('request.jwt.claim.role','service_role',true);`;
  const script = `\\set VERBOSITY verbose\n\\set ON_ERROR_STOP 1\nBEGIN;\n${pre}\n\\echo @@BEGIN\n${sql};\n\\echo @@END\nCOMMIT;\n`;
  const r = cp.spawnSync('psql', ['-h', PGHOST, '-p', PGPORT, '-U', 'postgres', '-d', PGDB, '-X', '-q', '-At'], { input: script, encoding: 'utf8', maxBuffer: 64e6 });
  const out = r.stdout || '', a = out.indexOf('@@BEGIN\n'), b = out.indexOf('\n@@END');
  if (a >= 0 && b > a && !/ERROR/.test(r.stderr || '')) return { ok: out.slice(a + 8, b).split('\n').filter(l => l && !/^SET$|^COMMIT$/.test(l)).pop() };
  const m = /ERROR:\s+([0-9A-Z]{5}):\s+(.*)/.exec(r.stderr || '') || [];
  let code = m[1] || 'XX000', msg = (m[2] || r.stderr || 'error').trim();
  if (code === '42883' && /function/.test(msg)) code = 'PGRST202';
  return { error: { code, message: msg } };
}
function terms(str) { // PostgREST or=(...) with and(...) groups
  const split = s => { const o = []; let d = 0, c = ''; for (const ch of s) { if (ch === '(') d++; if (ch === ')') d--; if (ch === ',' && !d) { o.push(c); c = ''; } else c += ch; } if (c) o.push(c); return o; };
  const one = t => { const m = /^([a-z_]+)\.([a-z]+)\.(.*)$/.exec(t); return cond(m[1], m[2], m[3]); };
  return split(str).map(t => { const m = /^and\((.*)\)$/.exec(t); return m ? '(' + split(m[1]).map(one).join(' AND ') + ')' : one(t); }).join(' OR ');
}
function cond(col, op, val) {
  const c = id(col);
  switch (op) {
    case 'eq': return `${c}::text = ${lit(String(val))}`; case 'neq': return `${c}::text <> ${lit(String(val))}`;
    case 'lt': return `${c} < ${lit(val)}`; case 'lte': return `${c} <= ${lit(val)}`; case 'gt': return `${c} > ${lit(val)}`; case 'gte': return `${c} >= ${lit(val)}`;
    case 'is': return val === 'null' || val === null ? `${c} IS NULL` : `${c} IS ${val}`;
    case 'ilike': return `${c}::text ILIKE ${lit(val)}`;
    case 'in': return `${c}::text IN (${val.replace(/^\(|\)$/g, '').split(',').map(x => lit(x.replace(/^"|"$/g, ''))).join(',')})`;
  }
  throw new Error('op ' + op);
}
function where(filters) { return (filters || []).map(f => f.k === 'or' ? '(' + terms(f.v) + ')' : f.k === 'in' ? `${id(f.col)}::text IN (${f.v.map(x => lit(String(x))).join(',')})` : f.k === 'is' ? (f.v === null ? `${id(f.col)} IS NULL` : `${id(f.col)} IS ${f.v}`) : f.k === 'ilike' ? cond(f.col, 'ilike', f.v) : cond(f.col, f.k, f.v)).join(' AND '); }
const cols = s => !s || s === '*' ? '*' : s.split(',').map(x => id(x.trim())).join(',');
function build(q) {
  const t = 'public.' + id(q.table), w = where(q.filters), W = w ? ' WHERE ' + w : '';
  const wrap = body => `SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (${body}) x`;
  const dml = (cte, sel) => `WITH r AS (${cte} RETURNING *) SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (SELECT ${sel} FROM r) x`;
  if (q.op === 'select') return wrap(`SELECT ${cols(q.select)} FROM ${t}${W}${(q.orders || []).length ? ' ORDER BY ' + q.orders.map(o => id(o.col) + (o.asc ? ' ASC' : ' DESC')).join(',') : ''}${q.limit != null ? ' LIMIT ' + (+q.limit) : ''}`);
  const rows = Array.isArray(q.values) ? q.values : q.values ? [q.values] : [];
  if (q.op === 'insert' || q.op === 'upsert') {
    const ks = [...new Set(rows.flatMap(r => Object.keys(r)))];
    let sql = `INSERT INTO ${t} (${ks.map(id).join(',')}) VALUES ${rows.map(r => '(' + ks.map(k => k in r ? lit(r[k]) : 'DEFAULT').join(',') + ')').join(',')}`;
    if (q.op === 'upsert') sql += ` ON CONFLICT (${(q.onConflict || 'id').split(',').map(id).join(',')}) DO UPDATE SET ${ks.map(k => `${id(k)}=EXCLUDED.${id(k)}`).join(',')}`;
    return dml(sql, q.select ? cols(q.select) : '1 AS ok');
  }
  if (q.op === 'update') return dml(`UPDATE ${t} SET ${Object.keys(q.values).map(k => `${id(k)}=${lit(q.values[k])}`).join(',')}${W}`, q.select ? cols(q.select) : '1 AS ok');
  if (q.op === 'delete') return dml(`DELETE FROM ${t}${W}`, '1 AS ok');
}
const ATC = {};
function argTypes(name) { // test stand-in only: real supabase-js sends JSON, so jsonb parameters must be passed as jsonb, not as a Postgres array literal
  if (!ATC[name]) { const r = psql(`SELECT coalesce(json_object_agg(a.n, a.t),'{}'::json) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace, LATERAL (SELECT unnest(p.proargnames) n, format_type(unnest(string_to_array(p.proargtypes::text,' ')::oid[]),NULL) t) a WHERE n.nspname='public' AND p.proname='${name.replace(/[^a-z0-9_]/gi, '')}'`); ATC[name] = r.error ? {} : JSON.parse(r.ok || '{}'); }
  return ATC[name];
}
let FN = null;
function fnInfo(name) { if (!FN) { const r = psql(`SELECT json_object_agg(proname, proretset OR prorettype IN (SELECT oid FROM pg_type WHERE typtype='c')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'`); FN = JSON.parse(r.ok || '{}'); } return FN[name]; }
const storage = {}, flags = { rt: false, offline: false };
function reset() {
  FN = null;
  const rr = psql(`SELECT set_config('request.jwt.claim.role','service_role',true);
   TRUNCATE public.board_posts, public.board_notifications, public.board_post_edits CASCADE; DELETE FROM public.posts; TRUNCATE public.messages, public.notifications, public.follows, public.content_reports, public.user_blocks, public.user_settings CASCADE;
   DO $$ BEGIN
     IF to_regclass('public.group_chats') IS NOT NULL THEN TRUNCATE public.group_chats CASCADE; END IF;
     IF to_regclass('public.conversation_settings') IS NOT NULL THEN TRUNCATE public.conversation_settings CASCADE; END IF;
     IF to_regclass('public.bmn_messaging_settings') IS NOT NULL THEN TRUNCATE public.bmn_messaging_settings CASCADE; END IF;
     IF to_regclass('public.message_requests') IS NOT NULL THEN TRUNCATE public.message_requests CASCADE; END IF;
   END $$;
   DELETE FROM public.profiles WHERE id NOT IN (${Object.values(U).map(u => `'${u}'`).join(',')});
   INSERT INTO auth.users(id,email) VALUES ${Object.values(U).map((u, i) => `('${u}','u${i}@test.local')`).join(',')} ON CONFLICT DO NOTHING;
   INSERT INTO public.profiles(id,username,display_name,last_seen_at) VALUES ('${U.A}','alice_test','Alice Test',now()),('${U.B}','bob_test','Bob Test',now()),('${U.C}','cara_test','Cara Test',now()),('${U.D}','dan_test','Dan Test',now()) ON CONFLICT (id) DO UPDATE SET username=EXCLUDED.username, display_name=EXCLUDED.display_name, last_seen_at=now();
   INSERT INTO public.follows(follower_id,following_id) VALUES ('${U.A}','${U.B}'),('${U.A}','${U.C}'),('${U.A}','${U.D}') ON CONFLICT DO NOTHING`);
  Object.keys(storage).forEach(k => delete storage[k]);
  if (rr.error) throw new Error('reset failed: ' + rr.error.message);
}
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="#09f"/></svg>';
http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', '*'); res.setHeader('Access-Control-Allow-Methods', '*');
  if (req.method === 'OPTIONS') { res.end(); return; }
  const url = new URL(req.url, 'http://x');
  if (url.pathname.startsWith('/img/')) { res.setHeader('content-type', 'image/svg+xml'); res.end(svg); return; }
  let body = ''; req.on('data', c => body += c); req.on('end', () => {
    const j = body ? JSON.parse(body) : {}, reply = o => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(o)); };
    try {
      if (url.pathname === '/reset') { reset(); return reply({ ok: true, U }); }
      if (url.pathname === '/flags') { Object.assign(flags, j); return reply(flags); }
      if (url.pathname === '/sql') { const r = psql(j.sql, j.uid || null); return reply(r.error ? r : { data: r.ok ? JSON.parse(r.ok) : null }); }   // test-only: assertions and fixtures
      if (url.pathname === '/bcast') return reply({ ok: true });   // broadcast (typing) is not persisted
      if (url.pathname === '/events') return reply({ events: [], seq: 0, rt: false });
      if (url.pathname === '/upload') { storage[j.path] = j.size; return reply({ data: { path: j.path } }); }
      if (url.pathname === '/remove') { (j.paths || []).forEach(p => delete storage[p]); return reply({ data: [] }); }
      if (url.pathname === '/storage') return reply(Object.keys(storage));
      if (flags.offline) return reply({ error: { message: 'Failed to fetch' } });
      if (url.pathname === '/query') {
        const r = psql(build(j.q), j.uid); if (r.error) return reply({ error: r.error });
        let data = JSON.parse(r.ok); if (!j.q.select && j.q.op !== 'select') data = null; else if (j.q.single) { if (data.length !== 1 && !(j.q.maybe && data.length === 0)) return reply({ error: { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned' } }); data = data[0] || null; }
        return reply({ data });
      }
      if (url.pathname === '/rpc') {
        const isT = fnInfo(j.name); if (isT === undefined) return reply({ error: { code: 'PGRST202', message: 'Could not find the function public.' + j.name } });
        const AT = argTypes(j.name);
        const args = Object.keys(j.args || {}).map(k => `${id(k)} := ${AT[k] === 'jsonb' && j.args[k] !== null ? "'" + JSON.stringify(j.args[k]).replace(/'/g, "''") + "'::jsonb" : lit(j.args[k])}`).join(', ');
        const r = psql(`SELECT coalesce(jsonb_agg(to_jsonb(f)),'[]'::jsonb) FROM public.${id(j.name)}(${args}) f`, j.uid); if (r.error) return reply({ error: r.error });
        let d = JSON.parse(r.ok); if (!isT) { d = d.length ? d[0] : null; if (d && typeof d === 'object' && Object.keys(d).length === 1 && j.name !== '') d = Object.values(d)[0]; }
        return reply({ data: d });
      }
      res.statusCode = 404; reply({ error: 'nf' });
    } catch (e) { res.statusCode = 500; reply({ error: { message: String(e.message) } }); }
  });
}).listen(PORT, () => console.log('pg stand-in up on', PORT));
