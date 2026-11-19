'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const moderation = require('../engines/moderation');
const account = require('../engines/account');
const verification = require('../engines/verification');
const { MODERATION_RULES_V1: MR, ACCOUNT_RISK_RULES_V1: AR, VERIFICATION_CRITERIA_V1: VC, activeRules } = require('../rules/defaults');
const { runRoute, ROUTES } = require('../owner-routes');
const { createHttpLogic } = require('../router');
const { createWorker } = require('../worker');
const { createHandlers } = require('../handlers');
const { createOpenAiModeration } = require('../providers/openai-moderation');
const { PiError, mapDbError, isUuid } = require('../lib/util');
const { createStore } = require('../store');

const OWNER = '00000000-0000-0000-0000-000000000001';
const U2 = '00000000-0000-0000-0000-000000000002';
const POLICIES = { spam_scams: { enabled: true, version: 1, review_threshold: 0.5, auto_action_threshold: 0.8, max_auto_action: 'hide_pending_review', always_human_review: false },
                   threats_violence: { enabled: true, version: 1, review_threshold: 0.4, auto_action_threshold: 0.7, max_auto_action: 'flag', always_human_review: true } };
const an = (text, extra = {}) => moderation.analyze({ subjectType: 'post', text, meta: { account_age_days: 1 }, ...extra }, MR);

// ------------------------------------------------------------------ moderation engine
test('moderation: scam text is high risk with reasons; benign text is zero', () => {
  const a = an('Guaranteed returns! Double your money, DM me to earn $500 per day https://bit.ly/x');
  assert.equal(a.topCategory, 'spam_scams'); assert.ok(a.risk >= 0.9); assert.ok(a.signals.length >= 3);
  const b = an('Had a lovely day at the beach with my family, sharing some photos!');
  assert.equal(b.risk, 0); assert.equal(b.topCategory, null); assert.ok(b.confidence <= 0.65, 'clear is never certainty');
});
test('moderation: obfuscated scam wording is still caught', () => { assert.ok(an('d0uble y0ur m0ney, gu4ranteed returns').risk > 0.5); });
test('moderation: engine makes no hate or sexual claim from rules alone', () => {
  const a = an('some neutral text'); assert.ok(!('hate_speech' in a.categoryScores) && !('prohibited_sexual_content' in a.categoryScores));
});
test('moderation: custom owner term and provider score feed a category', () => {
  const r = { ...MR, custom_terms: { hate_speech: [{ term: 'badword', weight: 0.9 }] } };
  assert.ok(moderation.analyze({ subjectType: 'comment', text: 'you are a badword' }, r).categoryScores.hate_speech >= 0.9);
  const p = moderation.analyze({ subjectType: 'comment', text: 'hello there friend', providerScores: { harassment_bullying: 0.8 }, providerName: 'x' }, MR);
  assert.equal(p.topCategory, 'harassment_bullying');
});
test('moderation: hash never equals or contains the text and is stable', () => {
  const a = an('Hello World'); const b = an('hello   world');
  assert.equal(a.contentHash, b.contentHash); assert.ok(!a.contentHash.includes('hello'));
});
test('moderation: impersonation of a verified account is flagged', () => {
  const a = moderation.analyze({ subjectType: 'profile', text: '', meta: { username: 'bmn_0fficial', display_name: 'BMN Official', verified: false, user_id: 'x' }, verifiedNames: [{ user_id: 'y', username: 'bmn_official', display_name: 'BMN Official' }] }, MR);
  assert.equal(a.topCategory, 'impersonation'); assert.ok(a.risk >= 0.7);
  const v = moderation.analyze({ subjectType: 'profile', text: '', meta: { username: 'bmn_0fficial', verified: true, user_id: 'x' }, verifiedNames: [{ user_id: 'y', username: 'bmn_official' }] }, MR);
  assert.equal(v.risk, 0, 'verified accounts are not screened as look-alikes');
});
test('moderation: decide NEVER recommends a destructive action, for any input', () => {
  const texts = ['kill yourself', 'I will kill you', 'double your money guaranteed returns dm me to earn $500 per day bit.ly/x', 'hello', 'you are so stupid'];
  for (const t of texts) for (const type of ['post', 'comment', 'message', 'profile']) for (const src of ['automated', 'user_report']) for (const enf of [true, false]) {
    const a = an(t, { subjectType: type }); const d = moderation.decide(a, { subjectType: type, source: src, policies: POLICIES, rules: MR, enforcementAvailable: enf });
    assert.ok(['no_action', 'flag', 'hide_pending_review', 'refer_to_human'].includes(d.recommended_action), d.recommended_action);
    assert.equal(d.mode, enf ? 'enforced' : 'shadow');
  }
});
test('moderation: hiding only for public content, never for messages or always-human categories', () => {
  const a = an('Guaranteed returns! Double your money, DM me to earn $500 per day https://bit.ly/x');
  assert.equal(moderation.decide(a, { subjectType: 'post', policies: POLICIES, rules: MR }).recommended_action, 'hide_pending_review');
  assert.notEqual(moderation.decide(a, { subjectType: 'message', policies: POLICIES, rules: MR }).recommended_action, 'hide_pending_review');
  const t = moderation.analyze({ subjectType: 'post', text: 'I will kill you tomorrow' }, MR);
  const d = moderation.decide(t, { subjectType: 'post', policies: POLICIES, rules: MR });
  assert.equal(d.requires_human_review, true); assert.notEqual(d.recommended_action, 'hide_pending_review');
});
test('moderation: a disabled policy records but takes no action and opens no review', () => {
  const d = moderation.decide(an('Guaranteed returns! Double your money'), { subjectType: 'post', policies: { spam_scams: { ...POLICIES.spam_scams, enabled: false } }, rules: MR });
  assert.equal(d.recommended_action, 'no_action'); assert.equal(d.requires_human_review, false);
});
test('moderation: user report alone raises priority but is not a conviction', () => {
  const a = moderation.analyze({ subjectType: 'post', text: 'a perfectly normal sentence about cooking', source: 'user_report', reportReason: 'spam' }, MR);
  assert.ok(a.risk <= 0.3);
});

