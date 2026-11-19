'use strict';
// Integration test: the REAL Node code (worker, handlers, owner routes) against the REAL database functions of migration 001+002,
// in a disposable LOCAL Postgres (see build_test_db.sh). Run with:  PI_TEST_DB=pinode node --test test/pi.integration.test.js
// Not covered: the Supabase PostgREST HTTP layer and the Express/JWT layer.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createPsqlClient } = require('./psql-client');
const { createStore } = require('../store');
const { createHandlers } = require('../handlers');
const { createWorker } = require('../worker');
const { runRoute } = require('../owner-routes');
const { createHttpLogic } = require('../router');

const DB = process.env.PI_TEST_DB;
const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const OWNER = U(1);
if (!DB) { test('integration skipped: set PI_TEST_DB', { skip: true }, () => {}); return; }

const client = createPsqlClient(DB);
const store = createStore(client);
const sql = (q) => client.sql(q);
const one = (q) => sql(q).split('\n')[0];
const owner = (method, path, body = {}, query = {}, actor = OWNER) => runRoute({ method, path, actor, body, query }, (n, a) => store.rpc(n, a)).then((r) => r.body.data);
const handlers = createHandlers({ store, log: () => {} });
const worker = createWorker({ store, handlers, workerId: 'itest-worker', log: { error() {}, log() {} } });
const SCAM = 'Guaranteed returns! Double your money, DM me to earn $500 per day https://bit.ly/x';

test('00 setup: users exist, all flags are OFF by default', () => {
  assert.equal(one(`select count(*) from public.pi_feature_flags where enabled`), '0');
  assert.equal(one(`select count(*) from public.profiles`), '4');
});

test('01 everything off: a worker tick does nothing but report in', async () => {
  const r = await worker.tick();
  assert.equal(r.claimed, 0);
  assert.equal(one(`select count(*) from public.pi_policy_decisions`), '0');
  assert.equal(one(`select count(*) from public.pi_worker_heartbeats where worker_id = 'itest-worker'`), '1');
});

test('02 owner console: only the owner may use it', async () => {
  await assert.rejects(owner('GET', '/overview', {}, {}, U(2)), (e) => e.status === 403);
  const ov = await owner('GET', '/overview'); assert.ok(ov && typeof ov === 'object');
  const logic = createHttpLogic({ store, hashKey: 'k'.repeat(32), log: { error() {} } });
  assert.equal((await logic.owner({ user: { id: U(2) }, method: 'GET', path: '/overview', query: {}, body: {} })).status, 403);
  assert.equal((await logic.owner({ user: { id: OWNER }, method: 'GET', path: '/overview', query: {}, body: {} })).status, 200);
});

test('03 flag dependencies are enforced by the database and surfaced as a clear 4xx', async () => {
  await assert.rejects(owner('POST', '/flags/moderation_enforcement', { enabled: true, reason: 'test' }), (e) => e.status >= 400 && e.status < 500);
  await owner('POST', '/flags/moderation_analysis', { enabled: true, reason: 'integration test' });
  assert.equal(one(`select enabled from public.pi_feature_flags where key='moderation_analysis'`), 't');
  assert.ok(Number(one(`select count(*) from public.pi_audit_log where action like '%flag%'`)) >= 1, 'flag change is audited');
});

test('04 content analysis: a scam post creates a human-review case, in SHADOW mode, and the post is NOT hidden', async () => {
  await owner('POST', '/policy/spam_scams', { enabled: true, review_threshold: 0.5, auto_action_threshold: 0.8, max_auto_action: 'hide_pending_review', always_human_review: false, reason: 'integration test' });
  await worker.tick();                                                                         // creates scan cursors at "now"
  sql(`update public.pi_scan_cursors set last_created_at = now() - interval '1 hour', last_id = null`);
  sql(`set request.jwt.claim.role='service_role'; insert into public.posts (id, user_id, title, caption, status, created_at) values ('00000000-0000-0000-0000-0000000b0001', '${U(3)}', 'Community post', '${SCAM}', 'published', now() - interval '1 minute')`);
  const r = await worker.tick(); assert.ok(r.claimed >= 1); assert.equal(r.failed, 0);
  assert.equal(one(`select count(*) from public.pi_policy_decisions where subject_id='00000000-0000-0000-0000-0000000b0001' and mode='shadow' and decision_kind <> 'account_risk'`), '1');
  assert.equal(one(`select count(*) from public.pi_moderation_cases where subject_id='00000000-0000-0000-0000-0000000b0001' and status in ('open','awaiting_review')`), '1');
  assert.equal(one(`select status from public.posts where id='00000000-0000-0000-0000-0000000b0001'`), 'published', 'nothing was hidden: enforcement hooks are not installed');
  assert.equal(one(`select count(*) from public.pi_content_analyses where content_hash is not null and content_length > 0`), '1');
  assert.equal(one(`select count(*) from public.pi_content_analyses where content_hash like '%guaranteed%'`), '0');
});

