-- =====================================================================================
-- BMN Platform Intelligence — migration 001 (UP)            schema version 1
-- Additive only: creates NEW objects prefixed pi_ / pi_*(). It does not ALTER, DROP,
-- UPDATE or INSERT into any existing BMN table, function, policy, trigger or index.
-- Reversible with 001_pi_schema.down.sql.
--
-- DO NOT RUN ON PRODUCTION until reviewed and approved. Tested only on a disposable
-- PostgreSQL 16 (see platform-intelligence/README.md for exactly what was and was not tested).
--
-- Compatibility rules this file follows (derived from the existing production-style baseline):
--   * public.bmn_delete_my_account() finishes with DELETE FROM auth.users. Every foreign key
--     from a pi_ table to auth.users is therefore ON DELETE CASCADE or ON DELETE SET NULL,
--     never RESTRICT / NO ACTION, and no CHECK constraint can be violated by a SET NULL.
--   * No foreign keys to posts / comments / messages / content_reports / bmn_verification_requests.
--     The production schema may differ from the baseline (the app already references tables the
--     baseline lacks, e.g. "reposts"), and moderation evidence must outlive deleted content.
--     Those references are plain uuid columns (polymorphic subject_type + subject_id).
--   * Raw message / post text is never stored here: only a SHA-256 content hash and scores.
--   * Raw IP addresses are never stored: only a keyed hash computed by the API server.
--   * Everything ships OFF: all feature flags are disabled, all policy categories are disabled.
-- =====================================================================================

BEGIN;

-- Fail fast instead of queueing behind long-running production transactions.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
SET LOCAL client_min_messages = warning;      -- hide the harmless "does not exist, skipping" notices on a first run

-- ---------------------------------------------------------------- preconditions
DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE EXCEPTION 'Precondition failed: auth.users not found (not a Supabase database?)';
  END IF;
  IF to_regprocedure('public.is_bmn_owner()') IS NULL THEN
    RAISE EXCEPTION 'Precondition failed: public.is_bmn_owner() not found';
  END IF;
  IF to_regclass('public.bmn_admins') IS NULL THEN
    RAISE EXCEPTION 'Precondition failed: public.bmn_admins not found';
  END IF;
  -- Refuse to run if something named pi_* already exists that this migration did not create
  -- (otherwise CREATE ... IF NOT EXISTS would silently skip it and later steps would misbehave).
  IF to_regclass('public.pi_schema_version') IS NULL
     AND (EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname LIKE 'pi\_%')
          OR EXISTS (SELECT 1 FROM pg_proc  WHERE pronamespace = 'public'::regnamespace AND proname  LIKE 'pi\_%')
          OR EXISTS (SELECT 1 FROM pg_type  WHERE typnamespace = 'public'::regnamespace AND typname   LIKE 'pi\_%' AND typtype = 'd')) THEN
    RAISE EXCEPTION 'Precondition failed: objects named pi_* already exist but were not created by this migration. Inspect them before continuing.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    RAISE EXCEPTION 'Precondition failed: roles anon / authenticated / service_role must exist';
  END IF;
END $$;

-- ---------------------------------------------------------------- shared type + helpers
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE n.nspname = 'public' AND t.typname = 'pi_category') THEN
    CREATE DOMAIN public.pi_category AS text CHECK (VALUE IN (
      'harassment_bullying', 'hate_speech', 'threats_violence', 'sexual_exploitation',
      'prohibited_sexual_content', 'spam_scams', 'impersonation', 'dangerous_prohibited',
      'manipulated_engagement', 'repeated_violations'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.pi_touch_updated_at() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- true only when the array is non-empty and EVERY check has result = 'pass'
CREATE OR REPLACE FUNCTION public.pi_all_checks_pass(p_checks jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_typeof(p_checks) = 'array'
     AND jsonb_array_length(p_checks) > 0
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_checks) AS e
                     WHERE e->>'result' IS DISTINCT FROM 'pass');
$$;

CREATE TABLE IF NOT EXISTS public.pi_schema_version (
  version    integer PRIMARY KEY,
  name       text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- feature flags + policies
CREATE TABLE IF NOT EXISTS public.pi_feature_flags (
  key         text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]{2,63}$'),
  enabled     boolean NOT NULL DEFAULT false,
  description text NOT NULL,
  config      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config) = 'object'),
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pi_policies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category              public.pi_category NOT NULL UNIQUE,
  description           text NOT NULL,
  enabled               boolean NOT NULL DEFAULT false,
  review_threshold      numeric(4,3) CHECK (review_threshold BETWEEN 0 AND 1),
  auto_action_threshold numeric(4,3) CHECK (auto_action_threshold BETWEEN 0 AND 1),
  -- The strongest action automation may take for this category. Severe / irreversible actions
  -- (remove_content, suspend, ban) are deliberately NOT allowed values: only humans can do those.
  max_auto_action       text NOT NULL DEFAULT 'none'
                        CHECK (max_auto_action IN ('none', 'flag', 'hide_pending_review', 'warn', 'restrict_temporary')),
  always_human_review   boolean NOT NULL DEFAULT false,
  version               integer NOT NULL DEFAULT 1,
  updated_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_policies_enabled_needs_threshold
    CHECK (NOT enabled OR review_threshold IS NOT NULL),
  CONSTRAINT pi_policies_auto_needs_threshold
    CHECK (max_auto_action = 'none' OR auto_action_threshold IS NOT NULL),
  CONSTRAINT pi_policies_auto_not_below_review
    CHECK (auto_action_threshold IS NULL OR review_threshold IS NULL OR auto_action_threshold >= review_threshold)
);

