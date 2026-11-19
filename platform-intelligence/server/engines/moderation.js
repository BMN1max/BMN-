'use strict';
// Content moderation engine: text + metadata analysis -> category scores, risk, confidence, outcome and a RECOMMENDATION.
//
// HONEST LIMITS (also shown to the owner in the console):
//  * This is a rule engine. It finds spam / scam / phishing, threats, insults, engagement manipulation, dangerous-goods phrases and
//    impersonation by explicit patterns and metadata. It does NOT claim to detect hate speech, sexual content or exploitation:
//    those categories are only populated from (a) owner-supplied custom terms, (b) user reports, (c) the optional AI provider.
//  * "confidence" is a heuristic that grows with the amount and independence of evidence. It is NOT a calibrated probability.
//  * A "clear" result means "no rule matched", never "proven safe", and its confidence is capped accordingly.
//  * The engine only ever recommends no_action / flag / hide_pending_review / refer_to_human. It cannot recommend removal, ban,
//    suspension or revoking verification, and the database would reject those anyway.
const { noisyOr, clamp, round4 } = require('../lib/util');
const T = require('../lib/text');
const { SAFE_CONTENT_ACTIONS } = require('../rules/defaults');

const sig = (code, category, weight, detail) => ({ code, category, weight, detail });

// [pattern on deobfuscated text, weight, code, category]
const PHRASES = [
  [/\b(?:guarantee[d]?|risk[- ]?free)\s+(?:returns?|profits?|income)\b/, 0.55, 'guaranteed_returns', 'spam_scams'],
  [/\bdouble\s+your\s+(?:money|crypto|bitcoin|investment)\b/, 0.6, 'double_your_money', 'spam_scams'],
  [/\b(?:send|give)\s+me\s+(?:your\s+)?(?:crypto|bitcoin|btc|usdt|gift\s?cards?)\b/, 0.6, 'send_me_money', 'spam_scams'],
  [/\b(?:seed\s+phrase|recovery\s+phrase|private\s+key|wallet\s+key)\b/, 0.55, 'wallet_secret', 'spam_scams'],
  [/\b(?:claim|collect)\s+your\s+(?:prize|reward|winnings|free\s+\w+)\b/, 0.45, 'claim_prize', 'spam_scams'],
  [/\byou(?:'ve| have)?\s+(?:been\s+)?(?:won|selected\s+(?:as|for)\s+(?:a\s+)?winner)\b/, 0.4, 'you_won', 'spam_scams'],
  [/\b(?:dm|message|text|whatsapp)\s+me\s+(?:to|for)\s+(?:earn|invest|make\s+money|get\s+rich|get\s+started)\b/, 0.5, 'dm_to_earn', 'spam_scams'],
  [/\b(?:make|earn)\s+\$?\d[\d,]*\s*(?:k|usd|dollars|naira|per\s+(?:day|week|hour))\b/, 0.35, 'earn_amount', 'spam_scams'],
  [/\b(?:investment|forex|crypto)\s+(?:opportunity|signals?|mentor|expert)\b/, 0.25, 'investment_pitch', 'spam_scams'],
  [/\bverify\s+your\s+(?:account|identity|wallet|bank)\b[^.]{0,40}\b(?:link|click|here|below)\b/, 0.55, 'phishing_verify', 'spam_scams'],
  [/\b(?:your\s+account\s+(?:has\s+been|will\s+be)\s+(?:suspended|locked|closed|deleted|banned))\b/, 0.5, 'account_threat_lure', 'spam_scams'],
  [/\b(?:send|share|give)\s+(?:me\s+)?(?:your\s+)?(?:password|otp|one[- ]time\s+(?:code|password)|pin\s+code|verification\s+code)\b/, 0.7, 'credential_request', 'spam_scams'],
  [/\b(?:click|tap|open)\s+(?:the\s+|this\s+)?(?:link|here)\b[^.]{0,30}\b(?:win|claim|earn|verify|free|urgent)\b/, 0.35, 'click_lure', 'spam_scams'],
  [/\b(?:western\s+union|moneygram|cash\s?app|zelle)\b[^.]{0,40}\b(?:send|pay|deposit|transfer)\b/, 0.3, 'untraceable_payment', 'spam_scams'],

  [/\b(?:follow\s*(?:for|4)\s*follow|f4f|sub\s*(?:for|4)\s*sub|like\s*(?:for|4)\s*like|l4l|follow\s+back\s+(?:guaranteed|100))\b/, 0.5, 'follow_swap', 'manipulated_engagement'],
  [/\b(?:buy|get|sell|cheap|free)\s+(?:\d[\d,]*\s*)?(?:followers|likes|views|subscribers|comments)\b/, 0.55, 'buy_engagement', 'manipulated_engagement'],
  [/\b(?:engagement\s+(?:pod|group)|boost\s+your\s+(?:followers|views|likes))\b/, 0.4, 'engagement_pod', 'manipulated_engagement'],

  [/\bi(?:'ll| will| am going to|'m going to|'m gonna| am gonna)\s+(?:kill|murder|stab|shoot|hurt|beat\s+up)\s+(?:you|u|him|her|them)\b/, 0.8, 'direct_threat', 'threats_violence'],
  [/\b(?:i(?:'ll| will)\s+find\s+(?:you|where\s+you\s+live)|know\s+where\s+you\s+live)\b/, 0.6, 'stalking_threat', 'threats_violence'],
  [/\b(?:bomb|shoot\s+up|massacre)\s+(?:the|this|that|your)\s+(?:school|church|mosque|mall|office|building|event)\b/, 0.8, 'mass_violence_threat', 'threats_violence'],
  [/\b(?:you\s+(?:should|deserve\s+to|need\s+to)\s+die|go\s+die|hope\s+you\s+die)\b/, 0.55, 'wish_death', 'threats_violence'],
  [/\b(?:kill\s+yourself|kys|go\s+hang\s+yourself|end\s+yourself)\b/, 0.7, 'self_harm_encouragement', 'harassment_bullying'],

  [/\byou(?:'re| are)?\s+(?:so\s+|such\s+an?\s+|a\s+)?(?:stupid|idiot|dumb|ugly|worthless|useless|pathetic|loser|trash|disgusting|moron)\b/, 0.35, 'insult_you', 'harassment_bullying'],
  [/\b(?:nobody|no\s+one)\s+(?:likes|wants|loves|cares\s+about)\s+you\b/, 0.35, 'belittle', 'harassment_bullying'],
  [/\b(?:shut\s+up|go\s+away)\s+(?:you|and)\b/, 0.2, 'dismissive', 'harassment_bullying'],

  [/\b(?:buy|sell|selling|get)\s+(?:cocaine|heroin|meth|mdma|molly|lsd|fentanyl|xanax|codeine|tramadol|weed|cannabis)\b/, 0.5, 'drug_sale', 'dangerous_prohibited'],
  [/\b(?:fake|forged|counterfeit)\s+(?:id|passport|license|licence|money|notes|currency|documents?)\b[^.]{0,30}\b(?:sale|sell|buy|available|order)\b/, 0.55, 'fake_documents', 'dangerous_prohibited'],
  [/\b(?:ak[- ]?47|ar[- ]?15|glock|firearms?|guns?)\b[^.]{0,30}\b(?:for\s+sale|selling|available|order\s+now)\b/, 0.5, 'weapon_sale', 'dangerous_prohibited']
];

const REPORT_REASON_TO_CATEGORY = [
  [/spam|scam|fraud|fake\s+(?:giveaway|offer)|phish/, 'spam_scams'],
  [/harass|bully|abus|insult/, 'harassment_bullying'],
  [/hate|racis|discriminat/, 'hate_speech'],
  [/violen|threat|self[- ]?harm|danger/, 'threats_violence'],
  [/nud|sexual|adult|porn/, 'prohibited_sexual_content'],
  [/imperson|fake\s+(?:account|profile)|pretend/, 'impersonation'],
  [/drug|weapon|illegal|prohibit/, 'dangerous_prohibited'],
  [/engagement|bot|follow|view/, 'manipulated_engagement']
];

function categoryForReport(reason) {
  const r = String(reason || '').toLowerCase();
  for (const [re, cat] of REPORT_REASON_TO_CATEGORY) if (re.test(r)) return cat;
  return null;
}

// Look-alike of a verified account name (impersonation) + officialdom words used by unverified accounts.
const OFFICIAL_WORDS = /(?:official|support|helpdesk|admin|moderator|staff|team|customer\s?care|security)/;
function impersonationSignals({ username, display_name, verified, is_owner, user_id }, verifiedNames, rules) {
  const out = [];
  if (verified || is_owner) return out;
  const keys = [username, display_name].map(T.nameKey).filter(Boolean);
  let best = { sim: 0, who: null };
  for (const v of verifiedNames || []) {
    if (!v || v.user_id === user_id) continue;
    for (const mine of [username, display_name]) for (const theirs of [v.username, v.display_name]) {
      const sim = T.nameSimilarity(mine, theirs);
      if (sim > best.sim && T.nameKey(theirs).length >= 4) best = { sim, who: v.username || v.display_name };
    }
  }
  if (best.sim >= 0.999) out.push(sig('lookalike_exact', 'impersonation', 0.75, 'same name as a verified account once symbols and look-alike characters are ignored'));
  else if (best.sim >= 0.85) out.push(sig('lookalike_close', 'impersonation', 0.55, 'name is one or two characters away from a verified account'));
  const joined = keys.join(' ');
  if (OFFICIAL_WORDS.test(joined) && (/bmn/.test(joined) || /(?:official|support|admin)/.test(joined))) out.push(sig('official_claim', 'impersonation', /bmn/.test(joined) ? 0.45 : 0.25, 'name presents the account as official / staff / support'));
  return out;
}

/**
 * @param {object} i  { subjectType, text, source, reportReason, meta:{account_age_days, author_verified, author_posts_1h, has_media, tag_count, username, display_name, verified, is_owner, user_id},
 *                      duplicates:{analyses, distinct_users}, verifiedNames:[], providerScores:{category:score}, providerName }
 * @param {object} rules  moderation_rules config
 */
function analyze(i, rules) {
  const maxLen = Number(rules.max_text_length) || 5000;
  const raw = String(i.text || '');
  const norm = T.normalizeText(raw, maxLen);
  const deob = T.deobfuscate(norm);
  const mult = rules.signal_weights || {};
  const signals = [];
  const add = (s) => { if (!s) return; const m = mult[s.code]; const w = clamp(s.weight * (typeof m === 'number' ? m : 1), 0, 0.95); if (w > 0) signals.push({ ...s, weight: round4(w) }); };
  const meta = i.meta || {};

  for (const [re, w, code, cat] of PHRASES) if (re.test(deob) || re.test(norm)) add(sig(code, cat, w, 'phrase pattern matched'));

  // links
  const urls = T.countUrls(norm);
  const young = Number(meta.account_age_days) < 3;
  if (urls >= 4) add(sig('many_links', 'spam_scams', 0.35, `${urls} links in one item`));
  else if (urls >= 2) add(sig('several_links', 'spam_scams', 0.12, `${urls} links`));
  if (urls >= 1 && T.hasShortener(norm)) add(sig('shortened_link', 'spam_scams', 0.25, 'link shortener used'));
  if (urls >= 1 && young && !meta.author_verified) add(sig('new_account_link', 'spam_scams', 0.15, 'link posted by an account under 3 days old'));

  // shape of the text
  const words = T.wordList(norm);
  if (T.repetitionRatio(words) > 0.55) add(sig('repetitive_text', 'spam_scams', 0.25, 'most words repeat'));
  if (T.capsRatio(raw) > 0.8) add(sig('shouting', 'harassment_bullying', 0.1, 'text is almost entirely capitals'));
  if (/(.)\1{9,}/.test(norm)) add(sig('character_flood', 'spam_scams', 0.2, 'long run of one character'));
  if (Number(meta.tag_count) >= 20) add(sig('tag_stuffing', 'manipulated_engagement', 0.3, `${meta.tag_count} tags`));
  if (Number(meta.author_posts_1h) >= 15) add(sig('posting_burst', 'spam_scams', 0.3, `${meta.author_posts_1h} posts in the last hour`));

  // the same text seen elsewhere (hash match, no text stored)
  const d = i.duplicates || {};
  if (Number(d.distinct_users) >= 3) add(sig('duplicate_across_accounts', 'spam_scams', 0.5, `identical content from ${d.distinct_users} accounts in 24h`));
  else if (Number(d.analyses) >= 4 && Number(d.distinct_users) <= 1) add(sig('duplicate_from_one_account', 'spam_scams', 0.3, `identical content ${d.analyses} times in 24h`));

  // impersonation (profiles)
  if (i.subjectType === 'profile') for (const s of impersonationSignals({ ...meta }, i.verifiedNames, rules)) add(s);

  // owner-defined terms, per category
  for (const [cat, list] of Object.entries(rules.custom_terms || {})) {
    for (const t of list || []) {
      const term = T.normalizeText(t.term, 80);
      if (term.length >= 2 && new RegExp(`(?:^|[^\\p{L}\\p{N}])${T.escapeRe(term)}(?:$|[^\\p{L}\\p{N}])`, 'u').test(norm)) add(sig('custom_term', cat, Number(t.weight) || 0.5, 'owner-defined term matched'));
    }
  }

  // optional AI provider scores (already mapped onto BMN categories by the adapter)
  for (const [cat, score] of Object.entries(i.providerScores || {})) {
    if (Number(score) >= 0.2) add(sig('provider:' + (i.providerName || 'ai'), cat, clamp(Number(score), 0, 0.95), 'AI provider score'));
  }

  // a user report is evidence that a person is worried: it raises review priority, it does not convict
  if (i.source === 'user_report') {
    const rc = categoryForReport(i.reportReason);
    if (rc) add(sig('user_report', rc, 0.3, 'a user reported this item'));
  }

  // per category: noisy-or of the signal weights
  const byCat = {};
  for (const s of signals) (byCat[s.category] ||= []).push(s.weight);
  const categoryScores = {};
  for (const [c, ws] of Object.entries(byCat)) categoryScores[c] = noisyOr(ws);
  const cats = Object.entries(categoryScores).sort((a, b) => b[1] - a[1]);
  const top = cats[0] || [null, 0];
  const risk = cats.length ? top[1] : 0;

  // heuristic confidence (see header)
  const topSignals = signals.filter((s) => s.category === top[0]);
  const strong = topSignals.reduce((m, s) => Math.max(m, s.weight), 0);
  const independent = new Set(topSignals.map((s) => s.code.split(':')[0])).size;
  let confidence;
  if (!signals.length) confidence = norm.length >= 20 ? 0.65 : 0.5;         // "nothing matched" is never certainty
  else confidence = clamp(0.3 + 0.12 * Math.min(independent, 4) + 0.35 * strong, 0.3, 0.95);

  return {
    normalizedText: norm,
    contentHash: T.contentHash(i.subjectType, norm),
    contentLength: raw.length,
    categoryScores,
    topCategory: top[0],
    risk: round4(risk),
    confidence: round4(confidence),
    signals: signals.sort((a, b) => b.weight - a.weight)
  };
}

/**
 * Turn an analysis + the live policy into an outcome and a recommendation. Pure function of its inputs.
 * @param {object} a  result of analyze()
 * @param {object} p  { subjectType, source, policies (runtime.policies), rules (moderation_rules config), enforcementAvailable }
 */
function decide(a, p) {
  const rules = p.rules || {};
  const pol = a.topCategory ? p.policies?.[a.topCategory] : null;
  const minConf = Number(rules.min_confidence_auto) || 0.6;
  const review = pol && pol.review_threshold != null ? Number(pol.review_threshold) : 0.5;
  const auto = pol && pol.auto_action_threshold != null ? Number(pol.auto_action_threshold) : null;
  const holdHours = clamp(Math.round(Number(rules.hold_hours) || 24), 1, 72);
  const reasons = a.signals.slice(0, 5).map((s) => `${s.code} (${s.category}, ${s.weight}): ${s.detail}`);
  const out = { outcome: 'clear', recommended_action: 'no_action', mode: p.enforcementAvailable ? 'enforced' : 'shadow', requires_human_review: false, hold_hours: holdHours, case_priority: 3, reasons, inputs: {}, user_visible_reason: null };
  out.inputs = { category: a.topCategory, policy_enabled: !!pol?.enabled, review_threshold: review, auto_action_threshold: auto, min_confidence_auto: minConf,
                 max_auto_action: pol?.max_auto_action || 'none', always_human_review: !!pol?.always_human_review, policy_version: pol?.version || null };

  if (!a.topCategory || a.risk < review) {
    out.reasons = a.topCategory ? reasons.concat([`risk ${a.risk} is below the review threshold ${review}`]) : ['no rule matched'];
    return out;
  }
  out.outcome = auto != null && a.risk >= auto && a.confidence >= minConf ? 'violation_likely' : 'uncertain';
  out.case_priority = a.risk >= 0.8 ? 1 : a.risk >= 0.6 ? 2 : 3;

  if (!pol || !pol.enabled) {                   // observation only: recorded, no action, no case
    out.reasons = reasons.concat(['the policy for this category is switched off: recorded for evaluation only']);
    return out;
  }
  if (p.source === 'user_report') out.requires_human_review = true;
  const max = pol.max_auto_action || 'none';
  if (pol.always_human_review) out.requires_human_review = true;

  let action = 'refer_to_human';
  if (max !== 'none') {
    action = 'flag';
    // Hiding is only offered for public posts/comments, never for private messages, and never for always-human categories.
    const hideable = (p.subjectType === 'post' || p.subjectType === 'comment') && max === 'hide_pending_review' && !pol.always_human_review;
    if (out.outcome === 'violation_likely' && hideable) action = 'hide_pending_review';
  }
  if (action === 'refer_to_human' || action === 'flag') out.requires_human_review = true;
  if (action === 'hide_pending_review') {
    out.requires_human_review = true;        // a hold always comes with a review case: it expires, a human decides
    out.user_visible_reason = 'This content is temporarily hidden while it is reviewed.';
  }
  if (!SAFE_CONTENT_ACTIONS.includes(action)) throw new Error('engine produced an unsafe action: ' + action);   // defence in depth
  out.recommended_action = action;
  return out;
}

module.exports = { analyze, decide, categoryForReport, PHRASES };
