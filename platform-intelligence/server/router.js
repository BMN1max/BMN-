'use strict';
// HTTP layer. The logic lives in framework-free functions (session, owner) that take a plain request object and return
// {status, body}; createRouter() is a thin express adapter. Mount at /api/pi.
//   POST /api/pi/session   signed-in users: privacy-preserving session beacon (keyed hashes only, never raw IP / device id)
//   /api/pi/owner/*        BMN owner only: control centre
const { runRoute } = require('./owner-routes');
const { hmacHex, PiError } = require('./lib/util');

function createHttpLogic({ store, hashKey, log = console }) {
  // req: { user:{id}, ip, headers:{}, method, path, query, body }
  async function session(req) {
    if (!hashKey) return { status: 204 };                                           // disabled until PI_HASH_KEY is configured
    try {
      const ip = String(req.ip || '');
      const dev = String(req.headers?.['x-bmn-device'] || '').slice(0, 80);
      if (!ip || !/^[A-Za-z0-9_-]{16,80}$/.test(dev)) return { status: 204 };
      await store.rpc('pi_record_session', { p_user: req.user.id, p_ip_hash: hmacHex(hashKey, 'ip:' + ip), p_device_hash: hmacHex(hashKey, 'dev:' + dev) });
    } catch (e) { /* the beacon must never break the app */ }
    return { status: 204 };
  }
  async function owner(req) {
    try {
      const ok = await store.rpc('pi_is_owner', { p_user: req.user.id });
      if (ok !== true) return { status: 403, body: { error: 'The Intelligence console is only available to the BMN owner.' } };
    } catch (e) { return { status: 500, body: { error: 'Could not verify owner access.' } }; }
    try {
      return await runRoute({ method: req.method, path: req.path, actor: req.user.id, query: req.query, body: req.body }, (name, args) => store.rpc(name, args));
    } catch (e) {
      const pe = e instanceof PiError ? e : new PiError('Unexpected error', { status: 500 });
      if (pe.status >= 500) log.error?.('[pi] owner route error:', pe.code, e.message);
      return { status: pe.status, body: { error: pe.expose ? pe.message : 'Something went wrong. Try again.', code: pe.code } };
    }
  }
  return { session, owner };
}

function createRouter({ express, store, requireUser, hashKey, rateLimit, log = console }) {
  const logic = createHttpLogic({ store, hashKey, log });
  const router = express.Router();
  router.use(express.json({ limit: '32kb' }));
  const lim = (o) => (rateLimit ? rateLimit({ standardHeaders: true, legacyHeaders: false, message: { error: 'Too many requests.' }, ...o }) : (q, s, n) => n());
  const send = (res, r) => { res.set('Cache-Control', 'no-store'); return r.body === undefined ? res.status(r.status).end() : res.status(r.status).json(r.body); };
  router.post('/session', lim({ windowMs: 60_000, limit: 6 }), requireUser, async (req, res) => send(res, await logic.session({ user: req.user, ip: req.ip, headers: req.headers })));
  router.use('/owner', lim({ windowMs: 60_000, limit: 120 }), requireUser, async (req, res) =>
    send(res, await logic.owner({ user: req.user, method: req.method, path: req.path, query: req.query, body: req.body })));
  router.use((err, req, res, next) => { void next; return res.status(400).json({ error: 'Invalid request.' }); });
  return router;
}
module.exports = { createHttpLogic, createRouter };