// ------------------------------------------------------------------ account engine
test('account: normal activity is low risk and recommends nothing', () => {
  const r = account.assess({ user_id: U2, follows_1h: 3, posts_1h: 1, account_age_days: 100 }, AR); assert.equal(r.risk_level, 'low'); assert.equal(r.decision.recommended_action, 'no_action'); assert.equal(r.restrictions.length, 0);
});
test('account: mass following by a new account is high risk with a TEMPORARY restriction capped at 72h', () => {
  const r = account.assess({ user_id: U2, follows_1h: 200, account_age_days: 0.2 }, { ...AR, restriction_hours: 9999 }, { restrictionsEnforceable: false, bucket: '1' });
  assert.equal(r.risk_level, 'high'); assert.equal(r.restrictions[0].restriction_type, 'limit_follows'); assert.equal(r.restrictions[0].hours, 72);
  assert.equal(r.decision.mode, 'shadow'); assert.equal(r.decision.recommended_action, 'restrict_temporary'); assert.equal(r.open_investigation, true); assert.equal(r.decision.requires_human_review, true);
});
test('account: output can never contain ban/suspend/delete', () => {
  const r = account.assess({ user_id: U2, follows_1h: 5000, posts_1h: 500, comments_1h: 900, messages_1h: 900, message_recipients_1h: 900, ips_24h: 99, devices_24h: 99, violations_90d: 9, reporters_7d: 9, account_age_days: 0 }, AR);
  assert.equal(r.risk_level, 'critical'); assert.ok(['restrict_temporary', 'refer_to_human'].includes(r.decision.recommended_action));
  assert.ok(!/ban|suspend|delet/i.test(JSON.stringify(r.decision.recommended_action) + JSON.stringify(r.restrictions.map((x) => x.restriction_type))));
});
test('account: configured limits change the outcome; verified standing lowers but does not remove risk', () => {
  const base = { user_id: U2, follows_1h: 10, account_age_days: 100 };
  assert.equal(account.assess(base, AR).risk_level, 'low');
  assert.notEqual(account.assess(base, { ...AR, limits: { ...AR.limits, follows_1h: 5 } }).risk_level, 'low');
  const lim = { ...AR, limits: { ...AR.limits, follows_1h: 5 } };
  assert.ok(account.assess({ ...base, verified: true }, lim).risk_score < account.assess(base, lim).risk_score);
  assert.ok(account.assess({ ...base, verified: true }, lim).risk_score > 0);
});

