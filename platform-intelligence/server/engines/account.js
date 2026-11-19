'use strict';
// Account-protection engine: activity counts + session facts -> risk score, level, reason codes, events, and (at most)
// TEMPORARY protective restrictions with an expiry. It never recommends a ban, suspension, deletion or verification change.
// Every limit is owner-configurable (account_risk_rules.limits). A signal fires when a count reaches its limit; the further
// above the limit, the heavier the signal.
const { noisyOr, clamp, round4 } = require('../lib/util');
const { SAFE_ACCOUNT_ACTIONS } = require('../rules/defaults');

// metric -> [limit key, reason code, category, event type, base weight, restriction type|null]
const METRICS = [
  ['follows_1h', 'follows_1h', 'mass_follow', 'mass_follow', 0.45, 'limit_follows'],
  ['follows_24h', 'follows_24h', 'mass_follow', 'mass_follow', 0.35, 'limit_follows'],
  ['posts_1h', 'posts_1h', 'posting_burst', 'spam_burst', 0.4, 'limit_posting'],
  ['comments_1h', 'comments_1h', 'comment_burst', 'spam_burst', 0.35, 'limit_posting'],
  ['duplicate_comments_24h', 'duplicate_comments_24h', 'duplicate_comments', 'spam_burst', 0.5, 'limit_posting'],
  ['messages_1h', 'messages_1h', 'message_flood', 'spam_burst', 0.4, 'limit_messaging'],
  ['message_recipients_1h', 'message_recipients_1h', 'message_fanout', 'spam_burst', 0.45, 'limit_messaging'],
  ['likes_1h', 'likes_1h', 'like_burst', 'automated_engagement', 0.3, null],
  ['ips_24h', 'ips_24h', 'many_networks', 'suspicious_login', 0.35, 'require_reauthentication'],
  ['devices_24h', 'devices_24h', 'many_devices', 'suspicious_login', 0.35, 'require_reauthentication'],
  ['shared_device_accounts_7d', 'shared_device_accounts_7d', 'shared_device', 'coordinated_abuse', 0.35, null],
  ['reporters_7d', 'reporters_7d', 'reported_by_many', 'unusual_activity', 0.4, null],
  ['violations_90d', 'violations_90d', 'repeated_violation', 'repeated_violation', 0.45, null]
];

function levelFor(score, th) {
  if (score >= th.critical) return 'critical';
  if (score >= th.high) return 'high';
  if (score >= th.medium) return 'medium';
  return 'low';
}

/**
 * @param {object} a  pi_user_activity_summary() result (+ optional session: {new_ip,new_device,users_on_ip_24h,users_on_device_7d})
 * @param {object} rules account_risk_rules config
 * @param {object} ctx { restrictionsEnforceable:boolean, bucket:string }
 */
function assess(a, rules, ctx = {}) {
  const lim = rules.limits || {};
  const th = rules.level_thresholds || { medium: 0.3, high: 0.55, critical: 0.8 };
  const signals = [];
  for (const [metric, limitKey, code, , base] of METRICS) {
    const value = Number(a[metric]); const limit = Number(lim[limitKey]);
    if (!Number.isFinite(value) || !Number.isFinite(limit) || limit < 1 || value < limit) continue;
    const ratio = value / limit;                                   // 1.0 = exactly at the limit
    const weight = round4(clamp(base * (0.7 + 0.3 * Math.min(ratio, 3)), 0.1, 0.9));
    signals.push({ code, metric, value, limit, weight, detail: `${metric} = ${value} (limit ${limit})` });
  }
  const newDays = Number(lim.new_account_days) || 2;
  const young = Number(a.account_age_days) < newDays;
  // a brand-new account behaving in bursts is more suspicious than an established one; this only amplifies existing signals
  if (young && signals.length) signals.push({ code: 'new_account_activity', metric: 'account_age_days', value: round4(Number(a.account_age_days) || 0), limit: newDays, weight: 0.2, detail: `account is under ${newDays} day(s) old` });
  const s = ctx.session || {};
  if (Number(s.users_on_ip_24h) >= 6) signals.push({ code: 'many_accounts_one_network', metric: 'users_on_ip_24h', value: Number(s.users_on_ip_24h), limit: 6, weight: 0.2, detail: `${s.users_on_ip_24h} accounts used this network in 24h` });

  let score = signals.length ? noisyOr(signals.map((x) => x.weight)) : 0;
  if (a.verified && score > 0) score = round4(score * 0.85);      // established standing lowers, never removes, concern
  const level = levelFor(score, th);
  const reason_codes = [...new Set(signals.map((x) => x.code))];
  const distinct = reason_codes.filter((c) => c !== 'new_account_activity').length;
  // heuristic confidence: grows with the number of independent behaviours, never above 0.9
  const confidence = signals.length ? round4(clamp(0.35 + 0.15 * Math.min(distinct, 3) + 0.2 * Math.max(...signals.map((x) => x.weight)), 0.3, 0.9)) : 0.6;

  const explanation = level === 'low' && !signals.length
    ? 'No unusual activity against the configured limits.'
    : `Risk ${level} (${score}): ` + signals.slice(0, 4).map((x) => x.detail).join('; ') + '.';

  const events = [];
  const seenEvent = new Set();
  for (const [metric, , code, event] of METRICS) {
    const sig = signals.find((x) => x.metric === metric);
    if (!sig || seenEvent.has(event) || level === 'low') continue;
    seenEvent.add(event);
    events.push({ event_type: event, severity: sig.weight >= 0.5 ? 'high' : 'medium', source: 'bmn_rules', details: { reason: code, value: sig.value, limit: sig.limit },
                  dedupe_key: `ev:${a.user_id}:${event}:${ctx.bucket || 'b'}` });
  }

  const hours = clamp(Math.round(Number(rules.restriction_hours) || 24), 1, 72);
  const restrictions = [];
  if (level === 'high' || level === 'critical') {
    const seen = new Set();
    for (const [metric, , code, , , rtype] of METRICS) {
      if (!rtype || seen.has(rtype) || !signals.some((x) => x.metric === metric)) continue;
      seen.add(rtype); restrictions.push({ restriction_type: rtype, reason_code: code, hours });
    }
  }

  let action = 'no_action';
  if (level === 'medium') action = 'flag';
  else if (level === 'high' || level === 'critical') action = restrictions.length ? 'restrict_temporary' : 'refer_to_human';
  if (!SAFE_ACCOUNT_ACTIONS.includes(action)) throw new Error('engine produced an unsafe action: ' + action);

  const open_investigation = level === 'high' || level === 'critical' || (level === 'medium' && distinct >= 2);
  const mode = ctx.restrictionsEnforceable ? 'enforced' : 'shadow';
  return {
    risk_level: level, risk_score: score, confidence, reason_codes, signals, explanation, events, restrictions, open_investigation,
    decision: { recommended_action: action, mode, requires_human_review: level === 'high' || level === 'critical' || open_investigation, reasons: signals.slice(0, 5).map((x) => x.detail),
                inputs: { thresholds: th, restriction_hours: hours, restrictions_enforceable: !!ctx.restrictionsEnforceable } }
  };
}

module.exports = { assess, METRICS, levelFor };