CREATE OR REPLACE FUNCTION public.pi_policy_bump_version() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF (NEW.enabled, NEW.review_threshold, NEW.auto_action_threshold, NEW.max_auto_action, NEW.always_human_review)
     IS DISTINCT FROM
     (OLD.enabled, OLD.review_threshold, OLD.auto_action_threshold, OLD.max_auto_action, OLD.always_human_review) THEN
    NEW.version := OLD.version + 1;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------- moderation core
CREATE TABLE IF NOT EXISTS public.pi_moderation_cases (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type          text NOT NULL CHECK (subject_type IN ('post', 'comment', 'message', 'profile', 'media', 'account', 'report')),
  subject_id            uuid NOT NULL,            -- for subject_type='account' this is the user id
  subject_user_id       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  source                text NOT NULL CHECK (source IN ('automated', 'user_report', 'owner', 'appeal')),
  report_id             uuid,                     -- content_reports.id (deliberately no FK)
  status                text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'awaiting_review', 'resolved', 'dismissed')),
  priority              smallint NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 4),   -- 1 = most urgent
  primary_category      public.pi_category,
  risk_score            numeric(5,4) CHECK (risk_score BETWEEN 0 AND 1),
  confidence            numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
  requires_human_review boolean NOT NULL DEFAULT false,
  assigned_to           uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution            text CHECK (resolution IN ('no_violation', 'violation_confirmed', 'content_removed',
                                                   'user_actioned', 'duplicate', 'insufficient_information')),
  idempotency_key       text UNIQUE,
  opened_at             timestamptz NOT NULL DEFAULT now(),
  resolved_at           timestamptz,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_cases_resolved_consistent
    CHECK ((status IN ('resolved', 'dismissed')) = (resolved_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS public.pi_content_analyses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id         uuid REFERENCES public.pi_moderation_cases(id) ON DELETE SET NULL,
  subject_type    text NOT NULL CHECK (subject_type IN ('post', 'comment', 'message', 'profile', 'media')),
  subject_id      uuid NOT NULL,
  subject_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  analysis_kind   text NOT NULL CHECK (analysis_kind IN ('text', 'image', 'video_frame', 'video', 'profile', 'metadata')),
  content_hash    text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),   -- sha256 hex; raw content is NOT stored
  content_length  integer CHECK (content_length >= 0),
  language        text,
  provider        text NOT NULL CHECK (char_length(btrim(provider)) > 0),  -- e.g. a vendor name or 'bmn_rules'
  model           text,
  model_version   text,
  policy_version  integer,
  category_scores jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(category_scores) = 'object'),
  top_category    public.pi_category,
  risk_score      numeric(5,4) CHECK (risk_score BETWEEN 0 AND 1),
  confidence      numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
  outcome         text NOT NULL CHECK (outcome IN ('clear', 'uncertain', 'violation_likely', 'skipped', 'provider_error')),
  error           text,
  latency_ms      integer CHECK (latency_ms >= 0),
  idempotency_key text UNIQUE,
  analysed_at     timestamptz NOT NULL DEFAULT now(),
  -- A real result must carry a real score: no invented results.
  CONSTRAINT pi_analyses_scored CHECK (outcome IN ('skipped', 'provider_error') OR risk_score IS NOT NULL),
  CONSTRAINT pi_analyses_error_recorded CHECK (outcome <> 'provider_error' OR error IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.pi_moderation_actions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id             uuid NOT NULL REFERENCES public.pi_moderation_cases(id) ON DELETE CASCADE,
  target_user_id      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  subject_type        text NOT NULL CHECK (subject_type IN ('post', 'comment', 'message', 'profile', 'media', 'account')),
  subject_id          uuid NOT NULL,
  action_type         text NOT NULL CHECK (action_type IN ('no_action', 'flag', 'hide_pending_review', 'restore', 'warn',
                        'restrict_temporary', 'lift_restriction', 'remove_content', 'suspend', 'ban', 'revoke_verification')),
  actor_type          text NOT NULL CHECK (actor_type IN ('system', 'owner', 'admin', 'moderator')),
  actor_id            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  -- 'shadow' = the decision was recorded but NOT applied to the platform (safe rollout / evaluation)
  mode                text NOT NULL DEFAULT 'shadow' CHECK (mode IN ('shadow', 'enforced')),
  reason_code         public.pi_category,
  user_visible_reason text,
  internal_note       text,
  policy_id           uuid REFERENCES public.pi_policies(id) ON DELETE SET NULL,
  policy_version      integer,
  analysis_id         uuid REFERENCES public.pi_content_analyses(id) ON DELETE SET NULL,
  confidence          numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
  expires_at          timestamptz,
  appealable          boolean NOT NULL DEFAULT true,
  idempotency_key     text UNIQUE,
  created_at          timestamptz NOT NULL DEFAULT now(),
  reversed_at         timestamptz,
  reversed_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reversal_reason     text,
  -- Automation may never take severe / irreversible actions (suspend, ban, remove_content, revoke_verification).
  CONSTRAINT pi_actions_system_limited
    CHECK (actor_type <> 'system' OR action_type IN ('no_action', 'flag', 'hide_pending_review', 'restore', 'warn',
                                                      'restrict_temporary', 'lift_restriction')),
  -- Automated holds / restrictions must expire on their own.
  CONSTRAINT pi_actions_system_temp_expires
    CHECK (actor_type <> 'system' OR action_type NOT IN ('hide_pending_review', 'restrict_temporary') OR expires_at IS NOT NULL),
  -- Severe human actions must carry a reason the user can be shown.
  CONSTRAINT pi_actions_severe_needs_reason
    CHECK (action_type NOT IN ('remove_content', 'suspend', 'ban', 'revoke_verification')
           OR char_length(btrim(coalesce(user_visible_reason, ''))) > 0),
  CONSTRAINT pi_actions_reversal_consistent
    CHECK (reversed_at IS NOT NULL OR reversal_reason IS NULL)
);