// ------------------------------------------------------------------ verification engine
const goodFacts = () => ({ found: true, request: { status: 'pending' }, profile: { exists: true, has_avatar: true, has_bio: true, display_name: 'Ada', username: 'ada_k' }, account_age_days: 40, published_posts: 5, followers: 10,
  account_status: 'active', violations_180d: 0, active_restrictions: 0, open_cases: 0, prior_rejections: 0, fraud_history: false, current_risk_level: 'low', already_verified: false, verified_names: [] });
test('verification: all required checks pass -> eligible_for_auto_approval', () => { const e = verification.evaluate(goodFacts(), VC); assert.equal(e.outcome, 'eligible_for_auto_approval'); assert.equal(e.checks.length, 7); assert.ok(e.checks.every((c) => c.result === 'pass')); });
test('verification: any failed check -> human review, NEVER rejection', () => {
  for (const mut of [(f) => { f.account_age_days = 2; }, (f) => { f.profile.has_bio = false; }, (f) => { f.published_posts = 0; }, (f) => { f.violations_180d = 1; }, (f) => { f.current_risk_level = 'high'; },
    (f) => { f.open_cases = 1; }, (f) => { f.fraud_history = true; }, (f) => { f.prior_rejections = 1; }, (f) => { f.verified_names = [{ username: 'ada_k', display_name: 'Ada' }]; }]) {
    const f = goodFacts(); mut(f); const e = verification.evaluate(f, VC); assert.equal(e.outcome, 'needs_human_review'); assert.notEqual(e.outcome, 'rejected');
  }
});
test('verification: manual evidence review and unknown checks never auto-pass', () => {
  const crit = { checks: [{ id: 'a', type: 'min_account_age_days', required: true, value: 1 }, { id: 'm', type: 'manual_evidence_review', required: true }] };
  assert.equal(verification.evaluate(goodFacts(), crit).outcome, 'needs_human_review');
  assert.equal(verification.evaluate(goodFacts(), { checks: [{ id: 'z', type: 'weird', required: true }] }).outcome, 'needs_human_review');
  assert.equal(verification.evaluate(goodFacts(), { checks: [] }).outcome, 'insufficient_evidence');
});
test('verification: already verified accounts are never auto-approved again', () => { const f = goodFacts(); f.already_verified = true; assert.equal(verification.evaluate(f, VC).outcome, 'needs_human_review'); });
test('verification: optional checks are informational, not stored', () => {
  const e = verification.evaluate(goodFacts(), { checks: [{ id: 'a', type: 'min_account_age_days', required: true, value: 1 }, { id: 'f', type: 'min_followers', required: false, value: 999 }] });
  assert.equal(e.outcome, 'eligible_for_auto_approval'); assert.equal(e.checks.length, 1); assert.equal(e.optional_checks[0].result, 'fail');
});

// ------------------------------------------------------------------ rules
test('rules: published version wins, otherwise built-in v1', () => {
  assert.equal(activeRules({}, 'moderation_rules').version, 1);
  assert.equal(activeRules({ rule_sets: { moderation_rules: { version: 3, config: { hold_hours: 5 } } } }, 'moderation_rules').version, 3);
});