test('05 re-processing the same content does not duplicate cases or decisions', async () => {
  const B = '00000000-0000-0000-0000-0000000b0001';
  const cnt = () => [one(`select count(*) from public.pi_policy_decisions where subject_id='${B}'`), one(`select count(*) from public.pi_moderation_cases where subject_id='${B}'`), one(`select count(*) from public.pi_content_analyses where subject_id='${B}'`)];
  const before = cnt(); assert.deepEqual(before, ['1', '1', '1']);
  sql(`select public.pi_enqueue_job('analyze_content', '{"subject_type":"post","subject_id":"00000000-0000-0000-0000-0000000b0001"}'::jsonb, 5::smallint, 'again-1')`);
  await worker.tick();
  assert.deepEqual(cnt(), before);
});

test('06 the owner decides the case (human decision, audited); automation cannot do it', async () => {
  const list = await owner('GET', '/cases', {}, { status: 'awaiting_review' }); assert.ok(list.length >= 1);
  const id = list[0].id;
  const detail = await owner('GET', '/cases/' + id); assert.ok(detail);
  await assert.rejects(owner('POST', `/cases/${id}/resolve`, { resolution: 'no_violation', note: 'x' }, {}, U(2)), (e) => e.status === 403);
  await owner('POST', `/cases/${id}/resolve`, { resolution: 'violation_confirmed', action_type: 'warn', user_visible_reason: 'Spam is not allowed on BMN.', note: 'confirmed spam' });
  assert.equal(one(`select count(*) from public.pi_moderation_cases where id='${id}' and status='resolved'`), '1');
  assert.ok(Number(one(`select count(*) from public.pi_audit_log where actor_type='owner'`)) >= 2);
});

test('07 failing job: retried with back-off, error recorded, other jobs unaffected', async () => {
  sql(`select public.pi_enqueue_job('analyze_content', '{"subject_type":"post","subject_id":"not-a-uuid"}'::jsonb, 1::smallint, 'bad-job-1')`);
  const r = await worker.tick(); assert.equal(r.failed, 1);
  assert.equal(one(`select status || ':' || attempts from public.pi_jobs where idempotency_key='bad-job-1'`), 'queued:1');
  assert.match(one(`select last_error from public.pi_jobs where idempotency_key='bad-job-1'`), /bad analyze_content payload/);
  sql(`update public.pi_jobs set status='running', locked_by='x', locked_at = now() - interval '2 minutes', lease_expires_at = now() - interval '1 minute', attempts = max_attempts where idempotency_key='bad-job-1'`);
  await worker.tick();
  assert.equal(one(`select status from public.pi_jobs where idempotency_key='bad-job-1'`), 'dead', 'dead-lettered after the last attempt');
});

test('08 account risk: burst activity creates a risk assessment + investigation + SHADOW restriction, nothing enforced', async () => {
  await owner('POST', '/flags/account_risk_scoring', { enabled: true, reason: 'integration test' });
  await owner('POST', '/rule-sets/account_risk_rules', { config: { level_thresholds: { medium: 0.3, high: 0.55, critical: 0.8 }, restriction_hours: 12, limits: { follows_1h: 2 } }, note: 'low limit for test' });
  sql(`set request.jwt.claim.role='service_role'; insert into public.follows (follower_id, following_id) values ('${U(2)}','${U(4)}'), ('${U(2)}','${U(1)}')`);
  sql(`select public.pi_enqueue_job('assess_account', '{"user_id":"${U(2)}"}'::jsonb, 3::smallint, 'assess-test-1')`);
  const r = await worker.tick(); assert.equal(r.failed, 0, 'no failures');
  const lvl = one(`select risk_level from public.pi_account_risk_assessments where user_id='${U(2)}' and is_current`);
  assert.ok(['medium', 'high', 'critical'].includes(lvl), lvl);
  assert.equal(one(`select rule_set_version from public.pi_policy_decisions where subject_user_id='${U(2)}' and decision_kind='account_risk' limit 1`), '2', 'the published rule-set version is recorded');
  assert.equal(one(`select count(*) from public.pi_policy_decisions where decision_kind='account_risk' and mode='enforced'`), '0');
  assert.equal(one(`select count(*) from public.bmn_user_moderation`), '0', 'nobody was suspended or banned');
  const inv = await owner('GET', '/investigations'); assert.ok(inv.length >= 1);
});