-- Moderation history is tamper-resistant: core fields never change, rows are never deleted.
-- Only reversal fields may be written (once), and user/FK columns may be set NULL (account deletion).
CREATE OR REPLACE FUNCTION public.pi_actions_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'pi_moderation_actions rows cannot be deleted' USING ERRCODE = '42501';
  END IF;
  IF ROW(NEW.id, NEW.case_id, NEW.subject_type, NEW.subject_id, NEW.action_type, NEW.actor_type, NEW.mode,
         NEW.reason_code, NEW.user_visible_reason, NEW.internal_note, NEW.policy_version, NEW.confidence,
         NEW.expires_at, NEW.appealable, NEW.idempotency_key, NEW.created_at)
     IS DISTINCT FROM
     ROW(OLD.id, OLD.case_id, OLD.subject_type, OLD.subject_id, OLD.action_type, OLD.actor_type, OLD.mode,
         OLD.reason_code, OLD.user_visible_reason, OLD.internal_note, OLD.policy_version, OLD.confidence,
         OLD.expires_at, OLD.appealable, OLD.idempotency_key, OLD.created_at) THEN
    RAISE EXCEPTION 'pi_moderation_actions core fields are immutable' USING ERRCODE = '42501';
  END IF;
  IF (NEW.target_user_id IS DISTINCT FROM OLD.target_user_id AND NEW.target_user_id IS NOT NULL)
     OR (NEW.actor_id IS DISTINCT FROM OLD.actor_id AND NEW.actor_id IS NOT NULL)
     OR (NEW.policy_id IS DISTINCT FROM OLD.policy_id AND NEW.policy_id IS NOT NULL)
     OR (NEW.analysis_id IS DISTINCT FROM OLD.analysis_id AND NEW.analysis_id IS NOT NULL)
     OR (NEW.reversed_by IS DISTINCT FROM OLD.reversed_by AND NEW.reversed_by IS NOT NULL AND OLD.reversed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'pi_moderation_actions reference columns may only be cleared' USING ERRCODE = '42501';
  END IF;
  IF OLD.reversed_at IS NOT NULL
     AND (NEW.reversed_at IS DISTINCT FROM OLD.reversed_at OR NEW.reversal_reason IS DISTINCT FROM OLD.reversal_reason) THEN
    RAISE EXCEPTION 'an action can only be reversed once' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TABLE IF NOT EXISTS public.pi_appeals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_id     uuid NOT NULL UNIQUE REFERENCES public.pi_moderation_actions(id) ON DELETE CASCADE,  -- one appeal per action
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  statement     text NOT NULL CHECK (char_length(btrim(statement)) BETWEEN 10 AND 2000),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'under_review', 'upheld', 'overturned')),
  reviewer_id   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decision_note text,
  decided_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_appeals_decided_consistent CHECK ((status IN ('upheld', 'overturned')) = (decided_at IS NOT NULL)),
  CONSTRAINT pi_appeals_decision_has_note
    CHECK (status NOT IN ('upheld', 'overturned') OR char_length(btrim(coalesce(decision_note, ''))) > 0)
);

-- ---------------------------------------------------------------- account protection
CREATE TABLE IF NOT EXISTS public.pi_account_risk_assessments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  risk_score   numeric(5,4) NOT NULL CHECK (risk_score BETWEEN 0 AND 1),
  risk_level   text NOT NULL CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
  reason_codes text[] NOT NULL DEFAULT '{}',
  signals      jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(signals) = 'array'),   -- explainability: what contributed
  explanation  text NOT NULL CHECK (char_length(btrim(explanation)) > 0),
  model_version text NOT NULL,
  is_current   boolean NOT NULL DEFAULT true,
  assessed_at  timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz,
  escalated_at timestamptz,
  -- Anything above "low" must say why: no unexplained risk scores.
  CONSTRAINT pi_risk_explainable CHECK (risk_level = 'low' OR cardinality(reason_codes) > 0)
);

