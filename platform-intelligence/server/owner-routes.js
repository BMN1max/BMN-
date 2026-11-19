'use strict';
// Owner control-centre API as data: one descriptor per endpoint, executed by the pure runRoute(). Every endpoint calls ONE database
// function that itself re-checks that the actor is the BMN owner (pi_assert_owner), so the HTTP layer is never the only gate.
// Nothing here can ban, delete, permanently remove or revoke anything: the database functions refuse such actions.
const { isUuid, PiError } = require('./lib/util');

const bad = (m) => new PiError(m, { status: 400, code: 'invalid', expose: true });
const uuid = (v, name) => { if (!isUuid(v)) throw bad(`${name} must be a valid id`); return v; };
const str = (v, name, max = 2000, required = true) => {
  if (v == null || v === '') { if (required) throw bad(`${name} is required`); return null; }
  if (typeof v !== 'string') throw bad(`${name} must be text`);
  if (v.length > max) throw bad(`${name} is too long (max ${max})`);
  return v;
};
const oneOf = (v, list, name, dflt) => { if (v == null || v === '') { if (dflt !== undefined) return dflt; throw bad(`${name} is required`); } if (!list.includes(v)) throw bad(`${name} must be one of: ${list.join(', ')}`); return v; };
const int = (v, name, dflt, lo, hi) => { if (v == null || v === '') return dflt; const n = Number(v); if (!Number.isInteger(n) || n < lo || n > hi) throw bad(`${name} must be a whole number between ${lo} and ${hi}`); return n; };
const bool = (v, name, dflt) => { if (v == null || v === '') return dflt; if (v === true || v === 'true' || v === '1') return true; if (v === false || v === 'false' || v === '0') return false; throw bad(`${name} must be true or false`); };
const num = (v, name) => { if (v == null || v === '') return null; const n = Number(v); if (!Number.isFinite(n)) throw bad(`${name} must be a number`); return n; };
const FLAG_KEY = /^[a-z][a-z0-9_]{2,60}$/;