// ------------------------------------------------------------------ owner routes
test('owner routes: validation rejects bad input before the database is called', async () => {
  let called = 0; const call = async () => { called++; return {}; };
  const bad = [
    { method: 'GET', path: '/cases/not-a-uuid' }, { method: 'GET', path: '/cases', query: { status: 'drop table' } }, { method: 'GET', path: '/cases', query: { limit: '9999' } },
    { method: 'POST', path: '/cases/' + U2 + '/resolve', body: { resolution: 'ban_user', note: 'x' } }, { method: 'POST', path: '/cases/' + U2 + '/resolve', body: { resolution: 'no_violation' } },
    { method: 'POST', path: '/verification/' + U2 + '/decide', body: { decision: 'revoked', note: 'x' } }, { method: 'POST', path: '/flags/BAD KEY', body: { enabled: true, reason: 'r' } },
    { method: 'POST', path: '/flags/auto_verification', body: { reason: 'r' } }, { method: 'POST', path: '/rule-sets/moderation_rules', body: { config: [] } }, { method: 'POST', path: '/jobs', body: { type: 'apply_action' } },
    { method: 'POST', path: '/events/abc/ack' }];
  for (const r of bad) await assert.rejects(runRoute({ ...r, actor: OWNER }, call), (e) => e instanceof PiError && e.status === 400, JSON.stringify(r));
  assert.equal(called, 0);
});
test('owner routes: needs a signed-in actor; unknown path is 404; good call passes the actor id', async () => {
  await assert.rejects(runRoute({ method: 'GET', path: '/overview', actor: 'nope' }, async () => ({})), (e) => e.status === 401);
  await assert.rejects(runRoute({ method: 'GET', path: '/nothing', actor: OWNER }, async () => ({})), (e) => e.status === 404);
  const seen = []; const r = await runRoute({ method: 'POST', path: '/cases/' + U2 + '/resolve', actor: OWNER, body: { resolution: 'no_violation', note: 'looks fine' } }, async (n, a) => { seen.push([n, a]); return { done: true }; });
  assert.equal(r.status, 200); assert.equal(seen[0][0], 'pi_owner_resolve_case'); assert.equal(seen[0][1].p_actor, OWNER); assert.equal(seen[0][1].p_action_type, 'no_action');
});
test('owner routes: no endpoint exposes ban / delete / revoke', () => { for (const r of ROUTES) assert.ok(!/ban|delete|revoke|suspend/i.test(r), r); });