CREATE TABLE IF NOT EXISTS public.pi_security_events (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type      text NOT NULL CHECK (event_type IN ('suspicious_login', 'unusual_activity', 'spam_burst', 'automated_engagement',
                    'mass_follow', 'mass_unfollow', 'impersonation_attempt', 'suspicious_signup_cluster',
                    'coordinated_abuse', 'repeated_violation', 'rate_limit_exceeded', 'other')),
  severity        text NOT NULL CHECK (severity IN ('info', 'low', 'medium', 'high', 'critical')),
  source          text NOT NULL CHECK (char_length(btrim(source)) > 0),
  ip_hash         text CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{64}$'),      -- keyed hash computed server-side; never a raw IP
  device_hash     text CHECK (device_hash IS NULL OR device_hash ~ '^[0-9a-f]{64}$'),
  details         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  dedupe_key      text UNIQUE,
  case_id         uuid REFERENCES public.pi_moderation_cases(id) ON DELETE SET NULL,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  acknowledged_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  acknowledged_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.pi_protective_restrictions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  restriction_type text NOT NULL CHECK (restriction_type IN ('limit_posting', 'limit_follows', 'limit_messaging',
                     'require_reauthentication', 'hide_from_discovery', 'hold_new_content_for_review')),
  reason_code      text NOT NULL CHECK (char_length(btrim(reason_code)) > 0),
  assessment_id    uuid REFERENCES public.pi_account_risk_assessments(id) ON DELETE SET NULL,
  actor_type       text NOT NULL CHECK (actor_type IN ('system', 'owner', 'admin', 'moderator')),
  created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  mode             text NOT NULL DEFAULT 'shadow' CHECK (mode IN ('shadow', 'enforced')),
  starts_at        timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,                       -- always temporary
  lifted_at        timestamptz,
  lifted_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  lift_reason      text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_restrictions_window CHECK (expires_at > starts_at)
);

-- ---------------------------------------------------------------- verification
-- Requests themselves stay in the existing bmn_verification_requests table; badges stay in
-- bmn_verified_users. These tables record how a request was evaluated and the decision history.
CREATE TABLE IF NOT EXISTS public.pi_verification_evaluations (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  verification_request_id uuid NOT NULL,                        -- bmn_verification_requests.id (no FK, see header)
  user_id                 uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  criteria_version        integer NOT NULL CHECK (criteria_version >= 1),
  -- [{ "check": "...", "result": "pass|fail|unverifiable", "evidence_ref": "...", "source": "..." }]
  checks                  jsonb NOT NULL CHECK (jsonb_typeof(checks) = 'array'),
  outcome                 text NOT NULL CHECK (outcome IN ('eligible_for_auto_approval', 'needs_human_review', 'insufficient_evidence')),
  impersonation_risk      numeric(5,4) CHECK (impersonation_risk BETWEEN 0 AND 1),
  created_at              timestamptz NOT NULL DEFAULT now(),
  -- Auto-approval eligibility is only possible when every recorded check passed.
  CONSTRAINT pi_verif_eligible_requires_all_pass
    CHECK (outcome <> 'eligible_for_auto_approval' OR public.pi_all_checks_pass(checks))
);

CREATE TABLE IF NOT EXISTS public.pi_verification_decisions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  verification_request_id uuid,
  evaluation_id           uuid REFERENCES public.pi_verification_evaluations(id) ON DELETE CASCADE,
  decision                text NOT NULL CHECK (decision IN ('approved', 'rejected', 'referred_to_human', 'revoked')),
  decided_by_type         text NOT NULL CHECK (decided_by_type IN ('system', 'owner', 'admin', 'moderator')),
  decided_by              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reason                  text NOT NULL CHECK (char_length(btrim(reason)) > 0),
  fraud_related           boolean NOT NULL DEFAULT false,
  created_at              timestamptz NOT NULL DEFAULT now(),
  -- Automation may approve (with a passing evaluation) or refer to a human; never reject or revoke.
  CONSTRAINT pi_verif_system_limited CHECK (decided_by_type <> 'system' OR decision IN ('approved', 'referred_to_human')),
  CONSTRAINT pi_verif_system_approval_has_evaluation CHECK (decided_by_type <> 'system' OR decision <> 'approved' OR evaluation_id IS NOT NULL),
  CONSTRAINT pi_verif_fraud_is_revocation CHECK (NOT fraud_related OR decision = 'revoked')
);

-- ---------------------------------------------------------------- AI provider usage + health
CREATE TABLE IF NOT EXISTS public.pi_ai_provider_usage (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider       text NOT NULL CHECK (char_length(btrim(provider)) > 0),
  model          text,
  operation      text NOT NULL CHECK (operation IN ('text_moderation', 'image_moderation', 'video_frame_moderation',
                   'classification', 'embedding', 'healthcheck', 'other')),
  status         text NOT NULL CHECK (status IN ('ok', 'error', 'rate_limited', 'timeout', 'blocked_by_provider', 'skipped_budget')),
  request_count  integer NOT NULL DEFAULT 1 CHECK (request_count >= 0),
  input_tokens   bigint CHECK (input_tokens >= 0),
  output_tokens  bigint CHECK (output_tokens >= 0),
  billable_units numeric(14,3) CHECK (billable_units >= 0),
  cost_usd       numeric(12,6) CHECK (cost_usd >= 0),
  -- A cost is only recorded when it is known: never a made-up number.
  cost_basis     text NOT NULL DEFAULT 'unknown' CHECK (cost_basis IN ('reported', 'estimated', 'unknown')),
  latency_ms     integer CHECK (latency_ms >= 0),
  analysis_id    uuid REFERENCES public.pi_content_analyses(id) ON DELETE SET NULL,
  request_id     text,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_usage_cost_consistent CHECK ((cost_usd IS NULL) = (cost_basis = 'unknown'))
);