test('09 verification: an incomplete profile goes to human review and stays pending (never auto-rejected)', async () => {
  await owner('POST', '/flags/verification_evaluation', { enabled: true, reason: 'integration test' });
  await worker.tick(); await worker.tick();
  assert.equal(one(`select outcome from public.pi_verification_evaluations where user_id='${U(2)}'`), 'needs_human_review');
  assert.equal(one(`select status from public.bmn_verification_requests where user_id='${U(2)}'`), 'pending');
  assert.equal(one(`select count(*) from public.bmn_verification_requests where status='rejected'`), '0');
  const v = await owner('GET', '/verification'); assert.ok(Array.isArray(v.pending) && v.pending.length >= 1);
});

test('10 auto-verification: only when ALL checks pass and the owner has switched it on; otherwise human review', async () => {
  sql(`set request.jwt.claim.role='service_role';
       update public.profiles set created_at = now() - interval '40 days', avatar_url='https://x.invalid/a.png', bio='Creator of BMN videos' where id='${U(4)}';
       insert into public.posts (user_id, title, caption, status) select '${U(4)}', 'Community post', 'post ' || g, 'published' from generate_series(1,4) g;
       insert into public.bmn_verification_requests (user_id, request_reason) values ('${U(4)}', 'I make videos for the BMN community every week.');`);
  await worker.tick(); await worker.tick();
  assert.equal(one(`select outcome from public.pi_verification_evaluations where user_id='${U(4)}'`), 'eligible_for_auto_approval');
  assert.equal(one(`select count(*) from public.bmn_verified_users where user_id='${U(4)}'`), '0', 'auto_verification flag is off: eligible but still needs a person');
  assert.match(one(`select reason from public.pi_verification_decisions where user_id='${U(4)}' order by created_at desc limit 1`), /switched off/);

  await owner('POST', '/flags/auto_verification', { enabled: true, reason: 'integration test' });
  const req = one(`select id from public.bmn_verification_requests where user_id='${U(4)}'`);
  await owner('POST', `/verification/${req}/evaluate`);     // owner-requested re-evaluation
  await worker.tick(); await worker.tick();
  assert.equal(one(`select count(*) from public.bmn_verified_users where user_id='${U(4)}'`), '1', 'all checks passed + flag on -> approved');
  assert.match(one(`select review_note from public.bmn_verification_requests where id='${req}'`), /Automatically approved/);
  assert.equal(one(`select count(*) from public.bmn_verified_users where user_id='${U(2)}'`), '0', 'the incomplete profile was not approved');
});

test('11 human verification decision requires a note and cannot revoke', async () => {
  const r2 = one(`select id from public.bmn_verification_requests where user_id='${U(2)}'`);
  await assert.rejects(owner('POST', `/verification/${r2}/decide`, { decision: 'revoked', note: 'x' }), (e) => e.status === 400);
  await assert.rejects(owner('POST', `/verification/${r2}/decide`, { decision: 'rejected', note: '' }), (e) => e.status === 400);
  await owner('POST', `/verification/${r2}/decide`, { decision: 'rejected', note: 'profile is incomplete; please add a photo and bio' });
  assert.equal(one(`select status from public.bmn_verification_requests where id='${r2}'`), 'rejected');
});

test('12 session beacon stores hashes only', async () => {
  const logic = createHttpLogic({ store, hashKey: 'k'.repeat(32) });
  const r = await logic.session({ user: { id: U(3) }, ip: '198.51.100.7', headers: { 'x-bmn-device': 'device_0123456789ABCDEF' } }); assert.equal(r.status, 204);
  assert.equal(one(`select count(*) from public.pi_session_observations where user_id='${U(3)}' and ip_hash ~ '^[0-9a-f]{64}$'`), '1');
  assert.equal(one(`select count(*) from public.pi_session_observations where ip_hash like '%198.51%'`), '0');
});

test('13 emergency halt: the worker stops all automated work at once', async () => {
  await owner('POST', '/flags/emergency_halt_automation', { enabled: true, reason: 'integration test' });
  const before = one(`select count(*) from public.pi_policy_decisions`);
  sql(`select public.pi_enqueue_job('assess_account', '{"user_id":"${U(3)}"}'::jsonb, 3::smallint, 'assess-halt-1')`);
  const r = await worker.tick(); assert.equal(r.halted, true);
  assert.equal(one(`select count(*) from public.pi_policy_decisions`), before);
  assert.equal(one(`select status from public.pi_jobs where idempotency_key='assess-halt-1'`), 'queued');
  await owner('POST', '/flags/emergency_halt_automation', { enabled: false, reason: 'integration test over' });
});

test('14 system health and audit are readable by the owner', async () => {
  const h = await owner('GET', '/health'); assert.ok('workers_active' in h);
  const a = await owner('GET', '/audit', {}, { limit: '20' }); assert.ok(Array.isArray(a) && a.length > 0);
  const p = await owner('GET', '/policy'); assert.ok(p);
});
