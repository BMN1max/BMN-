'use strict';
// Verification evaluation: checks a pending request against the RECORDED criteria. It can say "eligible for auto approval",
// "needs human review" or "insufficient evidence". It can NEVER reject or revoke: the worst outcome is a human review.
// The database makes the final decision on whether to approve automatically (flags, owner delegation, history gates).
const T = require('../lib/text');
const LEVELS = ['low', 'medium', 'high', 'critical'];
const pass = (id, type, detail) => ({ check: type, id, result: 'pass', detail });
const fail = (id, type, detail) => ({ check: type, id, result: 'fail', detail });
const review = (id, type, detail) => ({ check: type, id, result: 'needs_review', detail });

function runCheck(c, f, verifiedNames) {
  const v = Number(c.value);
  switch (c.type) {
    case 'min_account_age_days': return Number(f.account_age_days) >= v ? pass(c.id, c.type, `account age ${Math.floor(f.account_age_days)}d >= ${v}d`) : fail(c.id, c.type, `account age ${Math.floor(f.account_age_days || 0)}d < ${v}d`);
    case 'profile_complete': return f.profile?.exists && f.profile.has_avatar && f.profile.has_bio && f.profile.display_name ? pass(c.id, c.type, 'avatar, bio and name present') : fail(c.id, c.type, 'avatar, bio or name missing');
    case 'min_published_posts': return Number(f.published_posts) >= v ? pass(c.id, c.type, `${f.published_posts} published posts >= ${v}`) : fail(c.id, c.type, `${f.published_posts} published posts < ${v}`);
    case 'min_followers': return Number(f.followers) >= v ? pass(c.id, c.type, `${f.followers} followers >= ${v}`) : fail(c.id, c.type, `${f.followers} followers < ${v}`);
    case 'good_standing': return f.account_status === 'active' && Number(f.violations_180d) === 0 && Number(f.active_restrictions) === 0 && !f.fraud_history && Number(f.prior_rejections) === 0
      ? pass(c.id, c.type, 'active, no recent violations, restrictions, fraud record or earlier rejection') : fail(c.id, c.type, 'status, recent violations, restrictions, fraud record or earlier rejection');
    case 'max_account_risk': { const max = LEVELS.indexOf(c.level || 'medium'); const cur = f.current_risk_level ? LEVELS.indexOf(f.current_risk_level) : -1;
      return cur <= max ? pass(c.id, c.type, `risk ${f.current_risk_level || 'not assessed'} within ${c.level || 'medium'}`) : fail(c.id, c.type, `risk ${f.current_risk_level} above ${c.level || 'medium'}`); }
    case 'no_open_cases': return Number(f.open_cases) === 0 ? pass(c.id, c.type, 'no open moderation case') : fail(c.id, c.type, `${f.open_cases} open case(s)`);
    case 'evidence_link_present': return f.request?.evidence_url ? pass(c.id, c.type, 'evidence link supplied') : fail(c.id, c.type, 'no evidence link');
    case 'manual_evidence_review': return review(c.id, c.type, 'a person must look at the supplied evidence');   // never auto-passes
    case 'impersonation_screen': {
      let best = 0;
      for (const n of verifiedNames) for (const m of [f.profile?.username, f.profile?.display_name]) for (const t of [n.username, n.display_name]) { if (T.nameKey(t).length >= 4) best = Math.max(best, T.nameSimilarity(m, t)); }
      return best >= 0.85 ? fail(c.id, c.type, 'name is very similar to an existing verified account') : pass(c.id, c.type, 'no look-alike of a verified account');
    }
    default: return review(c.id, c.type, 'unknown check type: handled by a person');
  }
}

function impersonationRisk(f, names) {
  let best = 0;
  for (const n of names) for (const m of [f.profile?.username, f.profile?.display_name]) for (const t of [n.username, n.display_name]) if (T.nameKey(t).length >= 4) best = Math.max(best, T.nameSimilarity(m, t));
  return Math.round(best * 10000) / 10000;
}

/** @param {object} facts pi_verification_facts() result; @param {object} criteria {checks:[...]} */
function evaluate(facts, criteria) {
  if (!facts || !facts.found) return { skip: true, reason: 'request not found' };
  const names = facts.verified_names || [];
  const all = (criteria.checks || []).map((c) => ({ c, r: runCheck(c, facts, names) }));
  const required = all.filter((x) => x.c.required);
  const stored = required.map((x) => ({ check: x.r.check, id: x.r.id, result: x.r.result, detail: x.r.detail }));
  const optional = all.filter((x) => !x.c.required).map((x) => ({ check: x.r.check, id: x.r.id, result: x.r.result, detail: x.r.detail }));
  let outcome;
  if (!stored.length) outcome = 'insufficient_evidence';
  else if (stored.every((x) => x.result === 'pass')) outcome = 'eligible_for_auto_approval';
  else if (stored.some((x) => x.result === 'fail')) outcome = 'needs_human_review';
  else outcome = 'needs_human_review';
  if (facts.already_verified && outcome === 'eligible_for_auto_approval') outcome = 'needs_human_review';
  return { outcome, checks: stored, optional_checks: optional, impersonation_risk: impersonationRisk(facts, names) };
}
module.exports = { evaluate, runCheck };