CREATE TABLE IF NOT EXISTS public.pi_provider_health (
  provider             text PRIMARY KEY CHECK (char_length(btrim(provider)) > 0),
  state                text NOT NULL DEFAULT 'unknown' CHECK (state IN ('unknown', 'healthy', 'degraded', 'down', 'disabled')),
  consecutive_failures integer NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
  last_success_at      timestamptz,
  last_failure_at      timestamptz,
  last_error           text,
  circuit_open_until   timestamptz,
  updated_at           timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- job queue + audit log
CREATE TABLE IF NOT EXISTS public.pi_jobs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type         text NOT NULL CHECK (job_type IN ('analyze_content', 'assess_account', 'evaluate_verification', 'apply_action',
                     'reverse_action', 'expire_restrictions', 'purge_retention', 'provider_healthcheck')),
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  status           text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'succeeded', 'dead', 'cancelled')),
  priority         smallint NOT NULL DEFAULT 5 CHECK (priority BETWEEN 1 AND 9),   -- 1 runs first
  attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts     integer NOT NULL DEFAULT 5 CHECK (max_attempts >= 1),
  run_after        timestamptz NOT NULL DEFAULT now(),
  locked_by        text,
  locked_at        timestamptz,
  lease_expires_at timestamptz,
  last_error       text,
  idempotency_key  text UNIQUE,
  created_at       timestamptz NOT NULL DEFAULT now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_jobs_lease_consistent
    CHECK ((status = 'running') = (locked_by IS NOT NULL AND lease_expires_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS public.pi_audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  actor_id    uuid,                                  -- no FK on purpose: evidence must survive account deletion
  actor_type  text NOT NULL CHECK (actor_type IN ('system', 'owner', 'admin', 'moderator', 'user', 'service')),
  action      text NOT NULL CHECK (char_length(btrim(action)) > 0),
  target_type text,
  target_id   text,
  before_state jsonb,
  after_state  jsonb,
  reason      text,
  request_id  text,
  ip_hash     text CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{64}$')
);

CREATE OR REPLACE FUNCTION public.pi_audit_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'pi_audit_log is append-only' USING ERRCODE = '42501';
END $$;

-- ---------------------------------------------------------------- indexes
CREATE INDEX IF NOT EXISTS pi_cases_queue_idx        ON public.pi_moderation_cases (priority, opened_at) WHERE status IN ('open', 'awaiting_review');
CREATE INDEX IF NOT EXISTS pi_cases_user_idx         ON public.pi_moderation_cases (subject_user_id, opened_at DESC);
CREATE INDEX IF NOT EXISTS pi_cases_subject_idx      ON public.pi_moderation_cases (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS pi_analyses_subject_idx   ON public.pi_content_analyses (subject_type, subject_id, analysed_at DESC);
CREATE INDEX IF NOT EXISTS pi_analyses_case_idx      ON public.pi_content_analyses (case_id) WHERE case_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pi_analyses_hash_idx      ON public.pi_content_analyses (content_hash);
CREATE INDEX IF NOT EXISTS pi_actions_target_idx     ON public.pi_moderation_actions (target_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS pi_actions_case_idx       ON public.pi_moderation_actions (case_id);
CREATE INDEX IF NOT EXISTS pi_appeals_user_idx       ON public.pi_appeals (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS pi_appeals_open_idx       ON public.pi_appeals (created_at) WHERE status IN ('pending', 'under_review');
CREATE UNIQUE INDEX IF NOT EXISTS pi_risk_one_current_per_user ON public.pi_account_risk_assessments (user_id) WHERE is_current;
CREATE INDEX IF NOT EXISTS pi_risk_level_idx         ON public.pi_account_risk_assessments (risk_level, assessed_at DESC) WHERE is_current;
CREATE INDEX IF NOT EXISTS pi_secevents_user_idx     ON public.pi_security_events (user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS pi_secevents_type_idx     ON public.pi_security_events (event_type, occurred_at DESC);
CREATE INDEX IF NOT EXISTS pi_secevents_open_idx     ON public.pi_security_events (occurred_at DESC) WHERE acknowledged_at IS NULL AND severity IN ('high', 'critical');
CREATE INDEX IF NOT EXISTS pi_secevents_ip_idx       ON public.pi_security_events (ip_hash, occurred_at DESC) WHERE ip_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS pi_restrictions_active_idx ON public.pi_protective_restrictions (user_id, expires_at) WHERE lifted_at IS NULL;
CREATE INDEX IF NOT EXISTS pi_verif_eval_user_idx    ON public.pi_verification_evaluations (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS pi_verif_dec_user_idx     ON public.pi_verification_decisions (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS pi_usage_provider_idx     ON public.pi_ai_provider_usage (provider, occurred_at DESC);
CREATE INDEX IF NOT EXISTS pi_usage_time_idx         ON public.pi_ai_provider_usage (occurred_at DESC);
CREATE INDEX IF NOT EXISTS pi_jobs_claim_idx         ON public.pi_jobs (priority, run_after) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS pi_jobs_lease_idx         ON public.pi_jobs (lease_expires_at) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS pi_jobs_type_status_idx   ON public.pi_jobs (job_type, status);
CREATE INDEX IF NOT EXISTS pi_audit_time_idx         ON public.pi_audit_log (occurred_at DESC);
CREATE INDEX IF NOT EXISTS pi_audit_target_idx       ON public.pi_audit_log (target_type, target_id);
CREATE INDEX IF NOT EXISTS pi_audit_actor_idx        ON public.pi_audit_log (actor_id, occurred_at DESC);

-- ---------------------------------------------------------------- triggers (only on pi_ tables)
DROP TRIGGER IF EXISTS pi_touch_flags    ON public.pi_feature_flags;
CREATE TRIGGER pi_touch_flags    BEFORE UPDATE ON public.pi_feature_flags    FOR EACH ROW EXECUTE FUNCTION public.pi_touch_updated_at();
DROP TRIGGER IF EXISTS pi_policy_version ON public.pi_policies;
CREATE TRIGGER pi_policy_version BEFORE UPDATE ON public.pi_policies         FOR EACH ROW EXECUTE FUNCTION public.pi_policy_bump_version();
DROP TRIGGER IF EXISTS pi_touch_cases    ON public.pi_moderation_cases;
CREATE TRIGGER pi_touch_cases    BEFORE UPDATE ON public.pi_moderation_cases FOR EACH ROW EXECUTE FUNCTION public.pi_touch_updated_at();
DROP TRIGGER IF EXISTS pi_touch_appeals  ON public.pi_appeals;
CREATE TRIGGER pi_touch_appeals  BEFORE UPDATE ON public.pi_appeals          FOR EACH ROW EXECUTE FUNCTION public.pi_touch_updated_at();
DROP TRIGGER IF EXISTS pi_touch_health   ON public.pi_provider_health;
CREATE TRIGGER pi_touch_health   BEFORE UPDATE ON public.pi_provider_health  FOR EACH ROW EXECUTE FUNCTION public.pi_touch_updated_at();
DROP TRIGGER IF EXISTS pi_actions_immutable ON public.pi_moderation_actions;
CREATE TRIGGER pi_actions_immutable BEFORE UPDATE OR DELETE ON public.pi_moderation_actions FOR EACH ROW EXECUTE FUNCTION public.pi_actions_guard();
DROP TRIGGER IF EXISTS pi_audit_no_change   ON public.pi_audit_log;
CREATE TRIGGER pi_audit_no_change   BEFORE UPDATE OR DELETE ON public.pi_audit_log FOR EACH ROW EXECUTE FUNCTION public.pi_audit_guard();
DROP TRIGGER IF EXISTS pi_audit_no_truncate ON public.pi_audit_log;
CREATE TRIGGER pi_audit_no_truncate BEFORE TRUNCATE ON public.pi_audit_log FOR EACH STATEMENT EXECUTE FUNCTION public.pi_audit_guard();

-- ---------------------------------------------------------------- functions
-- Internal: append to the audit log. Not exposed to users.
CREATE OR REPLACE FUNCTION public.pi_write_audit(
  p_actor uuid, p_actor_type text, p_action text, p_target_type text, p_target_id text,
  p_before jsonb, p_after jsonb, p_reason text) RETURNS bigint
  LANGUAGE sql SET search_path = '' AS $$
  INSERT INTO public.pi_audit_log (actor_id, actor_type, action, target_type, target_id, before_state, after_state, reason)
  VALUES (p_actor, p_actor_type, p_action, p_target_type, p_target_id, p_before, p_after, p_reason)
  RETURNING id;
$$;

-- Job queue ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pi_claim_jobs(
  p_worker text, p_limit integer DEFAULT 10, p_lease interval DEFAULT interval '5 minutes', p_types text[] DEFAULT NULL)
  RETURNS SETOF public.pi_jobs
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF p_worker IS NULL OR btrim(p_worker) = '' THEN
    RAISE EXCEPTION 'worker id required' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;
  -- A job whose lease expired on its final allowed attempt is dead-lettered, not retried forever.
  UPDATE public.pi_jobs
     SET status = 'dead', locked_by = NULL, locked_at = NULL, lease_expires_at = NULL,
         finished_at = now(), updated_at = now(),
         last_error = left(coalesce(last_error, '') || ' [lease expired on final attempt]', 2000)
   WHERE status = 'running' AND lease_expires_at < now() AND attempts >= max_attempts;
  RETURN QUERY
  UPDATE public.pi_jobs j
     SET status = 'running', attempts = j.attempts + 1, locked_by = p_worker, locked_at = now(),
         lease_expires_at = now() + p_lease, started_at = coalesce(j.started_at, now()), updated_at = now()
   WHERE j.id IN (
     SELECT c.id FROM public.pi_jobs c
      WHERE ((c.status = 'queued' AND c.run_after <= now()) OR (c.status = 'running' AND c.lease_expires_at < now()))
        AND c.attempts < c.max_attempts
        AND (p_types IS NULL OR c.job_type = ANY (p_types))
      ORDER BY c.priority, c.run_after, c.created_at
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED)
  RETURNING j.*;
END $$;

CREATE OR REPLACE FUNCTION public.pi_complete_job(p_job_id uuid, p_worker text) RETURNS boolean
  LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE n integer;
BEGIN
  UPDATE public.pi_jobs
     SET status = 'succeeded', locked_by = NULL, locked_at = NULL, lease_expires_at = NULL,
         finished_at = now(), updated_at = now()
   WHERE id = p_job_id AND status = 'running' AND locked_by = p_worker;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END $$;

-- Returns the new status ('queued' for a retry, 'dead' when attempts are exhausted), or NULL if the
-- caller does not hold the job. Default back-off: 10s, 20s, 40s ... capped at 1 hour.
CREATE OR REPLACE FUNCTION public.pi_fail_job(p_job_id uuid, p_worker text, p_error text, p_retry_in interval DEFAULT NULL)
  RETURNS text
  LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE j public.pi_jobs; v_status text;
BEGIN
  SELECT * INTO j FROM public.pi_jobs WHERE id = p_job_id AND status = 'running' AND locked_by = p_worker FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_status := CASE WHEN j.attempts >= j.max_attempts THEN 'dead' ELSE 'queued' END;
  UPDATE public.pi_jobs
     SET status = v_status, locked_by = NULL, locked_at = NULL, lease_expires_at = NULL,
         last_error = left(p_error, 2000),
         run_after = CASE WHEN v_status = 'queued'
                          THEN now() + coalesce(p_retry_in, least(interval '10 seconds' * power(2, j.attempts - 1), interval '1 hour'))
                          ELSE j.run_after END,
         finished_at = CASE WHEN v_status = 'dead' THEN now() ELSE NULL END,
         updated_at = now()
   WHERE id = p_job_id;
  RETURN v_status;
END $$;

-- Repeat-offender signal: enforced, non-reversed, user-affecting actions in a window.
CREATE OR REPLACE FUNCTION public.pi_violation_count(p_user uuid, p_window interval DEFAULT interval '90 days')
  RETURNS integer
  LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT count(*)::integer FROM public.pi_moderation_actions
   WHERE target_user_id = p_user AND mode = 'enforced' AND reversed_at IS NULL
     AND action_type IN ('warn', 'hide_pending_review', 'remove_content', 'restrict_temporary', 'suspend', 'ban')
     AND created_at >= now() - p_window;
$$;

-- User-facing: a user's own enforced actions, with ONLY safe columns (no scores, notes, policy or actor).
CREATE OR REPLACE FUNCTION public.pi_my_moderation_notices()
  RETURNS TABLE (action_id uuid, action_type text, user_visible_reason text, created_at timestamptz,
                 expires_at timestamptz, appealable boolean, reversed boolean, appeal_status text)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT a.id, a.action_type, a.user_visible_reason, a.created_at, a.expires_at,
         (a.appealable AND a.reversed_at IS NULL AND ap.id IS NULL),
         (a.reversed_at IS NOT NULL), ap.status
    FROM public.pi_moderation_actions a
    LEFT JOIN public.pi_appeals ap ON ap.action_id = a.id
   WHERE a.target_user_id = (SELECT auth.uid())
     AND a.mode = 'enforced'
     AND a.action_type NOT IN ('no_action', 'flag')
   ORDER BY a.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.pi_submit_appeal(p_action_id uuid, p_statement text) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_uid uuid := (SELECT auth.uid()); a public.pi_moderation_actions; v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO a FROM public.pi_moderation_actions WHERE id = p_action_id AND target_user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No such action for this account' USING ERRCODE = 'P0002';
  END IF;
  IF a.mode <> 'enforced' OR NOT a.appealable OR a.reversed_at IS NOT NULL
     OR a.action_type IN ('no_action', 'flag') THEN
    RAISE EXCEPTION 'This action cannot be appealed' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO public.pi_appeals (action_id, user_id, statement) VALUES (p_action_id, v_uid, p_statement)
  RETURNING id INTO v_id;                                  -- unique(action_id) => 23505 if already appealed
  PERFORM public.pi_write_audit(v_uid, 'user', 'appeal_submitted', 'moderation_action', p_action_id::text,
                                NULL, jsonb_build_object('appeal_id', v_id), NULL);
  RETURN v_id;
END $$;

-- Owner decision on an appeal. Callable by the server only (service_role); the owner check is repeated
-- here in the database so a bug in the API layer cannot let a non-owner decide an appeal.
CREATE OR REPLACE FUNCTION public.pi_decide_appeal(p_actor uuid, p_appeal_id uuid, p_decision text, p_note text)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE ap public.pi_appeals;
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.bmn_admins WHERE user_id = p_actor AND lower(role) = 'owner') THEN
    RAISE EXCEPTION 'Only the BMN owner can decide appeals' USING ERRCODE = '42501';
  END IF;
  IF p_decision NOT IN ('upheld', 'overturned') THEN
    RAISE EXCEPTION 'decision must be upheld or overturned' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NULL OR btrim(p_note) = '' THEN
    RAISE EXCEPTION 'a decision note is required' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO ap FROM public.pi_appeals WHERE id = p_appeal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'appeal not found' USING ERRCODE = 'P0002';
  END IF;
  IF ap.status NOT IN ('pending', 'under_review') THEN
    RAISE EXCEPTION 'appeal already decided' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.pi_appeals
     SET status = p_decision, reviewer_id = p_actor, decision_note = p_note, decided_at = now()
   WHERE id = p_appeal_id;
  IF p_decision = 'overturned' THEN
    UPDATE public.pi_moderation_actions
       SET reversed_at = now(), reversed_by = p_actor, reversal_reason = 'appeal overturned: ' || left(p_note, 500)
     WHERE id = ap.action_id AND reversed_at IS NULL;
    -- The effect on the platform (e.g. restoring content) is applied by a worker, idempotently.
    INSERT INTO public.pi_jobs (job_type, payload, priority, idempotency_key)
    VALUES ('reverse_action', jsonb_build_object('action_id', ap.action_id, 'appeal_id', p_appeal_id), 2,
            'reverse_action:' || ap.action_id::text)
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;
  PERFORM public.pi_write_audit(p_actor, 'owner', 'appeal_' || p_decision, 'appeal', p_appeal_id::text,
                                jsonb_build_object('status', ap.status), jsonb_build_object('status', p_decision), p_note);
END $$;

-- ---------------------------------------------------------------- seed configuration (all OFF)
-- These are configuration definitions, not activity. Nothing here enables any behaviour.
INSERT INTO public.pi_feature_flags (key, enabled, description) VALUES
  ('moderation_analysis',          false, 'Run content analysis and store results. Does not apply any action to users or content.'),
  ('moderation_enforcement',       false, 'Allow automated, reversible actions (flag / hide pending review / warn / temporary restriction). Without this, decisions are recorded in shadow mode only.'),
  ('moderation_message_scanning',  false, 'Analyse private messages. Privacy-sensitive: keep off until the privacy policy covers it.'),
  ('account_risk_scoring',         false, 'Compute explainable account risk assessments and security alerts.'),
  ('account_protective_restrictions', false, 'Allow temporary protective restrictions on high-risk accounts.'),
  ('auto_verification',            false, 'Allow automatic approval when every verification check passes. Uncertain cases always go to a human.'),
  ('ai_providers',                 false, 'Allow outbound calls to external AI providers. Off = rules-only operation.'),
  ('emergency_halt_automation',    false, 'Kill switch: when true, workers must stop all automated enforcement immediately.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.pi_policies (category, description, always_human_review) VALUES
  ('harassment_bullying',       'Harassment and bullying', false),
  ('hate_speech',               'Hate speech', false),
  ('threats_violence',          'Threats and violent content', true),
  ('sexual_exploitation',       'Sexual exploitation', true),
  ('prohibited_sexual_content', 'Prohibited sexual content', false),
  ('spam_scams',                'Spam and scams', false),
  ('impersonation',             'Impersonation', false),
  ('dangerous_prohibited',      'Dangerous or prohibited content', false),
  ('manipulated_engagement',    'Manipulated engagement', false),
  ('repeated_violations',       'Repeated policy violations', true)
ON CONFLICT (category) DO NOTHING;

INSERT INTO public.pi_schema_version (version, name) VALUES (1, '001_pi_schema')
ON CONFLICT (version) DO NOTHING;

-- ---------------------------------------------------------------- RLS + grants (explicit table list only)
DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'pi_schema_version', 'pi_feature_flags', 'pi_policies', 'pi_moderation_cases', 'pi_content_analyses',
    'pi_moderation_actions', 'pi_appeals', 'pi_account_risk_assessments', 'pi_security_events',
    'pi_protective_restrictions', 'pi_verification_evaluations', 'pi_verification_decisions',
    'pi_ai_provider_usage', 'pi_provider_health', 'pi_jobs', 'pi_audit_log'];
  s text;
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);     -- still filtered by RLS below
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS pi_owner_select ON public.%I', t);
    EXECUTE format('CREATE POLICY pi_owner_select ON public.%I FOR SELECT TO authenticated USING ((SELECT public.is_bmn_owner()))', t);
    -- pg_get_serial_sequence() raises an error for a table with no such column, so check first.
    s := NULL;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = t AND column_name = 'id' AND is_identity = 'YES') THEN
      s := pg_get_serial_sequence('public.' || t, 'id');
    END IF;
    IF s IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated', s);
      EXECUTE format('GRANT ALL ON SEQUENCE %s TO service_role', s);
    END IF;
  END LOOP;
END $$;

-- A user may read their own appeals; nothing else in pi_ is readable by ordinary users.
DROP POLICY IF EXISTS pi_appeals_select_own ON public.pi_appeals;
CREATE POLICY pi_appeals_select_own ON public.pi_appeals FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Functions: nobody by default; then grant exactly what each caller needs.
REVOKE ALL ON FUNCTION
  public.pi_touch_updated_at(), public.pi_policy_bump_version(), public.pi_actions_guard(), public.pi_audit_guard(),
  public.pi_all_checks_pass(jsonb),
  public.pi_write_audit(uuid, text, text, text, text, jsonb, jsonb, text),
  public.pi_claim_jobs(text, integer, interval, text[]),
  public.pi_complete_job(uuid, text),
  public.pi_fail_job(uuid, text, text, interval),
  public.pi_violation_count(uuid, interval),
  public.pi_my_moderation_notices(),
  public.pi_submit_appeal(uuid, text),
  public.pi_decide_appeal(uuid, uuid, text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.pi_write_audit(uuid, text, text, text, text, jsonb, jsonb, text),
  public.pi_claim_jobs(text, integer, interval, text[]),
  public.pi_complete_job(uuid, text),
  public.pi_fail_job(uuid, text, text, interval),
  public.pi_violation_count(uuid, interval),
  public.pi_decide_appeal(uuid, uuid, text, text)
  TO service_role;

GRANT EXECUTE ON FUNCTION public.pi_my_moderation_notices()       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pi_submit_appeal(uuid, text)      TO authenticated, service_role;
-- pi_all_checks_pass is used inside a CHECK constraint, which runs as the inserting role.
GRANT EXECUTE ON FUNCTION public.pi_all_checks_pass(jsonb)         TO service_role;

COMMIT;