// ------------------------------------------------------------------ http logic
test('http: non-owner gets 403 and no route function runs', async () => {
  const calls = []; const store = { rpc: async (n, a) => { calls.push(n); return n === 'pi_is_owner' ? false : {}; } };
  const r = await createHttpLogic({ store, hashKey: 'k'.repeat(32) }).owner({ user: { id: U2 }, method: 'GET', path: '/overview', query: {}, body: {} });
  assert.equal(r.status, 403); assert.deepEqual(calls, ['pi_is_owner']);
});
test('http: DB errors never leak internals; owner-safe errors are shown', async () => {
  const mk = (err) => ({ rpc: async (n) => { if (n === 'pi_is_owner') return true; throw mapDbError(err); } });
  let r = await createHttpLogic({ store: mk({ code: 'XX000', message: 'relation "secret_table" does not exist' }), hashKey: 'k', log: { error() {} } }).owner({ user: { id: OWNER }, method: 'GET', path: '/overview', query: {}, body: {} });
  assert.equal(r.status, 500); assert.ok(!/secret_table/.test(JSON.stringify(r.body)));
  r = await createHttpLogic({ store: mk({ code: '22023', message: 'a decision note is required' }), hashKey: 'k' }).owner({ user: { id: OWNER }, method: 'GET', path: '/overview', query: {}, body: {} });
  assert.equal(r.status, 400); assert.match(r.body.error, /note is required/);
});
test('http: session beacon stores keyed hashes only, never the raw IP or device id; disabled without a key', async () => {
  const seen = []; const store = { rpc: async (n, a) => { seen.push(a); return {}; } };
  const dev = 'device_ABCDEFGHIJKLMNOP';
  await createHttpLogic({ store, hashKey: 'k'.repeat(32) }).session({ user: { id: U2 }, ip: '203.0.113.9', headers: { 'x-bmn-device': dev } });
  assert.match(seen[0].p_ip_hash, /^[0-9a-f]{64}$/); assert.match(seen[0].p_device_hash, /^[0-9a-f]{64}$/); assert.ok(!JSON.stringify(seen[0]).includes('203.0.113.9') && !JSON.stringify(seen[0]).includes(dev));
  seen.length = 0; const r = await createHttpLogic({ store, hashKey: null }).session({ user: { id: U2 }, ip: '1.2.3.4', headers: { 'x-bmn-device': dev } });
  assert.equal(r.status, 204); assert.equal(seen.length, 0);
  await createHttpLogic({ store, hashKey: 'k'.repeat(32) }).session({ user: { id: U2 }, ip: '1.2.3.4', headers: { 'x-bmn-device': 'short' } }); assert.equal(seen.length, 0);
  const boom = await createHttpLogic({ store: { rpc: async () => { throw new Error('db down'); } }, hashKey: 'k'.repeat(32) }).session({ user: { id: U2 }, ip: '1.2.3.4', headers: { 'x-bmn-device': dev } });
  assert.equal(boom.status, 204, 'the beacon never breaks the app');
});

// ------------------------------------------------------------------ worker (fake store)
function fakeStore(rt, jobs = []) {
  const log = []; const s = { log, rpc: async (n, a) => { log.push([n, a]);
    if (n === 'pi_get_runtime_config') return rt; if (n === 'pi_claim_jobs') { const j = jobs.splice(0); return j; } return null; } }; return s;
}
const RT = (flags = {}, extra = {}) => ({ halted: false, flags: Object.fromEntries(Object.entries(flags).map(([k, v]) => [k, { enabled: v }])), policies: {}, rule_sets: {}, ...extra });
test('worker: everything off -> claims only housekeeping job types, runs no sweepers of disabled features', async () => {
  const st = fakeStore(RT()); const w = createWorker({ store: st, handlers: {}, log: { error() {} } }); await w.tick();
  const claim = st.log.find((x) => x[0] === 'pi_claim_jobs')[1]; assert.ok(!claim.p_types.includes('analyze_content') && !claim.p_types.includes('assess_account') && !claim.p_types.includes('evaluate_verification'));
  assert.ok(!st.log.some((x) => /^pi_enqueue_/.test(x[0]))); assert.ok(st.log.some((x) => x[0] === 'pi_worker_heartbeat'));
});
test('worker: halted -> no sweeping, no claiming', async () => {
  const st = fakeStore(RT({ moderation_analysis: true }, { halted: true })); const w = createWorker({ store: st, handlers: {}, log: { error() {} } }); const r = await w.tick();
  assert.equal(r.halted, true); assert.ok(!st.log.some((x) => x[0] === 'pi_claim_jobs' || /^pi_enqueue_/.test(x[0])));
});
test('worker: success completes the job; a throwing handler is failed (retry) and the worker keeps going', async () => {
  const jobs = [{ id: 'j1', job_type: 'analyze_content', payload: {} }, { id: 'j2', job_type: 'analyze_content', payload: {} }, { id: 'j3', job_type: 'assess_account', payload: {} }];
  const st = fakeStore(RT({ moderation_analysis: true, account_risk_scoring: true }), jobs); let n = 0;
  const w = createWorker({ store: st, log: { error() {} }, handlers: { analyze_content: async () => { if (++n === 1) throw new Error('boom'); return {}; }, assess_account: async () => ({}) } });
  const r = await w.tick(); assert.deepEqual([r.claimed, r.ok, r.failed], [3, 2, 1]);
  const fail = st.log.find((x) => x[0] === 'pi_fail_job'); assert.equal(fail[1].p_job_id, 'j1'); assert.match(fail[1].p_error, /boom/);
  assert.equal(st.log.filter((x) => x[0] === 'pi_complete_job').length, 2);
});
test('worker: ticks never overlap', async () => {
  let release; const gate = new Promise((r) => { release = r; });
  const st = { log: [], rpc: async (n) => { if (n === 'pi_get_runtime_config') { await gate; return RT(); } return n === 'pi_claim_jobs' ? [] : null; } };
  const w = createWorker({ store: st, handlers: {}, log: { error() {} } }); const a = w.tick(); const b = await w.tick(); assert.ok(b.skipped); release(); await a;
});
test('worker: configuration outage is reported, not thrown', async () => {
  const w = createWorker({ store: { rpc: async () => { throw new Error('down'); } }, handlers: {}, log: { error() {} } }); const r = await w.tick(); assert.equal(r.error, 'config unavailable');
});

