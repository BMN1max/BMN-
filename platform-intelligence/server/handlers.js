'use strict';
// Job handlers. Each handler: re-reads the live configuration, checks the feature flags itself (a switched-off feature completes the
// job as "skipped" instead of burning retries), does the work, and commits through ONE database function (atomic + idempotent).
const moderation = require('./engines/moderation');
const account = require('./engines/account');
const verification = require('./engines/verification');
const { activeRules } = require('./rules/defaults');
const { isUuid, PiError } = require('./lib/util');

const flagOn = (rt, k) => !rt.halted && !!rt.flags?.[k]?.enabled;
const SUBJECTS = ['post', 'comment', 'message', 'profile'];

function createHandlers({ store, provider = null, now = () => Date.now(), log = () => {} }) {
  let namesCache = { at: 0, list: [] };
  async function verifiedNames() {
    if (now() - namesCache.at > 5 * 60 * 1000) namesCache = { at: now(), list: (await store.rpc('pi_verified_names', { p_limit: 2000 })) || [] };
    return namesCache.list;
  }

  async function analyze_content(job, rt) {
    if (!flagOn(rt, 'moderation_analysis')) return { skipped: 'moderation analysis is off' };
    const p = job.payload || {};
    if (!SUBJECTS.includes(p.subject_type) || !isUuid(p.subject_id)) throw new PiError('bad analyze_content payload', { status: 400, code: 'invalid' });
    if (p.subject_type === 'message' && !flagOn(rt, 'moderation_message_scanning')) return { skipped: 'message scanning is off' };
    const subj = await store.rpc('pi_fetch_subject', { p_type: p.subject_type, p_id: p.subject_id });
    if (!subj || !subj.found) return { skipped: subj?.reason || 'subject not found' };
    const rules = activeRules(rt, 'moderation_rules');
    const source = p.source === 'user_report' ? 'user_report' : 'automated';

    // optional AI provider: never for private messages, only when the owner has enabled `ai_providers`, and only if its circuit is closed
    let providerScores = null, providerName = null, model = null, providerError = null;
    if (provider && provider.enabled && flagOn(rt, 'ai_providers') && p.subject_type !== 'message' && String(subj.text || '').trim().length >= 3) {
      const usable = await store.rpc('pi_provider_available', { p_provider: provider.name });
      if (usable) {
        try { const r = await provider.score(String(subj.text).slice(0, rules.config.max_text_length || 5000)); providerScores = r.scores; providerName = provider.name; model = r.model;
              await store.rpc('pi_report_provider', { p_provider: provider.name, p_ok: true }); }
        catch (e) { providerError = String(e.message || e).slice(0, 200); await store.rpc('pi_report_provider', { p_provider: provider.name, p_ok: false, p_error: providerError }); }
      }
    }
    const meta = { account_age_days: subj.account_age_days, author_verified: subj.author_verified, author_posts_1h: subj.author_posts_1h, has_media: subj.has_media, tag_count: subj.tag_count,
                   username: subj.username, display_name: subj.display_name, verified: subj.verified, is_owner: subj.is_owner, user_id: subj.user_id };
    const input = { subjectType: p.subject_type, text: subj.text, source, reportReason: p.report_reason, meta, verifiedNames: p.subject_type === 'profile' ? await verifiedNames() : [], providerScores: providerScores || {}, providerName };
    let a = moderation.analyze(input, rules.config);
    const dup = await store.rpc('pi_duplicate_count', { p_hash: a.contentHash });
    if (dup && (Number(dup.distinct_users) >= 3 || Number(dup.analyses) >= 4)) a = moderation.analyze({ ...input, duplicates: dup }, rules.config);
    const d = moderation.decide(a, { subjectType: p.subject_type, source, policies: rt.policies, rules: rules.config, enforcementAvailable: !!rt.enforcement_available });
    const key = `analysis:${p.subject_type}:${p.subject_id}:${a.contentHash.slice(0, 32)}` + (source === 'user_report' ? `:report:${p.report_id || 'x'}` : '');
    const res = await store.rpc('pi_commit_moderation_result', {
      p: { idempotency_key: key, subject_type: p.subject_type, subject_id: p.subject_id, subject_user_id: subj.user_id, source, report_id: p.report_id || null,
           top_category: a.topCategory, outcome: d.outcome, risk_score: a.risk, confidence: a.confidence, content_hash: a.contentHash, content_length: a.contentLength,
           provider: providerName || 'bmn_rules', model, rule_set_version: rules.version, category_scores: a.categoryScores, error: providerError,
           decision: { recommended_action: d.recommended_action, mode: d.mode, requires_human_review: d.requires_human_review, hold_hours: d.hold_hours, case_priority: d.case_priority,
                       reasons: d.reasons, inputs: d.inputs, user_visible_reason: d.user_visible_reason } } });
    return res || {};
  }

  async function assess_account(job, rt) {
    if (!flagOn(rt, 'account_risk_scoring')) return { skipped: 'account risk scoring is off' };
    const uid = job.payload?.user_id;
    if (!isUuid(uid)) throw new PiError('bad assess_account payload', { status: 400, code: 'invalid' });
    const sum = await store.rpc('pi_user_activity_summary', { p_user: uid });
    if (!sum || !sum.account_exists) return { skipped: 'account no longer exists' };
    const rules = activeRules(rt, 'account_risk_rules');
    const ws = activeRules(rt, 'worker_settings').config;
    const mins = Number(ws.assess_interval_minutes) || 30;
    const bucket = Math.floor(now() / (mins * 60000));
    const r = account.assess(sum, rules.config, { restrictionsEnforceable: !!rt.restrictions_enforceable, bucket: String(bucket) });
    const res = await store.rpc('pi_commit_account_assessment', { p: { idempotency_key: `assess:${uid}:${bucket}`, user_id: uid, rule_set_version: rules.version, ...r } });
    return res || {};
  }

  async function evaluate_verification(job, rt) {
    if (!flagOn(rt, 'verification_evaluation')) return { skipped: 'verification evaluation is off' };
    const rid = job.payload?.request_id;
    if (!isUuid(rid)) throw new PiError('bad evaluate_verification payload', { status: 400, code: 'invalid' });
    const facts = await store.rpc('pi_verification_facts', { p_request_id: rid });
    if (!facts || !facts.found) return { skipped: 'request not found' };
    if (facts.request.status !== 'pending') return { skipped: 'request is no longer pending' };
    const crit = activeRules(rt, 'verification_criteria');
    const ev = verification.evaluate(facts, crit.config);
    if (ev.skip) return { skipped: ev.reason };
    return (await store.rpc('pi_commit_verification_evaluation', { p: { request_id: rid, criteria_version: crit.version, outcome: ev.outcome, checks: ev.checks, impersonation_risk: ev.impersonation_risk, force: !!job.payload?.force } })) || {};
  }

  async function reverse_action(job) {
    if (!isUuid(job.payload?.action_id)) throw new PiError('bad reverse_action payload', { status: 400, code: 'invalid' });
    return (await store.rpc('pi_apply_reversal', { p_action_id: job.payload.action_id })) || {};
  }
  async function provider_healthcheck() {
    if (!provider || !provider.enabled) return { skipped: 'no provider configured' };
    try { await provider.score('hello'); await store.rpc('pi_report_provider', { p_provider: provider.name, p_ok: true }); return { ok: true }; }
    catch (e) { await store.rpc('pi_report_provider', { p_provider: provider.name, p_ok: false, p_error: String(e.message || e).slice(0, 200) }); return { ok: false }; }
  }
  async function purge_retention() { return (await store.rpc('pi_purge_retention', {})) || {}; }
  async function expire_restrictions() { return (await store.rpc('pi_expire_automated', {})) || {}; }
  async function apply_action() { return { skipped: 'actions are applied only by authorised human decisions in this version' }; }

  return { analyze_content, assess_account, evaluate_verification, reverse_action, provider_healthcheck, purge_retention, expire_restrictions, apply_action };
}
module.exports = { createHandlers };