// [method, path pattern, handler(call, ctx) ]  ctx = { actor, q (query), b (body), p (path params) }
const ROUTES = [
  ['GET', '/overview', (c, x) => c('pi_owner_overview', { p_actor: x.actor })],
  ['GET', '/health', (c) => c('pi_system_health', {})],
  ['GET', '/cases', (c, x) => c('pi_owner_list_cases', { p_actor: x.actor, p_status: oneOf(x.q.status, ['open', 'awaiting_review', 'resolved', 'all'], 'status', 'awaiting_review'), p_limit: int(x.q.limit, 'limit', 50, 1, 200), p_offset: int(x.q.offset, 'offset', 0, 0, 100000) })],
  ['GET', '/cases/:id', (c, x) => c('pi_owner_case_detail', { p_actor: x.actor, p_case_id: uuid(x.p.id, 'id') })],
  ['POST', '/cases/:id/resolve', (c, x) => c('pi_owner_resolve_case', { p_actor: x.actor, p_case_id: uuid(x.p.id, 'id'),
      p_resolution: oneOf(x.b.resolution, ['no_violation', 'violation_confirmed', 'insufficient_information', 'duplicate'], 'resolution'),
      p_action_type: oneOf(x.b.action_type, ['no_action', 'warn', 'remove_content'], 'action_type', 'no_action'),
      p_user_visible_reason: str(x.b.user_visible_reason, 'user_visible_reason', 500, false), p_note: str(x.b.note, 'note', 2000) })],
  ['POST', '/actions/:id/reverse', (c, x) => c('pi_owner_reverse_action', { p_actor: x.actor, p_action_id: uuid(x.p.id, 'id'), p_reason: str(x.b.reason, 'reason', 1000) })],
  ['GET', '/accounts', (c, x) => c('pi_owner_list_accounts', { p_actor: x.actor, p_min_level: oneOf(x.q.min_level, ['low', 'medium', 'high', 'critical'], 'min_level', 'medium'), p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['GET', '/investigations', (c, x) => c('pi_owner_list_investigations', { p_actor: x.actor, p_status: oneOf(x.q.status, ['open', 'in_review', 'closed'], 'status', 'open'), p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['GET', '/investigations/:id', (c, x) => c('pi_owner_investigation_detail', { p_actor: x.actor, p_id: uuid(x.p.id, 'id') })],
  ['POST', '/investigations/:id', (c, x) => c('pi_owner_update_investigation', { p_actor: x.actor, p_id: uuid(x.p.id, 'id'), p_status: oneOf(x.b.status, ['open', 'in_review', 'closed'], 'status'),
      p_note: str(x.b.note, 'note', 2000), p_resolution: str(x.b.resolution, 'resolution', 1000, false) })],
  ['GET', '/events', (c, x) => c('pi_owner_list_events', { p_actor: x.actor, p_only_open: bool(x.q.only_open, 'only_open', true), p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['POST', '/events/:id/ack', (c, x) => c('pi_owner_ack_event', { p_actor: x.actor, p_event_id: int(x.p.id, 'id', null, 1, Number.MAX_SAFE_INTEGER) })],
  ['GET', '/alerts', (c, x) => c('pi_owner_list_alerts', { p_actor: x.actor, p_include_resolved: bool(x.q.include_resolved, 'include_resolved', false), p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['POST', '/alerts/:id/ack', (c, x) => c('pi_owner_ack_alert', { p_actor: x.actor, p_alert_id: int(x.p.id, 'id', null, 1, Number.MAX_SAFE_INTEGER) })],
  ['GET', '/restrictions', (c, x) => c('pi_owner_list_restrictions', { p_actor: x.actor, p_active_only: bool(x.q.active_only, 'active_only', true), p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['POST', '/restrictions/:id/lift', (c, x) => c('pi_owner_lift_restriction', { p_actor: x.actor, p_id: uuid(x.p.id, 'id'), p_reason: str(x.b.reason, 'reason', 1000) })],
  ['GET', '/verification', (c, x) => c('pi_owner_list_verification', { p_actor: x.actor, p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['POST', '/verification/:id/decide', (c, x) => c('pi_owner_decide_verification', { p_actor: x.actor, p_request_id: uuid(x.p.id, 'id'), p_decision: oneOf(x.b.decision, ['approved', 'rejected'], 'decision'), p_note: str(x.b.note, 'note', 1000) })],
  ['POST', '/verification/:id/evaluate', (c, x) => c('pi_owner_enqueue', { p_actor: x.actor, p_type: 'evaluate_verification', p_payload: { request_id: uuid(x.p.id, 'id') } })],
  ['GET', '/appeals', (c, x) => c('pi_owner_list_appeals', { p_actor: x.actor, p_status: oneOf(x.q.status, ['pending', 'upheld', 'overturned', 'all'], 'status', 'pending'), p_limit: int(x.q.limit, 'limit', 50, 1, 200) })],
  ['POST', '/appeals/:id/decide', (c, x) => c('pi_decide_appeal', { p_actor: x.actor, p_appeal_id: uuid(x.p.id, 'id'), p_decision: oneOf(x.b.decision, ['upheld', 'overturned'], 'decision'), p_note: str(x.b.note, 'note', 2000) })],
  ['GET', '/audit', (c, x) => c('pi_owner_list_audit', { p_actor: x.actor, p_limit: int(x.q.limit, 'limit', 100, 1, 500), p_before: x.q.before ? int(x.q.before, 'before', null, 1, Number.MAX_SAFE_INTEGER) : null, p_action_prefix: str(x.q.prefix, 'prefix', 60, false) })],
  ['GET', '/policy', (c, x) => c('pi_owner_policy_overview', { p_actor: x.actor })],
  ['POST', '/policy/:category', (c, x) => c('pi_owner_update_policy', { p_actor: x.actor, p_category: str(x.p.category, 'category', 60),
      p_enabled: bool(x.b.enabled, 'enabled', null), p_review: num(x.b.review_threshold, 'review_threshold'), p_auto: x.b.auto_action_threshold === null ? null : num(x.b.auto_action_threshold, 'auto_action_threshold'),
      p_max_auto: str(x.b.max_auto_action, 'max_auto_action', 40, false), p_always_human: bool(x.b.always_human_review, 'always_human_review', null), p_reason: str(x.b.reason, 'reason', 1000) })],
  ['POST', '/flags/:key', (c, x) => { if (!FLAG_KEY.test(x.p.key || '')) throw bad('unknown feature flag'); return c('pi_owner_set_flag', { p_actor: x.actor, p_key: x.p.key, p_enabled: bool(x.b.enabled, 'enabled', undefined) ?? (() => { throw bad('enabled is required'); })(), p_reason: str(x.b.reason, 'reason', 1000) }); }],
  ['POST', '/rule-sets/:key', (c, x) => { if (!x.b.config || typeof x.b.config !== 'object' || Array.isArray(x.b.config)) throw bad('config must be an object'); return c('pi_owner_publish_rule_set', { p_actor: x.actor, p_key: str(x.p.key, 'key', 60), p_config: x.b.config, p_note: str(x.b.note, 'note', 1000) }); }],
  ['POST', '/jobs', (c, x) => c('pi_owner_enqueue', { p_actor: x.actor, p_type: oneOf(x.b.type, ['evaluate_verification', 'provider_healthcheck'], 'type'), p_payload: x.b.type === 'evaluate_verification' ? { request_id: uuid(x.b.request_id, 'request_id') } : {} })]
];

const compiled = ROUTES.map(([method, pattern, fn]) => {
  const names = []; const re = new RegExp('^' + pattern.replace(/:([a-z_]+)/g, (_, n) => { names.push(n); return '([^/]+)'; }) + '/?$');
  return { method, pattern, re, names, fn };
});

/** Pure: no express, no network. `call(name,args)` is the database caller. */
async function runRoute({ method, path, actor, query = {}, body = {} }, call) {
  if (!isUuid(actor)) throw new PiError('Sign in is required.', { status: 401, code: 'unauthenticated', expose: true });
  for (const r of compiled) {
    if (r.method !== method) continue;
    const m = r.re.exec(path); if (!m) continue;
    const p = {}; r.names.forEach((n, i) => { try { p[n] = decodeURIComponent(m[i + 1]); } catch { throw bad('bad path'); } });
    const data = await r.fn(call, { actor, q: query || {}, b: (body && typeof body === 'object') ? body : {}, p });
    return { status: 200, body: { ok: true, data } };
  }
  throw new PiError('Not found', { status: 404, code: 'not_found', expose: true });
}
module.exports = { runRoute, ROUTES: compiled.map((r) => `${r.method} ${r.pattern}`) };