// ------------------------------------------------------------------ handlers (fake store)
test('handlers: switched-off features skip the job instead of failing it', async () => {
  const h = createHandlers({ store: { rpc: async () => { throw new Error('must not be called'); } } });
  assert.match((await h.analyze_content({ payload: {} }, RT())).skipped, /off/); assert.match((await h.assess_account({ payload: {} }, RT())).skipped, /off/); assert.match((await h.evaluate_verification({ payload: {} }, RT())).skipped, /off/);
});
test('handlers: private messages are never read while message scanning is off', async () => {
  const h = createHandlers({ store: { rpc: async () => { throw new Error('must not be called'); } } });
  const r = await h.analyze_content({ payload: { subject_type: 'message', subject_id: U2 } }, RT({ moderation_analysis: true })); assert.match(r.skipped, /message scanning/);
});
test('handlers: external AI provider is not called for messages, when its flag is off, or when its circuit is open', async () => {
  let providerCalls = 0; const provider = { name: 'p', enabled: true, score: async () => { providerCalls++; return { scores: { harassment_bullying: 0.9 }, model: 'm' }; } };
  const mkStore = (available) => ({ rpc: async (n) => { if (n === 'pi_fetch_subject') return { found: true, user_id: U2, text: 'hello there everyone', account_age_days: 5 }; if (n === 'pi_provider_available') return available; if (n === 'pi_duplicate_count') return { analyses: 0, distinct_users: 0 }; return {}; } });
  const job = { payload: { subject_type: 'post', subject_id: U2 } };
  await createHandlers({ store: mkStore(true), provider }).analyze_content(job, RT({ moderation_analysis: true })); assert.equal(providerCalls, 0, 'ai_providers flag off');
  await createHandlers({ store: mkStore(false), provider }).analyze_content(job, RT({ moderation_analysis: true, ai_providers: true })); assert.equal(providerCalls, 0, 'circuit open');
  await createHandlers({ store: mkStore(true), provider }).analyze_content(job, RT({ moderation_analysis: true, ai_providers: true })); assert.equal(providerCalls, 1);
  await createHandlers({ store: { rpc: async (n) => (n === 'pi_fetch_subject' ? { found: true, user_id: U2, text: 'hello', account_age_days: 5 } : n === 'pi_provider_available' ? true : {}) }, provider }).analyze_content({ payload: { subject_type: 'message', subject_id: U2 } }, RT({ moderation_analysis: true, moderation_message_scanning: true, ai_providers: true }));
  assert.equal(providerCalls, 1, 'messages never go to the provider');
});
test('handlers: a provider failure is reported to the circuit breaker and analysis continues rules-only', async () => {
  const reports = []; const provider = { name: 'p', enabled: true, score: async () => { throw new Error('HTTP 500'); } };
  const store = { rpc: async (n, a) => { if (n === 'pi_fetch_subject') return { found: true, user_id: U2, text: 'hello there everyone', account_age_days: 5 }; if (n === 'pi_provider_available') return true; if (n === 'pi_report_provider') { reports.push(a); return 'degraded'; } if (n === 'pi_duplicate_count') return {}; if (n === 'pi_commit_moderation_result') { reports.push(a.p); return { duplicate: false }; } return {}; } };
  await createHandlers({ store, provider }).analyze_content({ payload: { subject_type: 'post', subject_id: U2 } }, RT({ moderation_analysis: true, ai_providers: true }));
  assert.equal(reports[0].p_ok, false); assert.equal(reports[1].provider, 'bmn_rules');
});
test('handlers: the commit payload only ever carries a safe recommended action and the rule-set version used', async () => {
  let payload; const store = { rpc: async (n, a) => { if (n === 'pi_fetch_subject') return { found: true, user_id: U2, text: 'Guaranteed returns! Double your money, DM me to earn $500 per day https://bit.ly/x', account_age_days: 1 }; if (n === 'pi_duplicate_count') return {}; if (n === 'pi_commit_moderation_result') { payload = a.p; return {}; } return {}; } };
  await createHandlers({ store }).analyze_content({ payload: { subject_type: 'post', subject_id: U2 } }, RT({ moderation_analysis: true }, { policies: POLICIES, rule_sets: { moderation_rules: { version: 4, config: { ...MR, hold_hours: 6 } } } }));
  assert.ok(['no_action', 'flag', 'hide_pending_review', 'refer_to_human'].includes(payload.decision.recommended_action)); assert.equal(payload.rule_set_version, 4); assert.equal(payload.decision.hold_hours, 6);
  assert.ok(!JSON.stringify(payload).toLowerCase().includes('double your money'), 'raw text is never sent to be stored');
});

