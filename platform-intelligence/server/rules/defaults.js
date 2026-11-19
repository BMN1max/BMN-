'use strict';
// Built-in default rule sets = VERSION 1 of each rule set. They live in code, are never edited in place, and every
// decision records which rule-set version it used. The owner publishes configurable versions (2, 3, ...) from the console;
// those are stored, immutable and validated in the database (pi_owner_publish_rule_set).

const MODERATION_RULES_V1 = Object.freeze({
  hold_hours: 24,               // temporary automatic holds expire after this many hours (1..72)
  min_confidence_auto: 0.6,     // below this confidence automation only flags for a human
  max_text_length: 5000,
  signal_weights: {             // multipliers (0..1) applied to built-in signals, e.g. {"shortened_link": 0.5} halves one signal
  },
  custom_terms: {}              // {"spam_scams": [{"term": "free crypto", "weight": 0.9}]}
});

const ACCOUNT_RISK_RULES_V1 = Object.freeze({
  level_thresholds: { medium: 0.3, high: 0.55, critical: 0.8 },
  restriction_hours: 24,
  limits: {
    follows_1h: 60, follows_24h: 300, posts_1h: 12, comments_1h: 40, duplicate_comments_24h: 5, messages_1h: 60,
    message_recipients_1h: 25, likes_1h: 300, interactions_1h: 400, ips_24h: 5, devices_24h: 4, shared_device_accounts_7d: 3,
    reporters_7d: 3, violations_90d: 2, new_account_days: 2
  }
});

// Every check is "required": the database only allows 'eligible_for_auto_approval' when every STORED check passed,
// so optional checks (required:false) are evaluated for the reviewer's information but are not part of the stored list.
const VERIFICATION_CRITERIA_V1 = Object.freeze({
  checks: [
    { id: 'account_age', type: 'min_account_age_days', required: true, value: 14 },
    { id: 'profile', type: 'profile_complete', required: true },
    { id: 'published_posts', type: 'min_published_posts', required: true, value: 3 },
    { id: 'standing', type: 'good_standing', required: true },
    { id: 'risk', type: 'max_account_risk', required: true, level: 'medium' },
    { id: 'open_cases', type: 'no_open_cases', required: true },
    { id: 'impersonation', type: 'impersonation_screen', required: true }
  ]
});

const WORKER_SETTINGS_V1 = Object.freeze({ tick_seconds: 15, batch_size: 10, scan_batch: 100, assess_interval_minutes: 30 });

const DEFAULTS = Object.freeze({
  moderation_rules: MODERATION_RULES_V1,
  account_risk_rules: ACCOUNT_RISK_RULES_V1,
  verification_criteria: VERIFICATION_CRITERIA_V1,
  worker_settings: WORKER_SETTINGS_V1
});

// Pick the published rule set when there is one, else the built-in version 1. `runtime` = result of pi_get_runtime_config().
function activeRules(runtime, key) {
  const published = runtime?.rule_sets?.[key];
  if (published && published.config && typeof published.config === 'object') return { version: Number(published.version) || 1, config: published.config };
  return { version: 1, config: DEFAULTS[key] };
}

// The only actions automation may RECOMMEND (the database enforces the same list).
const SAFE_CONTENT_ACTIONS = Object.freeze(['no_action', 'flag', 'hide_pending_review', 'refer_to_human']);
const SAFE_ACCOUNT_ACTIONS = Object.freeze(['no_action', 'flag', 'restrict_temporary', 'refer_to_human']);

module.exports = { DEFAULTS, MODERATION_RULES_V1, ACCOUNT_RISK_RULES_V1, VERIFICATION_CRITERIA_V1, WORKER_SETTINGS_V1, activeRules, SAFE_CONTENT_ACTIONS, SAFE_ACCOUNT_ACTIONS };
