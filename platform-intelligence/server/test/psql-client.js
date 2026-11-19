'use strict';
// TEST HELPER ONLY. A stand-in for supabaseAdmin that runs `rpc(name, args)` as the service_role against a LOCAL disposable Postgres
// through psql. It proves the Node code calls the real database functions with the right argument names and shapes. It does NOT test
// PostgREST / Supabase's HTTP layer. Refuses non-local hosts.
const { spawnSync } = require('node:child_process');

function lit(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return String(v);
  if (Array.isArray(v) && v.every((x) => typeof x === 'string')) return lit('{' + v.map((x) => '"' + x.replace(/(["\\])/g, '\\$1') + '"').join(',') + '}');
  if (typeof v === 'object' || Array.isArray(v)) return lit(JSON.stringify(v));
  return "'" + String(v).replace(/'/g, "''") + "'";
}

function createPsqlClient(db, { role = 'service_role' } = {}) {
  if (process.env.PGHOST && !/^(\/|localhost$|127\.)/.test(process.env.PGHOST)) throw new Error('refusing to run against a non-local PGHOST');
  const run = (sql) => spawnSync('psql', ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-d', db], { input: sql, encoding: 'utf8' });
  const shape = new Map();
  function kind(name) {
    if (shape.has(name)) return shape.get(name);
    const r = run(`select case when proretset then 'set' when prorettype = 'void'::regtype then 'void' else 'scalar' end from pg_proc where proname = ${lit(name)} and pronamespace = 'public'::regnamespace limit 1;`);
    const k = (r.stdout || '').trim() || 'scalar'; shape.set(name, k); return k;
  }
  return {
    sql: (q) => { const r = run(q); if (r.status !== 0) throw new Error(r.stderr); return r.stdout.trim(); },
    async rpc(name, args = {}) {
      const call = `public.${name}(${Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(', ')})`;
      const k = kind(name);
      const q = k === 'set' ? `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from ${call} t` : k === 'void' ? `select ${call}` : `select to_jsonb(${call})`;
      const r = run(`set request.jwt.claim.role = 'service_role'; set role ${role};\n${q};`);
      if (r.status !== 0) {
        const m = /ERROR:\s+([0-9A-Z]{5}):\s+(.*)/.exec(r.stderr || '');
        return { data: null, error: { code: m ? m[1] : 'XX000', message: m ? m[2] : (r.stderr || 'psql failed') } };
      }
      const out = r.stdout.split('\n').filter((l) => l && !/^(SET)$/.test(l)).pop();
      return { data: k === 'void' || out === undefined || out === '' || out === 'null' ? null : JSON.parse(out), error: null };
    }
  };
}
module.exports = { createPsqlClient, lit };