// ------------------------------------------------------------------ provider adapter (mocked fetch ONLY)
test('openai adapter: maps categories, sends the key only in the header, handles errors and timeouts', async () => {
  let seen; const ok = createOpenAiModeration({ apiKey: 'sk-test', fetchImpl: async (url, o) => { seen = { url, o }; return { ok: true, json: async () => ({ model: 'm1', results: [{ category_scores: { harassment: 0.7, hate: 0.2, 'sexual/minors': 0.01, unknown: 0.9 } }] }) }; } });
  const r = await ok.score('hello'); assert.equal(r.scores.harassment_bullying, 0.7); assert.equal(r.scores.hate_speech, 0.2); assert.ok(!('unknown' in r.scores));
  assert.equal(seen.o.headers.authorization, 'Bearer sk-test'); assert.ok(!seen.o.body.includes('sk-test'));
  await assert.rejects(createOpenAiModeration({ apiKey: 'k', fetchImpl: async () => ({ ok: false, status: 429 }) }).score('x'), /HTTP 429/);
  await assert.rejects(createOpenAiModeration({ apiKey: 'k', fetchImpl: async () => ({ ok: true, json: async () => ({}) }) }).score('x'), /unexpected/);
  await assert.rejects(createOpenAiModeration({ apiKey: 'k', timeoutMs: 20, fetchImpl: (u, o) => new Promise((_, rej) => o.signal.addEventListener('abort', () => rej(new Error('aborted')))) }).score('x'), /aborted/);
  assert.equal(createOpenAiModeration({}).enabled, false); await assert.rejects(createOpenAiModeration({}).score('x'), /not configured/);
});

// ------------------------------------------------------------------ misc
test('store: maps database error codes to safe statuses', async () => {
  const mk = (code) => createStore({ rpc: async () => ({ data: null, error: { code, message: 'm' } }) });
  for (const [c, s] of [['42501', 403], ['22023', 400], ['P0002', 404], ['P0001', 409], ['55000', 409], ['XX000', 500]]) await assert.rejects(mk(c).rpc('f'), (e) => e.status === s);
  assert.ok(isUuid(OWNER));
});
