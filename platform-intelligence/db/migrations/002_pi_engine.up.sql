-- =====================================================================================
-- BMN Platform Intelligence — migration 002 (UP)            schema version 2
-- "Intelligence engine": policy engine, rule sets, decision history, account protection,
-- verification workflow, worker plumbing and the owner control-centre read/write functions.
--
-- ADDITIVE ONLY. Creates NEW objects named pi_*. It does not ALTER, DROP or rewrite any existing BMN
-- table, policy, trigger or index, and it does not touch any migration-001 table definition.
-- The only things it adds to migration-001 objects are: one trigger on pi_policies (policy version
-- snapshots) and one new feature-flag row (verification_evaluation, OFF).
--
-- DO NOT RUN ON PRODUCTION until reviewed and approved. Run on a Supabase branch / restored copy first.
-- Reversible with 002_pi_engine.down.sql (run it BEFORE 001_pi_schema.down.sql).
--
-- Safety rules that are enforced HERE in the database (not only in application code):
--   * Automation (actor 'system') can never ban, suspend, remove content or revoke verification
--     (migration 001 CHECK constraints) and the engine functions below only accept the safe action set.
--   * Every automated hold / restriction carries an expiry; expired holds are closed by pi_expire_automated().
--   * Automated decisions run in SHADOW mode (recorded, not applied) unless enforcement is explicitly
--     available. Enforcement needs the flag AND config.hooks_installed = true, which no migration sets yet:
--     the enforcement hooks into posts/comments are a separate, optional, approval-gated migration 003.
--   * Auto-verification can only APPROVE, only when every recorded check passed, and only after
--     independent database safety gates; everything else becomes 'referred_to_human'. Never auto reject/revoke.
--   * The emergency halt flag stops all automated commits immediately.
--   * Every owner action re-checks owner status inside the database and writes to the append-only audit log.
--   * All feature flags ship OFF. This migration enables nothing.
-- =====================================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';
SET LOCAL client_min_messages = warning;

-- ---------------------------------------------------------------- preconditions
DO $$
DECLARE
  t text; f text; c text; v_missing text[] := '{}';
  v_tables text[] := ARRAY[
    'pi_schema_version','pi_feature_flags','pi_policies','pi_moderation_cases','pi_content_analyses','pi_moderation_actions',
    'pi_appeals','pi_account_risk_assessments','pi_security_events','pi_protective_restrictions','pi_verification_evaluations',
    'pi_verification_decisions','pi_ai_provider_usage','pi_provider_health','pi_jobs','pi_audit_log',
    'bmn_admins','bmn_user_moderation','bmn_verification_requests','bmn_verified_users','comments','content_reports',
    'follows','likes','messages','moderation_actions','posts','profiles'];
  v_funcs text[] := ARRAY['public.is_bmn_owner()','public.pi_write_audit(uuid, text, text, text, text, jsonb, jsonb, text)',
    'public.pi_claim_jobs(text, integer, interval, text[])','public.pi_violation_count(uuid, interval)'];
  -- columns the engine functions read or write in EXISTING BMN tables (plpgsql only fails at run time, so check now)
  v_cols text[] := ARRAY[
    'posts.id','posts.user_id','posts.title','posts.caption','posts.content','posts.tags','posts.status','posts.created_at','posts.updated_at',
    'posts.video_url','posts.media_url','comments.id','comments.user_id','comments.post_id','comments.body','comments.content','comments.created_at',
    'follows.follower_id','follows.following_id','follows.created_at','likes.user_id','likes.post_id','likes.created_at',
    'messages.id','messages.sender_id','messages.recipient_id','messages.content','messages.created_at',
    'content_reports.id','content_reports.reporter_id','content_reports.post_id','content_reports.reported_user_id','content_reports.reason','content_reports.details','content_reports.created_at',
    'profiles.id','profiles.username','profiles.display_name','profiles.bio','profiles.avatar_url','profiles.created_at','profiles.updated_at',
    'bmn_verification_requests.id','bmn_verification_requests.user_id','bmn_verification_requests.request_reason','bmn_verification_requests.evidence_url',
    'bmn_verification_requests.status','bmn_verification_requests.created_at','bmn_verification_requests.reviewed_at','bmn_verification_requests.reviewed_by','bmn_verification_requests.review_note',
    'bmn_verified_users.user_id','bmn_verified_users.verified_at','bmn_verified_users.verified_by','bmn_verified_users.verification_note',
    'moderation_actions.admin_id','moderation_actions.target_user_id','moderation_actions.post_id','moderation_actions.action','moderation_actions.reason',
    'bmn_user_moderation.user_id','bmn_user_moderation.status','bmn_user_moderation.expires_at','bmn_admins.user_id','bmn_admins.role'];
  v_002 text[] := ARRAY['pi_rule_sets','pi_policy_versions','pi_policy_decisions','pi_session_observations','pi_scan_cursors',
    'pi_investigations','pi_investigation_notes','pi_system_alerts','pi_worker_heartbeats'];
BEGIN
  IF to_regclass('public.pi_schema_version') IS NULL THEN
    RAISE EXCEPTION 'Precondition failed: migration 001 is not installed (pi_schema_version is missing). Install 001 first.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 1 AND name = '001_pi_schema') THEN
    RAISE EXCEPTION 'Precondition failed: pi_schema_version has no row for 001_pi_schema.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version > 2) THEN
    RAISE EXCEPTION 'A newer Platform Intelligence schema is already installed; migration 002 will not run over it.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 2 AND name <> '002_pi_engine') THEN
    RAISE EXCEPTION 'Schema version 2 is recorded under a different name; refusing to continue.' USING ERRCODE = 'P0001';
  END IF;
  FOREACH t IN ARRAY v_tables LOOP
    IF to_regclass('public.' || t) IS NULL THEN v_missing := v_missing || t; END IF;
  END LOOP;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'Precondition failed: required table(s) missing: %', array_to_string(v_missing, ', ') USING ERRCODE = 'P0001';
  END IF;
  FOREACH f IN ARRAY v_funcs LOOP
    IF to_regprocedure(f) IS NULL THEN v_missing := v_missing || f; END IF;
  END LOOP;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'Precondition failed: required function(s) missing: %', array_to_string(v_missing, ', ') USING ERRCODE = 'P0001';
  END IF;
  FOREACH c IN ARRAY v_cols LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = split_part(c, '.', 1) AND column_name = split_part(c, '.', 2)) THEN
      v_missing := v_missing || c;
    END IF;
  END LOOP;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'Precondition failed: this database differs from the baseline BMN schema. Missing column(s): %', array_to_string(v_missing, ', ') USING ERRCODE = 'P0001';
  END IF;
  -- partial installation: some 002 tables exist but the version row does not
  IF NOT EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 2)
     AND EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname = ANY (v_002)) THEN
    RAISE EXCEPTION 'Inconsistent or partial migration-002 installation detected (some 002 tables exist but there is no version-2 row). Nothing was changed. Run 002_pi_engine.down.sql with SET pi.confirm_partial_cleanup = ''yes'' first.' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- =====================================================================================  TABLES
-- ---------------------------------------------------------------- versioned, configurable rule sets
-- Version 1 of every rule set is the built-in default shipped with the server code and is NOT stored here.
-- Published versions start at 2. A published version never changes; publishing retires the previous one.
CREATE TABLE IF NOT EXISTS public.pi_rule_sets (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_key   text NOT NULL CHECK (rule_key IN ('moderation_rules', 'account_risk_rules', 'verification_criteria', 'worker_settings')),
  version    integer NOT NULL CHECK (version >= 2),
  config     jsonb NOT NULL CHECK (jsonb_typeof(config) = 'object'),
  status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retired')),
  note       text NOT NULL CHECK (char_length(btrim(note)) > 0),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  CONSTRAINT pi_rule_sets_key_version UNIQUE (rule_key, version),
  CONSTRAINT pi_rule_sets_retired_consistent CHECK ((status = 'retired') = (retired_at IS NOT NULL))
);

-- ---------------------------------------------------------------- policy version history (snapshots of pi_policies)
CREATE TABLE IF NOT EXISTS public.pi_policy_versions (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  policy_id             uuid NOT NULL,                  -- no FK: history must outlive the policy row
  category              public.pi_category NOT NULL,
  version               integer NOT NULL,
  enabled               boolean NOT NULL,
  review_threshold      numeric(4,3),
  auto_action_threshold numeric(4,3),
  max_auto_action       text NOT NULL,
  always_human_review   boolean NOT NULL,
  changed_by            uuid,                           -- no FK on purpose (evidence survives account deletion)
  changed_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pi_policy_versions_cat_ver UNIQUE (category, version)
);

-- ---------------------------------------------------------------- versioned policy DECISIONS (what the engine decided, under which policy)
CREATE TABLE IF NOT EXISTS public.pi_policy_decisions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_kind         text NOT NULL CHECK (decision_kind IN ('content_moderation', 'account_risk', 'verification')),
  subject_type          text NOT NULL CHECK (subject_type IN ('post', 'comment', 'message', 'profile', 'media', 'account', 'report', 'verification_request')),
  subject_id            uuid NOT NULL,
  subject_user_id       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  policy_category       public.pi_category,
  policy_version        integer,
  rule_set_key          text,
  rule_set_version      integer CHECK (rule_set_version >= 1),
  outcome               text NOT NULL CHECK (char_length(btrim(outcome)) > 0),
  -- The engine can only ever RECOMMEND this safe set: there is no ban / suspend / remove / revoke value.
  recommended_action    text NOT NULL CHECK (recommended_action IN ('no_action', 'flag', 'hide_pending_review', 'warn',
                          'restrict_temporary', 'refer_to_human', 'approve_verification')),
  mode                  text NOT NULL CHECK (mode IN ('shadow', 'enforced')),
  risk_score            numeric(5,4) CHECK (risk_score BETWEEN 0 AND 1),
  confidence            numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
  requires_human_review boolean NOT NULL DEFAULT false,
  reasons               text[] NOT NULL DEFAULT '{}',
  inputs                jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(inputs) = 'object'),   -- flags, thresholds in effect
  case_id               uuid REFERENCES public.pi_moderation_cases(id) ON DELETE SET NULL,
  analysis_id           uuid REFERENCES public.pi_content_analyses(id) ON DELETE SET NULL,
  idempotency_key       text UNIQUE,
  decided_at            timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- session observations (keyed hashes only; never raw IPs)
CREATE TABLE IF NOT EXISTS public.pi_session_observations (
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  ip_hash       text NOT NULL CHECK (ip_hash ~ '^[0-9a-f]{64}$'),
  device_hash   text NOT NULL CHECK (device_hash ~ '^[0-9a-f]{64}$'),
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  seen_count    integer NOT NULL DEFAULT 1 CHECK (seen_count >= 1),
  PRIMARY KEY (user_id, ip_hash, device_hash)
);

-- ---------------------------------------------------------------- scan cursors (which new content has already been queued)
CREATE TABLE IF NOT EXISTS public.pi_scan_cursors (
  source          text PRIMARY KEY CHECK (source IN ('posts', 'comments', 'content_reports', 'profiles', 'messages')),
  last_created_at timestamptz NOT NULL,
  last_id         uuid,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- investigations
CREATE TABLE IF NOT EXISTS public.pi_investigations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  assessment_id uuid REFERENCES public.pi_account_risk_assessments(id) ON DELETE SET NULL,
  severity      text NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_review', 'closed')),
  summary       text NOT NULL CHECK (char_length(btrim(summary)) > 0),
  assigned_to   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution    text CHECK (resolution IN ('no_action_needed', 'false_positive', 'user_contacted', 'action_taken_elsewhere', 'referred')),
  opened_at     timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz,
  closed_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT pi_investigations_closed_consistent CHECK ((status = 'closed') = (closed_at IS NOT NULL)),
  CONSTRAINT pi_investigations_closed_has_resolution CHECK (status <> 'closed' OR resolution IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.pi_investigation_notes (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  investigation_id uuid NOT NULL REFERENCES public.pi_investigations(id) ON DELETE CASCADE,
  author_id        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  author_type      text NOT NULL CHECK (author_type IN ('system', 'owner', 'admin', 'moderator')),
  note             text NOT NULL CHECK (char_length(btrim(note)) > 0),
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- system alerts + worker heartbeats
CREATE TABLE IF NOT EXISTS public.pi_system_alerts (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind            text NOT NULL CHECK (char_length(btrim(kind)) > 0),
  severity        text NOT NULL CHECK (severity IN ('info', 'low', 'medium', 'high', 'critical')),
  message         text NOT NULL CHECK (char_length(btrim(message)) > 0),
  details         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  dedupe_key      text,
  occurrences     integer NOT NULL DEFAULT 1 CHECK (occurrences >= 1),
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  acknowledged_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  acknowledged_at timestamptz,
  resolved_at     timestamptz
);

CREATE TABLE IF NOT EXISTS public.pi_worker_heartbeats (
  worker_id       text PRIMARY KEY CHECK (btrim(worker_id) <> '' AND char_length(worker_id) <= 200),
  version         text,
  started_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  jobs_succeeded  bigint NOT NULL DEFAULT 0 CHECK (jobs_succeeded >= 0),
  jobs_failed     bigint NOT NULL DEFAULT 0 CHECK (jobs_failed >= 0),
  last_error      text,
  meta            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(meta) = 'object')
);

-- ---------------------------------------------------------------- indexes
CREATE UNIQUE INDEX IF NOT EXISTS pi_rule_sets_one_active   ON public.pi_rule_sets (rule_key) WHERE status = 'active';
CREATE INDEX        IF NOT EXISTS pi_policy_decisions_subj  ON public.pi_policy_decisions (subject_type, subject_id, decided_at DESC);
CREATE INDEX        IF NOT EXISTS pi_policy_decisions_user  ON public.pi_policy_decisions (subject_user_id, decided_at DESC);
CREATE INDEX        IF NOT EXISTS pi_policy_decisions_time  ON public.pi_policy_decisions (decided_at DESC);
CREATE INDEX        IF NOT EXISTS pi_session_obs_ip         ON public.pi_session_observations (ip_hash, last_seen_at DESC);
CREATE INDEX        IF NOT EXISTS pi_session_obs_device     ON public.pi_session_observations (device_hash, last_seen_at DESC);
CREATE INDEX        IF NOT EXISTS pi_session_obs_user       ON public.pi_session_observations (user_id, last_seen_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS pi_investigation_one_open ON public.pi_investigations (user_id) WHERE status <> 'closed';
CREATE INDEX        IF NOT EXISTS pi_investigations_queue   ON public.pi_investigations (severity, opened_at) WHERE status <> 'closed';
CREATE INDEX        IF NOT EXISTS pi_investigation_notes_ix ON public.pi_investigation_notes (investigation_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS pi_alerts_one_open        ON public.pi_system_alerts (dedupe_key) WHERE resolved_at IS NULL AND dedupe_key IS NOT NULL;
CREATE INDEX        IF NOT EXISTS pi_alerts_open_ix         ON public.pi_system_alerts (severity, created_at DESC) WHERE resolved_at IS NULL;
CREATE INDEX        IF NOT EXISTS pi_heartbeats_seen        ON public.pi_worker_heartbeats (last_seen_at DESC);
CREATE INDEX        IF NOT EXISTS pi_restrictions_expiry_ix ON public.pi_protective_restrictions (expires_at) WHERE lifted_at IS NULL;
CREATE INDEX        IF NOT EXISTS pi_actions_expiry_ix      ON public.pi_moderation_actions (expires_at) WHERE reversed_at IS NULL AND expires_at IS NOT NULL;

-- =====================================================================================  GUARDS (triggers on pi_ tables only)
-- Rule sets: a published version never changes; the only allowed change is active -> retired.
CREATE OR REPLACE FUNCTION public.pi_rule_sets_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'pi_rule_sets rows cannot be deleted' USING ERRCODE = '42501';
  END IF;
  IF ROW(NEW.id, NEW.rule_key, NEW.version, NEW.config, NEW.note, NEW.created_at)
     IS DISTINCT FROM ROW(OLD.id, OLD.rule_key, OLD.version, OLD.config, OLD.note, OLD.created_at) THEN
    RAISE EXCEPTION 'a published rule-set version is immutable; publish a new version instead' USING ERRCODE = '42501';
  END IF;
  IF NEW.created_by IS DISTINCT FROM OLD.created_by AND NEW.created_by IS NOT NULL THEN
    RAISE EXCEPTION 'pi_rule_sets.created_by may only be cleared' USING ERRCODE = '42501';
  END IF;
  IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
    RAISE EXCEPTION 'a retired rule-set version cannot be re-activated; publish a new version' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

-- Append-only history: policy versions, policy decisions. Reference columns may only be CLEARED
-- (that is what ON DELETE SET NULL does when a case / analysis / account is removed).
CREATE OR REPLACE FUNCTION public.pi_policy_versions_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'pi_policy_versions is append-only' USING ERRCODE = '42501';
END $$;

CREATE OR REPLACE FUNCTION public.pi_policy_decisions_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'pi_policy_decisions rows cannot be deleted' USING ERRCODE = '42501';
  END IF;
  IF ROW(NEW.id, NEW.decision_kind, NEW.subject_type, NEW.subject_id, NEW.policy_category, NEW.policy_version, NEW.rule_set_key,
         NEW.rule_set_version, NEW.outcome, NEW.recommended_action, NEW.mode, NEW.risk_score, NEW.confidence,
         NEW.requires_human_review, NEW.reasons, NEW.inputs, NEW.idempotency_key, NEW.decided_at)
     IS DISTINCT FROM
     ROW(OLD.id, OLD.decision_kind, OLD.subject_type, OLD.subject_id, OLD.policy_category, OLD.policy_version, OLD.rule_set_key,
         OLD.rule_set_version, OLD.outcome, OLD.recommended_action, OLD.mode, OLD.risk_score, OLD.confidence,
         OLD.requires_human_review, OLD.reasons, OLD.inputs, OLD.idempotency_key, OLD.decided_at) THEN
    RAISE EXCEPTION 'pi_policy_decisions core fields are immutable' USING ERRCODE = '42501';
  END IF;
  IF (NEW.subject_user_id IS DISTINCT FROM OLD.subject_user_id AND NEW.subject_user_id IS NOT NULL)
     OR (NEW.case_id IS DISTINCT FROM OLD.case_id AND NEW.case_id IS NOT NULL)
     OR (NEW.analysis_id IS DISTINCT FROM OLD.analysis_id AND NEW.analysis_id IS NOT NULL) THEN
    RAISE EXCEPTION 'pi_policy_decisions reference columns may only be cleared' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.pi_investigations_touch() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Snapshot every policy version (insert + any change that bumps the version) into pi_policy_versions.
CREATE OR REPLACE FUNCTION public.pi_policy_snapshot() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.pi_policy_versions (policy_id, category, version, enabled, review_threshold, auto_action_threshold,
                                         max_auto_action, always_human_review, changed_by)
  VALUES (NEW.id, NEW.category, NEW.version, NEW.enabled, NEW.review_threshold, NEW.auto_action_threshold,
          NEW.max_auto_action, NEW.always_human_review, NEW.updated_by)
  ON CONFLICT (category, version) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS pi_rule_sets_immutable ON public.pi_rule_sets;
CREATE TRIGGER pi_rule_sets_immutable BEFORE UPDATE OR DELETE ON public.pi_rule_sets FOR EACH ROW EXECUTE FUNCTION public.pi_rule_sets_guard();
DROP TRIGGER IF EXISTS pi_rule_sets_no_truncate ON public.pi_rule_sets;
CREATE TRIGGER pi_rule_sets_no_truncate BEFORE TRUNCATE ON public.pi_rule_sets FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_policy_versions_append_only ON public.pi_policy_versions;
CREATE TRIGGER pi_policy_versions_append_only BEFORE UPDATE OR DELETE ON public.pi_policy_versions FOR EACH ROW EXECUTE FUNCTION public.pi_policy_versions_guard();
DROP TRIGGER IF EXISTS pi_policy_versions_no_truncate ON public.pi_policy_versions;
CREATE TRIGGER pi_policy_versions_no_truncate BEFORE TRUNCATE ON public.pi_policy_versions FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_policy_decisions_immutable ON public.pi_policy_decisions;
CREATE TRIGGER pi_policy_decisions_immutable BEFORE UPDATE OR DELETE ON public.pi_policy_decisions FOR EACH ROW EXECUTE FUNCTION public.pi_policy_decisions_guard();
DROP TRIGGER IF EXISTS pi_policy_decisions_no_truncate ON public.pi_policy_decisions;
CREATE TRIGGER pi_policy_decisions_no_truncate BEFORE TRUNCATE ON public.pi_policy_decisions FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_investigations_no_truncate ON public.pi_investigations;
CREATE TRIGGER pi_investigations_no_truncate BEFORE TRUNCATE ON public.pi_investigations FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_investigations_touch ON public.pi_investigations;
CREATE TRIGGER pi_investigations_touch BEFORE UPDATE ON public.pi_investigations FOR EACH ROW EXECUTE FUNCTION public.pi_investigations_touch();
-- the one thing 002 adds to a 001 table: policy version snapshots
DROP TRIGGER IF EXISTS pi_policy_snapshot_trg ON public.pi_policies;
CREATE TRIGGER pi_policy_snapshot_trg AFTER INSERT OR UPDATE ON public.pi_policies FOR EACH ROW EXECUTE FUNCTION public.pi_policy_snapshot();

-- Seed: snapshot the policy versions that already exist (version 1 of each category), and the one new flag (OFF).
INSERT INTO public.pi_policy_versions (policy_id, category, version, enabled, review_threshold, auto_action_threshold,
                                       max_auto_action, always_human_review, changed_by)
SELECT id, category, version, enabled, review_threshold, auto_action_threshold, max_auto_action, always_human_review, updated_by
  FROM public.pi_policies
ON CONFLICT (category, version) DO NOTHING;

INSERT INTO public.pi_feature_flags (key, enabled, description) VALUES
  ('verification_evaluation', false,
   'Evaluate verification applications against the recorded criteria and show the check results to reviewers. Never approves or rejects by itself. Turn auto_verification on separately to allow approvals.')
ON CONFLICT (key) DO NOTHING;

-- =====================================================================================  FUNCTIONS
-- ---------------------------------------------------------------- owner / flag helpers
CREATE OR REPLACE FUNCTION public.pi_is_owner(p_user uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_user IS NOT NULL AND EXISTS (SELECT 1 FROM public.bmn_admins WHERE user_id = p_user AND lower(role) = 'owner');
$$;

CREATE OR REPLACE FUNCTION public.pi_assert_owner(p_actor uuid) RETURNS void
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.pi_is_owner(p_actor) THEN
    RAISE EXCEPTION 'Only the BMN owner can do this' USING ERRCODE = '42501';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.pi_automation_halted() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT enabled FROM public.pi_feature_flags WHERE key = 'emergency_halt_automation'), false);
$$;

-- A flag counts as "on" only while the emergency halt is NOT engaged.
CREATE OR REPLACE FUNCTION public.pi_flag_on(p_key text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT public.pi_automation_halted()
     AND coalesce((SELECT enabled FROM public.pi_feature_flags WHERE key = p_key), false);
$$;

-- Enforcement ("enforced" mode) is available only when the flag is on AND the enforcement hooks are installed.
-- No migration sets hooks_installed yet, so in this version every automated decision is shadow-mode.
CREATE OR REPLACE FUNCTION public.pi_enforcement_available() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.pi_flag_on('moderation_enforcement') AND public.pi_flag_on('moderation_analysis')
     AND coalesce((SELECT config ->> 'hooks_installed' FROM public.pi_feature_flags WHERE key = 'moderation_enforcement'), 'false') = 'true';
$$;

CREATE OR REPLACE FUNCTION public.pi_restrictions_enforceable() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.pi_flag_on('account_protective_restrictions') AND public.pi_flag_on('account_risk_scoring')
     AND coalesce((SELECT config ->> 'hooks_installed' FROM public.pi_feature_flags WHERE key = 'account_protective_restrictions'), 'false') = 'true';
$$;

CREATE OR REPLACE FUNCTION public.pi_json_num(p jsonb, k text) RETURNS numeric
  LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN jsonb_typeof(p -> k) = 'number' THEN (p ->> k)::numeric END;
$$;

-- ---------------------------------------------------------------- queue + alert helpers
CREATE OR REPLACE FUNCTION public.pi_enqueue_job(p_type text, p_payload jsonb DEFAULT '{}'::jsonb, p_priority smallint DEFAULT 5,
                                                 p_key text DEFAULT NULL, p_run_after timestamptz DEFAULT now())
  RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO public.pi_jobs (job_type, payload, priority, idempotency_key, run_after)
  VALUES (p_type, coalesce(p_payload, '{}'::jsonb), p_priority, p_key, coalesce(p_run_after, now()))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v;
  RETURN v;            -- NULL when a job with this idempotency key already exists (duplicate prevented)
END $$;

CREATE OR REPLACE FUNCTION public.pi_raise_alert(p_kind text, p_severity text, p_message text, p_details jsonb DEFAULT '{}'::jsonb,
                                                 p_dedupe_key text DEFAULT NULL)
  RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO public.pi_system_alerts (kind, severity, message, details, dedupe_key)
  VALUES (p_kind, p_severity, p_message, coalesce(p_details, '{}'::jsonb), p_dedupe_key)
  ON CONFLICT (dedupe_key) WHERE resolved_at IS NULL AND dedupe_key IS NOT NULL
  DO UPDATE SET occurrences = public.pi_system_alerts.occurrences + 1, last_seen_at = now(),
                details = EXCLUDED.details, severity = EXCLUDED.severity, message = EXCLUDED.message
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.pi_clear_alert(p_dedupe_key text) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n integer;
BEGIN
  UPDATE public.pi_system_alerts SET resolved_at = now() WHERE dedupe_key = p_dedupe_key AND resolved_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ---------------------------------------------------------------- rule-set validation (structure + ranges)
CREATE OR REPLACE FUNCTION public.pi_validate_rule_config(p_key text, p_config jsonb) RETURNS text
  LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  e jsonb; k text; n numeric; m numeric; h numeric; c numeric; ids text[] := '{}'; typ text; arr jsonb; term jsonb;
  known_types text[] := ARRAY['min_account_age_days', 'profile_complete', 'min_published_posts', 'min_followers', 'good_standing',
                              'max_account_risk', 'no_open_cases', 'impersonation_screen', 'manual_evidence_review', 'evidence_link_present'];
BEGIN
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN RETURN 'config must be a JSON object'; END IF;
  IF pg_column_size(p_config) > 60000 THEN RETURN 'config is too large (60 KB maximum)'; END IF;

  IF p_key = 'moderation_rules' THEN
    n := public.pi_json_num(p_config, 'hold_hours');
    IF n IS NULL OR n < 1 OR n > 72 OR n <> trunc(n) THEN RETURN 'hold_hours must be a whole number between 1 and 72'; END IF;
    n := public.pi_json_num(p_config, 'min_confidence_auto');
    IF n IS NULL OR n < 0 OR n > 1 THEN RETURN 'min_confidence_auto must be a number between 0 and 1'; END IF;
    n := public.pi_json_num(p_config, 'max_text_length');
    IF n IS NULL OR n < 100 OR n > 20000 OR n <> trunc(n) THEN RETURN 'max_text_length must be a whole number between 100 and 20000'; END IF;
    IF p_config ? 'signal_weights' THEN
      IF jsonb_typeof(p_config -> 'signal_weights') IS DISTINCT FROM 'object' THEN RETURN 'signal_weights must be an object'; END IF;
      FOR k, e IN SELECT * FROM jsonb_each(p_config -> 'signal_weights') LOOP
        IF NOT (CASE WHEN jsonb_typeof(e) = 'number' THEN (e #>> '{}')::numeric BETWEEN 0 AND 1 ELSE false END) THEN
          RETURN format('signal_weights.%s must be a number between 0 and 1', k);
        END IF;
      END LOOP;
    END IF;
    IF p_config ? 'custom_terms' THEN
      IF jsonb_typeof(p_config -> 'custom_terms') IS DISTINCT FROM 'object' THEN RETURN 'custom_terms must be an object of category -> list'; END IF;
      FOR k, arr IN SELECT * FROM jsonb_each(p_config -> 'custom_terms') LOOP
        IF k NOT IN ('harassment_bullying', 'hate_speech', 'threats_violence', 'sexual_exploitation', 'prohibited_sexual_content',
                     'spam_scams', 'impersonation', 'dangerous_prohibited', 'manipulated_engagement', 'repeated_violations') THEN
          RETURN format('custom_terms has an unknown category: %s', k);
        END IF;
        IF jsonb_typeof(arr) <> 'array' OR jsonb_array_length(arr) > 500 THEN RETURN format('custom_terms.%s must be a list of at most 500 entries', k); END IF;
        FOR term IN SELECT * FROM jsonb_array_elements(arr) LOOP
          IF jsonb_typeof(term) IS DISTINCT FROM 'object' OR jsonb_typeof(term -> 'term') IS DISTINCT FROM 'string'
             OR coalesce(char_length(term ->> 'term'), 0) NOT BETWEEN 2 AND 80
             OR public.pi_json_num(term, 'weight') IS NULL OR public.pi_json_num(term, 'weight') NOT BETWEEN 0 AND 1 THEN
            RETURN format('custom_terms.%s entries must look like {"term": "2-80 characters", "weight": 0..1}', k);
          END IF;
        END LOOP;
      END LOOP;
    END IF;
    RETURN NULL;

  ELSIF p_key = 'account_risk_rules' THEN
    IF jsonb_typeof(p_config -> 'level_thresholds') IS DISTINCT FROM 'object' THEN RETURN 'level_thresholds must be an object with medium, high and critical'; END IF;
    m := public.pi_json_num(p_config -> 'level_thresholds', 'medium');
    h := public.pi_json_num(p_config -> 'level_thresholds', 'high');
    c := public.pi_json_num(p_config -> 'level_thresholds', 'critical');
    IF m IS NULL OR h IS NULL OR c IS NULL OR NOT (0 < m AND m < h AND h < c AND c <= 1) THEN
      RETURN 'level_thresholds must satisfy 0 < medium < high < critical <= 1';
    END IF;
    n := public.pi_json_num(p_config, 'restriction_hours');
    IF n IS NULL OR n < 1 OR n > 72 OR n <> trunc(n) THEN RETURN 'restriction_hours must be a whole number between 1 and 72'; END IF;
    IF p_config ? 'limits' THEN
      IF jsonb_typeof(p_config -> 'limits') IS DISTINCT FROM 'object' THEN RETURN 'limits must be an object'; END IF;
      FOR k, e IN SELECT * FROM jsonb_each(p_config -> 'limits') LOOP
        IF NOT (CASE WHEN jsonb_typeof(e) = 'number' THEN (e #>> '{}')::numeric >= 1 ELSE false END) THEN RETURN format('limits.%s must be a number >= 1', k); END IF;
      END LOOP;
    END IF;
    RETURN NULL;

  ELSIF p_key = 'verification_criteria' THEN
    IF jsonb_typeof(p_config -> 'checks') IS DISTINCT FROM 'array' THEN RETURN 'checks must be a list of 1 to 30 checks'; END IF;
    IF jsonb_array_length(p_config -> 'checks') NOT BETWEEN 1 AND 30 THEN
      RETURN 'checks must be a list of 1 to 30 checks';
    END IF;
    FOR e IN SELECT * FROM jsonb_array_elements(p_config -> 'checks') LOOP
      IF jsonb_typeof(e) IS DISTINCT FROM 'object' THEN RETURN 'each check must be an object'; END IF;
      IF jsonb_typeof(e -> 'id') IS DISTINCT FROM 'string' OR coalesce(e ->> 'id', '') !~ '^[a-z][a-z0-9_]{1,39}$' THEN RETURN 'each check needs an id of lowercase letters, digits and underscores'; END IF;
      IF (e ->> 'id') = ANY (ids) THEN RETURN format('duplicate check id: %s', e ->> 'id'); END IF;
      ids := ids || (e ->> 'id');
      typ := e ->> 'type';
      IF typ IS NULL OR NOT (typ = ANY (known_types)) THEN RETURN format('unknown check type: %s', coalesce(typ, 'NULL')); END IF;
      IF jsonb_typeof(e -> 'required') IS DISTINCT FROM 'boolean' THEN RETURN format('check %s needs required: true or false', e ->> 'id'); END IF;
      IF e ? 'value' AND NOT (CASE WHEN jsonb_typeof(e -> 'value') = 'number' THEN (e ->> 'value')::numeric >= 0 ELSE false END) THEN RETURN format('check %s: value must be a number >= 0', e ->> 'id'); END IF;
      IF typ = 'max_account_risk' AND (e ->> 'level') IS NOT NULL AND (e ->> 'level') NOT IN ('low', 'medium') THEN RETURN format('check %s: level must be low or medium', e ->> 'id'); END IF;
    END LOOP;
    RETURN NULL;

  ELSIF p_key = 'worker_settings' THEN
    n := public.pi_json_num(p_config, 'tick_seconds');
    IF n IS NULL OR n < 5 OR n > 300 THEN RETURN 'tick_seconds must be between 5 and 300'; END IF;
    n := public.pi_json_num(p_config, 'batch_size');
    IF n IS NULL OR n < 1 OR n > 50 THEN RETURN 'batch_size must be between 1 and 50'; END IF;
    n := public.pi_json_num(p_config, 'scan_batch');
    IF n IS NULL OR n < 10 OR n > 500 THEN RETURN 'scan_batch must be between 10 and 500'; END IF;
    n := public.pi_json_num(p_config, 'assess_interval_minutes');
    IF n IS NULL OR n < 5 OR n > 120 THEN RETURN 'assess_interval_minutes must be between 5 and 120'; END IF;
    RETURN NULL;
  END IF;
  RETURN 'unknown rule set';
END $$;

-- ---------------------------------------------------------------- owner: flags, policies, rule sets
CREATE OR REPLACE FUNCTION public.pi_owner_set_flag(p_actor uuid, p_key text, p_enabled boolean, p_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE f public.pi_feature_flags; v_after public.pi_feature_flags;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'enabled must be true or false' USING ERRCODE = '22023'; END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required to change a feature flag' USING ERRCODE = '22023'; END IF;
  SELECT * INTO f FROM public.pi_feature_flags WHERE key = p_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown feature flag %', p_key USING ERRCODE = 'P0002'; END IF;
  IF p_enabled AND NOT f.enabled THEN
    -- dependencies: a switch cannot be turned on while what it relies on is off
    IF p_key = 'moderation_enforcement' THEN
      IF NOT EXISTS (SELECT 1 FROM public.pi_feature_flags WHERE key = 'moderation_analysis' AND enabled) THEN
        RAISE EXCEPTION 'moderation_enforcement needs moderation_analysis to be on first' USING ERRCODE = '55000';
      END IF;
      IF coalesce(f.config ->> 'hooks_installed', 'false') <> 'true' THEN
        RAISE EXCEPTION 'moderation_enforcement cannot be enabled yet: the enforcement hooks (migration 003) are not installed. Decisions stay in shadow mode.' USING ERRCODE = '55000';
      END IF;
    ELSIF p_key = 'account_protective_restrictions' THEN
      IF NOT EXISTS (SELECT 1 FROM public.pi_feature_flags WHERE key = 'account_risk_scoring' AND enabled) THEN
        RAISE EXCEPTION 'account_protective_restrictions needs account_risk_scoring to be on first' USING ERRCODE = '55000';
      END IF;
      IF coalesce(f.config ->> 'hooks_installed', 'false') <> 'true' THEN
        RAISE EXCEPTION 'account_protective_restrictions cannot be enabled yet: the enforcement hooks (migration 003) are not installed. Restrictions stay in shadow mode.' USING ERRCODE = '55000';
      END IF;
    ELSIF p_key = 'moderation_message_scanning' THEN
      IF NOT EXISTS (SELECT 1 FROM public.pi_feature_flags WHERE key = 'moderation_analysis' AND enabled) THEN
        RAISE EXCEPTION 'moderation_message_scanning needs moderation_analysis to be on first' USING ERRCODE = '55000';
      END IF;
    ELSIF p_key = 'auto_verification' THEN
      IF NOT EXISTS (SELECT 1 FROM public.pi_feature_flags WHERE key = 'verification_evaluation' AND enabled) THEN
        RAISE EXCEPTION 'auto_verification needs verification_evaluation to be on first' USING ERRCODE = '55000';
      END IF;
    END IF;
  END IF;
  -- turning a prerequisite off also turns off what depends on it, so no flag is left on without its foundation
  UPDATE public.pi_feature_flags SET enabled = p_enabled, updated_by = p_actor WHERE key = p_key RETURNING * INTO v_after;
  IF NOT p_enabled THEN
    IF p_key = 'moderation_analysis' THEN
      UPDATE public.pi_feature_flags SET enabled = false, updated_by = p_actor WHERE key IN ('moderation_enforcement', 'moderation_message_scanning') AND enabled;
    ELSIF p_key = 'account_risk_scoring' THEN
      UPDATE public.pi_feature_flags SET enabled = false, updated_by = p_actor WHERE key = 'account_protective_restrictions' AND enabled;
    ELSIF p_key = 'verification_evaluation' THEN
      UPDATE public.pi_feature_flags SET enabled = false, updated_by = p_actor WHERE key = 'auto_verification' AND enabled;
    END IF;
  END IF;
  PERFORM public.pi_write_audit(p_actor, 'owner', 'feature_flag_changed', 'feature_flag', p_key,
            jsonb_build_object('enabled', f.enabled), jsonb_build_object('enabled', p_enabled), p_reason);
  RETURN to_jsonb(v_after);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_update_policy(p_actor uuid, p_category text, p_enabled boolean, p_review numeric,
    p_auto numeric, p_max_auto text, p_always_human boolean, p_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.pi_policies; n public.pi_policies;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required to change a policy' USING ERRCODE = '22023'; END IF;
  SELECT * INTO o FROM public.pi_policies WHERE category::text = p_category FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown policy category %', p_category USING ERRCODE = 'P0002'; END IF;
  -- Serious categories must always reach a human. This cannot be switched off from the console.
  IF o.always_human_review AND NOT coalesce(p_always_human, true) THEN
    RAISE EXCEPTION 'the % policy always requires human review; this cannot be disabled', p_category USING ERRCODE = '42501';
  END IF;
  UPDATE public.pi_policies
     SET enabled = coalesce(p_enabled, enabled), review_threshold = p_review, auto_action_threshold = p_auto,
         max_auto_action = coalesce(p_max_auto, max_auto_action), always_human_review = coalesce(p_always_human, always_human_review),
         updated_by = p_actor
   WHERE id = o.id RETURNING * INTO n;      -- table CHECK constraints validate thresholds and the allowed (non-severe) action set
  PERFORM public.pi_write_audit(p_actor, 'owner', 'policy_changed', 'policy', p_category,
            jsonb_build_object('version', o.version, 'enabled', o.enabled, 'review_threshold', o.review_threshold,
                               'auto_action_threshold', o.auto_action_threshold, 'max_auto_action', o.max_auto_action),
            jsonb_build_object('version', n.version, 'enabled', n.enabled, 'review_threshold', n.review_threshold,
                               'auto_action_threshold', n.auto_action_threshold, 'max_auto_action', n.max_auto_action), p_reason);
  RETURN to_jsonb(n);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_publish_rule_set(p_actor uuid, p_key text, p_config jsonb, p_note text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_err text; v_prev integer; v_new integer; r public.pi_rule_sets;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_note IS NULL OR btrim(p_note) = '' THEN RAISE EXCEPTION 'a note describing the change is required' USING ERRCODE = '22023'; END IF;
  IF p_key IS NULL OR p_key NOT IN ('moderation_rules', 'account_risk_rules', 'verification_criteria', 'worker_settings') THEN
    RAISE EXCEPTION 'unknown rule set' USING ERRCODE = '22023';
  END IF;
  v_err := public.pi_validate_rule_config(p_key, p_config);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'invalid rule set: %', v_err USING ERRCODE = '22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pi_rule_sets:' || p_key));
  SELECT max(version) INTO v_prev FROM public.pi_rule_sets WHERE rule_key = p_key;
  v_new := greatest(coalesce(v_prev, 1), 1) + 1;
  UPDATE public.pi_rule_sets SET status = 'retired', retired_at = now() WHERE rule_key = p_key AND status = 'active';
  INSERT INTO public.pi_rule_sets (rule_key, version, config, note, created_by) VALUES (p_key, v_new, p_config, p_note, p_actor) RETURNING * INTO r;
  PERFORM public.pi_write_audit(p_actor, 'owner', 'rule_set_published', 'rule_set', p_key,
            jsonb_build_object('version', coalesce(v_prev, 1)), jsonb_build_object('version', v_new, 'config', p_config), p_note);
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.pi_get_active_rules(p_key text) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('version', version, 'config', config) FROM public.pi_rule_sets WHERE rule_key = p_key AND status = 'active';
$$;

-- Everything the workers need to know in one round trip.
CREATE OR REPLACE FUNCTION public.pi_get_runtime_config() RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'halted', public.pi_automation_halted(),
    'flags', (SELECT coalesce(jsonb_object_agg(key, jsonb_build_object('enabled', enabled, 'config', config)), '{}'::jsonb) FROM public.pi_feature_flags),
    'policies', (SELECT coalesce(jsonb_object_agg(category::text, jsonb_build_object('enabled', enabled, 'version', version,
                   'review_threshold', review_threshold, 'auto_action_threshold', auto_action_threshold,
                   'max_auto_action', max_auto_action, 'always_human_review', always_human_review)), '{}'::jsonb) FROM public.pi_policies),
    'rule_sets', (SELECT coalesce(jsonb_object_agg(rule_key, jsonb_build_object('version', version, 'config', config)), '{}'::jsonb)
                    FROM public.pi_rule_sets WHERE status = 'active'),
    'enforcement_available', public.pi_enforcement_available(),
    'restrictions_enforceable', public.pi_restrictions_enforceable());
$$;

-- ---------------------------------------------------------------- facts the engines read (counts and flags; no private text is stored)
-- Called by the account-protection beacon. Stores keyed hashes only.
CREATE OR REPLACE FUNCTION public.pi_record_session(p_user uuid, p_ip_hash text, p_device_hash text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_ip_known boolean; v_dev_known boolean; v_age numeric;
BEGIN
  IF NOT public.pi_flag_on('account_risk_scoring') THEN RETURN jsonb_build_object('recorded', false); END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_user) THEN RETURN jsonb_build_object('recorded', false); END IF;
  SELECT EXISTS (SELECT 1 FROM public.pi_session_observations WHERE user_id = p_user AND ip_hash = p_ip_hash),
         EXISTS (SELECT 1 FROM public.pi_session_observations WHERE user_id = p_user AND device_hash = p_device_hash)
    INTO v_ip_known, v_dev_known;
  INSERT INTO public.pi_session_observations (user_id, ip_hash, device_hash) VALUES (p_user, p_ip_hash, p_device_hash)
  ON CONFLICT (user_id, ip_hash, device_hash) DO UPDATE
    SET last_seen_at = now(), seen_count = public.pi_session_observations.seen_count + 1;
  SELECT extract(epoch FROM (now() - created_at)) / 86400 INTO v_age FROM public.profiles WHERE id = p_user;
  RETURN jsonb_build_object('recorded', true, 'new_ip', NOT v_ip_known, 'new_device', NOT v_dev_known, 'account_age_days', v_age,
    'ips_24h', (SELECT count(DISTINCT ip_hash) FROM public.pi_session_observations WHERE user_id = p_user AND last_seen_at > now() - interval '24 hours'),
    'devices_24h', (SELECT count(DISTINCT device_hash) FROM public.pi_session_observations WHERE user_id = p_user AND last_seen_at > now() - interval '24 hours'),
    'users_on_ip_24h', (SELECT count(DISTINCT user_id) FROM public.pi_session_observations WHERE ip_hash = p_ip_hash AND last_seen_at > now() - interval '24 hours'),
    'users_on_device_7d', (SELECT count(DISTINCT user_id) FROM public.pi_session_observations WHERE device_hash = p_device_hash AND last_seen_at > now() - interval '7 days'));
END $$;

CREATE OR REPLACE FUNCTION public.pi_add_security_event(p jsonb) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v bigint;
BEGIN
  IF NOT public.pi_flag_on('account_risk_scoring') THEN RETURN NULL; END IF;
  INSERT INTO public.pi_security_events (user_id, event_type, severity, source, ip_hash, device_hash, details, dedupe_key)
  VALUES (nullif(p ->> 'user_id', '')::uuid, p ->> 'event_type', p ->> 'severity', p ->> 'source', nullif(p ->> 'ip_hash', ''),
          nullif(p ->> 'device_hash', ''), coalesce(p -> 'details', '{}'::jsonb), nullif(p ->> 'dedupe_key', ''))
  ON CONFLICT (dedupe_key) DO NOTHING
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.pi_user_activity_summary(p_user uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  SELECT jsonb_build_object(
    'user_id', p_user,
    'account_exists', EXISTS (SELECT 1 FROM auth.users WHERE id = p_user),
    'account_age_days', (SELECT extract(epoch FROM (now() - created_at)) / 86400 FROM public.profiles WHERE id = p_user),
    'posts_1h',  (SELECT count(*) FROM public.posts WHERE user_id = p_user AND created_at > now() - interval '1 hour'),
    'posts_24h', (SELECT count(*) FROM public.posts WHERE user_id = p_user AND created_at > now() - interval '24 hours'),
    'comments_1h',  (SELECT count(*) FROM public.comments WHERE user_id = p_user AND created_at > now() - interval '1 hour'),
    'comments_24h', (SELECT count(*) FROM public.comments WHERE user_id = p_user AND created_at > now() - interval '24 hours'),
    'duplicate_comments_24h', (SELECT coalesce(count(*) - count(DISTINCT md5(lower(btrim(coalesce(content, body, ''))))), 0)
                                 FROM public.comments WHERE user_id = p_user AND created_at > now() - interval '24 hours'),
    'likes_1h',  (SELECT count(*) FROM public.likes WHERE user_id = p_user AND created_at > now() - interval '1 hour'),
    'likes_24h', (SELECT count(*) FROM public.likes WHERE user_id = p_user AND created_at > now() - interval '24 hours'),
    'follows_1h',  (SELECT count(*) FROM public.follows WHERE follower_id = p_user AND created_at > now() - interval '1 hour'),
    'follows_24h', (SELECT count(*) FROM public.follows WHERE follower_id = p_user AND created_at > now() - interval '24 hours'),
    'followers_gained_24h', (SELECT count(*) FROM public.follows WHERE following_id = p_user AND created_at > now() - interval '24 hours'),
    'messages_1h', (SELECT count(*) FROM public.messages WHERE sender_id = p_user AND created_at > now() - interval '1 hour'),
    'message_recipients_1h', (SELECT count(DISTINCT recipient_id) FROM public.messages WHERE sender_id = p_user AND created_at > now() - interval '1 hour'),
    'reporters_7d', (SELECT count(DISTINCT r.reporter_id) FROM public.content_reports r LEFT JOIN public.posts p ON p.id = r.post_id
                      WHERE (r.reported_user_id = p_user OR p.user_id = p_user) AND r.created_at > now() - interval '7 days'),
    'violations_90d', public.pi_violation_count(p_user, interval '90 days'),
    'active_restrictions', (SELECT count(*) FROM public.pi_protective_restrictions WHERE user_id = p_user AND lifted_at IS NULL AND expires_at > now()),
    'open_cases', (SELECT count(*) FROM public.pi_moderation_cases WHERE subject_user_id = p_user AND status IN ('open', 'awaiting_review')),
    'account_status', coalesce((SELECT status FROM public.bmn_user_moderation WHERE user_id = p_user AND (expires_at IS NULL OR expires_at > now())), 'active'),
    'verified', EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = p_user),
    'ips_24h', (SELECT count(DISTINCT ip_hash) FROM public.pi_session_observations WHERE user_id = p_user AND last_seen_at > now() - interval '24 hours'),
    'devices_24h', (SELECT count(DISTINCT device_hash) FROM public.pi_session_observations WHERE user_id = p_user AND last_seen_at > now() - interval '24 hours'),
    'shared_device_accounts_7d', (SELECT coalesce(max(c), 0) FROM (
        SELECT count(DISTINCT o2.user_id) - 1 AS c
          FROM public.pi_session_observations o1 JOIN public.pi_session_observations o2 ON o2.device_hash = o1.device_hash AND o2.last_seen_at > now() - interval '7 days'
         WHERE o1.user_id = p_user AND o1.last_seen_at > now() - interval '7 days' GROUP BY o1.device_hash) s)
  ) INTO r;
  RETURN r;
END $$;

-- Transient text for analysis. The caller hashes it and must never store it.
CREATE OR REPLACE FUNCTION public.pi_fetch_subject(p_type text, p_id uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; v_user uuid;
BEGIN
  IF p_type = 'post' THEN
    SELECT jsonb_build_object('found', true, 'user_id', user_id, 'status', status, 'created_at', created_at,
        'text', concat_ws(E'\n', nullif(nullif(btrim(title), ''), 'Community post'), caption, content, array_to_string(tags, ' ')),
        'has_media', (coalesce(video_url, media_url) IS NOT NULL), 'tag_count', coalesce(cardinality(tags), 0))
      INTO r FROM public.posts WHERE id = p_id;
  ELSIF p_type = 'comment' THEN
    SELECT jsonb_build_object('found', true, 'user_id', user_id, 'created_at', created_at, 'text', coalesce(content, body, '')) INTO r
      FROM public.comments WHERE id = p_id;
  ELSIF p_type = 'message' THEN
    IF NOT public.pi_flag_on('moderation_message_scanning') THEN RETURN jsonb_build_object('found', false, 'reason', 'message scanning is off'); END IF;
    SELECT jsonb_build_object('found', true, 'user_id', sender_id, 'created_at', created_at, 'text', content) INTO r
      FROM public.messages WHERE id = p_id;
  ELSIF p_type = 'profile' THEN
    SELECT jsonb_build_object('found', true, 'user_id', id, 'created_at', created_at, 'username', username, 'display_name', display_name,
        'text', concat_ws(E'\n', bio), 'has_avatar', (avatar_url IS NOT NULL),
        'verified', EXISTS (SELECT 1 FROM public.bmn_verified_users v WHERE v.user_id = profiles.id),
        'is_owner', public.pi_is_owner(profiles.id)) INTO r FROM public.profiles WHERE id = p_id;
  ELSE
    RETURN jsonb_build_object('found', false, 'reason', 'unsupported subject type');
  END IF;
  IF r IS NULL THEN RETURN jsonb_build_object('found', false, 'reason', 'not found'); END IF;
  v_user := (r ->> 'user_id')::uuid;
  RETURN r || jsonb_build_object(
    'account_age_days', (SELECT extract(epoch FROM (now() - created_at)) / 86400 FROM public.profiles WHERE id = v_user),
    'author_verified', EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = v_user),
    'author_posts_1h', (SELECT count(*) FROM public.posts WHERE user_id = v_user AND created_at > now() - interval '1 hour'));
END $$;

CREATE OR REPLACE FUNCTION public.pi_duplicate_count(p_hash text, p_window interval DEFAULT interval '24 hours') RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('analyses', count(*), 'distinct_users', count(DISTINCT subject_user_id))
    FROM public.pi_content_analyses WHERE content_hash = p_hash AND analysed_at > now() - p_window;
$$;

CREATE OR REPLACE FUNCTION public.pi_verification_facts(p_request_id uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.bmn_verification_requests; p public.profiles;
BEGIN
  SELECT * INTO q FROM public.bmn_verification_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT * INTO p FROM public.profiles WHERE id = q.user_id;
  RETURN jsonb_build_object('found', true,
    'request', jsonb_build_object('id', q.id, 'user_id', q.user_id, 'status', q.status, 'created_at', q.created_at,
        'reason_length', char_length(btrim(q.request_reason)), 'evidence_url', q.evidence_url),
    'profile', jsonb_build_object('exists', p.id IS NOT NULL, 'username', p.username, 'display_name', p.display_name,
        'has_avatar', coalesce(btrim(p.avatar_url), '') <> '', 'has_bio', coalesce(btrim(p.bio), '') <> ''),
    'account_age_days', (SELECT extract(epoch FROM (now() - created_at)) / 86400 FROM public.profiles WHERE id = q.user_id),
    'published_posts', (SELECT count(*) FROM public.posts WHERE user_id = q.user_id AND status = 'published'),
    'followers', (SELECT count(*) FROM public.follows WHERE following_id = q.user_id),
    'account_status', coalesce((SELECT status FROM public.bmn_user_moderation WHERE user_id = q.user_id AND (expires_at IS NULL OR expires_at > now())), 'active'),
    'violations_180d', public.pi_violation_count(q.user_id, interval '180 days'),
    'active_restrictions', (SELECT count(*) FROM public.pi_protective_restrictions WHERE user_id = q.user_id AND lifted_at IS NULL AND expires_at > now()),
    'open_cases', (SELECT count(*) FROM public.pi_moderation_cases WHERE subject_user_id = q.user_id AND status IN ('open', 'awaiting_review')),
    'current_risk_level', (SELECT risk_level FROM public.pi_account_risk_assessments WHERE user_id = q.user_id AND is_current AND (expires_at IS NULL OR expires_at > now())),
    'already_verified', EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = q.user_id),
    'prior_rejections', (SELECT count(*) FROM public.bmn_verification_requests WHERE user_id = q.user_id AND status = 'rejected'),
    'fraud_history', EXISTS (SELECT 1 FROM public.pi_verification_decisions WHERE user_id = q.user_id AND (fraud_related OR decision = 'revoked')),
    'verified_names', (SELECT coalesce(jsonb_agg(jsonb_build_object('user_id', v.user_id, 'username', pr.username, 'display_name', pr.display_name)), '[]'::jsonb)
                         FROM (SELECT user_id FROM public.bmn_verified_users WHERE user_id <> q.user_id LIMIT 2000) v
                         JOIN public.profiles pr ON pr.id = v.user_id));
END $$;

-- Names of verified accounts, for the impersonation screen of profile analysis (public information only).
CREATE OR REPLACE FUNCTION public.pi_verified_names(p_limit integer DEFAULT 2000) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_id', v.user_id, 'username', pr.username, 'display_name', pr.display_name)), '[]'::jsonb)
    FROM (SELECT user_id FROM public.bmn_verified_users ORDER BY verified_at LIMIT least(greatest(coalesce(p_limit, 2000), 1), 5000)) v
    JOIN public.profiles pr ON pr.id = v.user_id;
$$;

-- ---------------------------------------------------------------- sweepers: turn new activity into queued jobs (IDs only, never text)
-- Cursors start at "now", so enabling analysis never back-fills old private or public history.
CREATE OR REPLACE FUNCTION public.pi_enqueue_new_content(p_limit integer DEFAULT 200) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_total integer := 0; cur public.pi_scan_cursors; r record; v_ts timestamptz; v_id uuid; v_stype text; v_sid uuid;
  v_zero constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN RAISE EXCEPTION 'limit must be between 1 and 1000' USING ERRCODE = '22023'; END IF;
  IF NOT public.pi_flag_on('moderation_analysis') THEN RETURN 0; END IF;

  -- posts (published, by creation time)
  INSERT INTO public.pi_scan_cursors (source, last_created_at) VALUES ('posts', now()) ON CONFLICT (source) DO NOTHING;
  SELECT * INTO cur FROM public.pi_scan_cursors WHERE source = 'posts' FOR UPDATE;
  v_ts := NULL;
  FOR r IN SELECT id, created_at FROM public.posts
            WHERE status = 'published' AND created_at <= now() - interval '5 seconds'
              AND (created_at, id) > (cur.last_created_at, coalesce(cur.last_id, v_zero))
            ORDER BY created_at, id LIMIT p_limit LOOP
    PERFORM public.pi_enqueue_job('analyze_content', jsonb_build_object('subject_type', 'post', 'subject_id', r.id), 5::smallint, 'analyze:post:' || r.id);
    v_total := v_total + 1; v_ts := r.created_at; v_id := r.id;
  END LOOP;
  IF v_ts IS NOT NULL THEN UPDATE public.pi_scan_cursors SET last_created_at = v_ts, last_id = v_id, updated_at = now() WHERE source = 'posts'; END IF;

  -- comments
  INSERT INTO public.pi_scan_cursors (source, last_created_at) VALUES ('comments', now()) ON CONFLICT (source) DO NOTHING;
  SELECT * INTO cur FROM public.pi_scan_cursors WHERE source = 'comments' FOR UPDATE;
  v_ts := NULL;
  FOR r IN SELECT id, created_at FROM public.comments
            WHERE created_at <= now() - interval '5 seconds' AND (created_at, id) > (cur.last_created_at, coalesce(cur.last_id, v_zero))
            ORDER BY created_at, id LIMIT p_limit LOOP
    PERFORM public.pi_enqueue_job('analyze_content', jsonb_build_object('subject_type', 'comment', 'subject_id', r.id), 5::smallint, 'analyze:comment:' || r.id);
    v_total := v_total + 1; v_ts := r.created_at; v_id := r.id;
  END LOOP;
  IF v_ts IS NOT NULL THEN UPDATE public.pi_scan_cursors SET last_created_at = v_ts, last_id = v_id, updated_at = now() WHERE source = 'comments'; END IF;

  -- user reports: highest priority; a report about an account is analysed through that account's profile
  INSERT INTO public.pi_scan_cursors (source, last_created_at) VALUES ('content_reports', now()) ON CONFLICT (source) DO NOTHING;
  SELECT * INTO cur FROM public.pi_scan_cursors WHERE source = 'content_reports' FOR UPDATE;
  v_ts := NULL;
  FOR r IN SELECT id, post_id, reported_user_id, reason, created_at FROM public.content_reports
            WHERE created_at <= now() - interval '2 seconds' AND (created_at, id) > (cur.last_created_at, coalesce(cur.last_id, v_zero))
            ORDER BY created_at, id LIMIT p_limit LOOP
    v_stype := NULL; v_sid := NULL;
    IF r.post_id IS NOT NULL THEN v_stype := 'post'; v_sid := r.post_id;
    ELSIF r.reported_user_id IS NOT NULL THEN v_stype := 'profile'; v_sid := r.reported_user_id; END IF;
    IF v_stype IS NOT NULL THEN
      PERFORM public.pi_enqueue_job('analyze_content',
        jsonb_build_object('subject_type', v_stype, 'subject_id', v_sid, 'report_id', r.id, 'source', 'user_report', 'report_reason', r.reason),
        2::smallint, 'analyze:report:' || r.id);
      v_total := v_total + 1;
    END IF;
    v_ts := r.created_at; v_id := r.id;
  END LOOP;
  IF v_ts IS NOT NULL THEN UPDATE public.pi_scan_cursors SET last_created_at = v_ts, last_id = v_id, updated_at = now() WHERE source = 'content_reports'; END IF;

  -- profiles (name / bio changes). Re-analysis of an unchanged profile is skipped by the worker via the content hash.
  INSERT INTO public.pi_scan_cursors (source, last_created_at) VALUES ('profiles', now()) ON CONFLICT (source) DO NOTHING;
  SELECT * INTO cur FROM public.pi_scan_cursors WHERE source = 'profiles' FOR UPDATE;
  v_ts := NULL;
  FOR r IN SELECT id, updated_at FROM public.profiles
            WHERE updated_at <= now() - interval '5 seconds' AND (updated_at, id) > (cur.last_created_at, coalesce(cur.last_id, v_zero))
            ORDER BY updated_at, id LIMIT p_limit LOOP
    PERFORM public.pi_enqueue_job('analyze_content', jsonb_build_object('subject_type', 'profile', 'subject_id', r.id), 6::smallint,
                                  'analyze:profile:' || r.id || ':' || (extract(epoch FROM r.updated_at) * 1000)::bigint);
    v_total := v_total + 1; v_ts := r.updated_at; v_id := r.id;
  END LOOP;
  IF v_ts IS NOT NULL THEN UPDATE public.pi_scan_cursors SET last_created_at = v_ts, last_id = v_id, updated_at = now() WHERE source = 'profiles'; END IF;

  -- private messages: ONLY while the privacy-sensitive flag is on; while it is off the cursor keeps pace with "now"
  INSERT INTO public.pi_scan_cursors (source, last_created_at) VALUES ('messages', now()) ON CONFLICT (source) DO NOTHING;
  SELECT * INTO cur FROM public.pi_scan_cursors WHERE source = 'messages' FOR UPDATE;
  IF NOT public.pi_flag_on('moderation_message_scanning') THEN
    UPDATE public.pi_scan_cursors SET last_created_at = now(), last_id = NULL, updated_at = now() WHERE source = 'messages';
  ELSE
    v_ts := NULL;
    FOR r IN SELECT id, created_at FROM public.messages
              WHERE created_at <= now() - interval '5 seconds' AND (created_at, id) > (cur.last_created_at, coalesce(cur.last_id, v_zero))
              ORDER BY created_at, id LIMIT p_limit LOOP
      PERFORM public.pi_enqueue_job('analyze_content', jsonb_build_object('subject_type', 'message', 'subject_id', r.id), 5::smallint, 'analyze:message:' || r.id);
      v_total := v_total + 1; v_ts := r.created_at; v_id := r.id;
    END LOOP;
    IF v_ts IS NOT NULL THEN UPDATE public.pi_scan_cursors SET last_created_at = v_ts, last_id = v_id, updated_at = now() WHERE source = 'messages'; END IF;
  END IF;
  RETURN v_total;
END $$;

CREATE OR REPLACE FUNCTION public.pi_enqueue_account_assessments(p_limit integer DEFAULT 100) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_total integer := 0; r record; v_mins integer; v_bucket bigint; v_id uuid;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN RAISE EXCEPTION 'limit must be between 1 and 1000' USING ERRCODE = '22023'; END IF;
  IF NOT public.pi_flag_on('account_risk_scoring') THEN RETURN 0; END IF;
  SELECT coalesce((config ->> 'assess_interval_minutes')::integer, 30) INTO v_mins FROM public.pi_rule_sets WHERE rule_key = 'worker_settings' AND status = 'active';
  v_mins := coalesce(v_mins, 30);
  v_bucket := floor(extract(epoch FROM now()) / (v_mins * 60))::bigint;
  FOR r IN
    SELECT DISTINCT s.u AS user_id FROM (
      SELECT follower_id AS u FROM public.follows  WHERE created_at > now() - make_interval(mins => v_mins)
      UNION ALL SELECT user_id FROM public.posts    WHERE created_at > now() - make_interval(mins => v_mins)
      UNION ALL SELECT user_id FROM public.comments WHERE created_at > now() - make_interval(mins => v_mins)
      UNION ALL SELECT user_id FROM public.likes    WHERE created_at > now() - make_interval(mins => v_mins)
      UNION ALL SELECT sender_id FROM public.messages WHERE created_at > now() - make_interval(mins => v_mins)
      UNION ALL SELECT user_id FROM public.pi_session_observations WHERE last_seen_at > now() - make_interval(mins => v_mins)) s
    WHERE s.u IS NOT NULL LIMIT p_limit
  LOOP
    v_id := public.pi_enqueue_job('assess_account', jsonb_build_object('user_id', r.user_id), 6::smallint, 'assess:' || r.user_id || ':' || v_bucket);
    IF v_id IS NOT NULL THEN v_total := v_total + 1; END IF;
  END LOOP;
  RETURN v_total;
END $$;

CREATE OR REPLACE FUNCTION public.pi_enqueue_verification_evaluations(p_limit integer DEFAULT 50) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_total integer := 0; r record; v_id uuid;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN RAISE EXCEPTION 'limit must be between 1 and 500' USING ERRCODE = '22023'; END IF;
  IF NOT public.pi_flag_on('verification_evaluation') THEN RETURN 0; END IF;
  FOR r IN SELECT q.id FROM public.bmn_verification_requests q
            WHERE q.status = 'pending' AND NOT EXISTS (SELECT 1 FROM public.pi_verification_evaluations e WHERE e.verification_request_id = q.id)
            ORDER BY q.created_at LIMIT p_limit LOOP
    v_id := public.pi_enqueue_job('evaluate_verification', jsonb_build_object('request_id', r.id), 4::smallint, 'verify:' || r.id);
    IF v_id IS NOT NULL THEN v_total := v_total + 1; END IF;
  END LOOP;
  RETURN v_total;
END $$;

-- ---------------------------------------------------------------- COMMIT: content analysis -> case / action / decision / audit (one transaction)
CREATE OR REPLACE FUNCTION public.pi_commit_moderation_result(p jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_key text := p ->> 'idempotency_key';
  v_type text := p ->> 'subject_type';
  v_subject uuid := (p ->> 'subject_id')::uuid;
  v_user uuid := nullif(p ->> 'subject_user_id', '')::uuid;
  v_source text := coalesce(nullif(p ->> 'source', ''), 'automated');
  v_cat text := nullif(p ->> 'top_category', '');
  v_outcome text := p ->> 'outcome';
  v_rec text := coalesce(p #>> '{decision,recommended_action}', 'no_action');
  v_mode text := coalesce(p #>> '{decision,mode}', 'shadow');
  v_human boolean := coalesce((p #>> '{decision,requires_human_review}')::boolean, false);
  v_hours integer := least(greatest(coalesce((p #>> '{decision,hold_hours}')::integer, 24), 1), 72);
  v_prio smallint := least(greatest(coalesce((p #>> '{decision,case_priority}')::integer, 3), 1), 4);
  v_risk numeric := nullif(p ->> 'risk_score', '')::numeric;
  v_conf numeric := nullif(p ->> 'confidence', '')::numeric;
  v_rule_ver integer := coalesce((p ->> 'rule_set_version')::integer, 1);
  v_pol public.pi_policies; v_exist uuid; v_case uuid; v_analysis uuid; v_action uuid; v_decision uuid; v_need_case boolean; v_expires timestamptz;
  v_rank text[] := ARRAY['none', 'flag', 'hide_pending_review', 'warn', 'restrict_temporary'];
BEGIN
  IF v_key IS NULL OR btrim(v_key) = '' THEN RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = '22023'; END IF;
  IF NOT public.pi_flag_on('moderation_analysis') THEN
    RAISE EXCEPTION 'content analysis is switched off or automation is halted' USING ERRCODE = '55000';
  END IF;
  IF v_type = 'message' AND NOT public.pi_flag_on('moderation_message_scanning') THEN
    RAISE EXCEPTION 'private message scanning is switched off' USING ERRCODE = '55000';
  END IF;
  IF v_rec NOT IN ('no_action', 'flag', 'hide_pending_review', 'warn', 'restrict_temporary', 'refer_to_human') THEN
    RAISE EXCEPTION 'recommended action % is not allowed for automation', v_rec USING ERRCODE = '22023';
  END IF;
  IF v_mode NOT IN ('shadow', 'enforced') THEN RAISE EXCEPTION 'invalid mode' USING ERRCODE = '22023'; END IF;
  IF v_mode = 'enforced' AND NOT public.pi_enforcement_available() THEN
    RAISE EXCEPTION 'enforced mode is not available (flag off, halted, or enforcement hooks not installed); record the decision in shadow mode' USING ERRCODE = '55000';
  END IF;

  SELECT id INTO v_exist FROM public.pi_content_analyses WHERE idempotency_key = v_key;
  IF FOUND THEN RETURN jsonb_build_object('duplicate', true, 'analysis_id', v_exist); END IF;

  IF v_cat IS NOT NULL THEN
    SELECT * INTO v_pol FROM public.pi_policies WHERE category::text = v_cat;
    IF FOUND THEN
      IF v_rec <> 'no_action' AND v_rec <> 'refer_to_human' THEN
        IF NOT v_pol.enabled THEN RAISE EXCEPTION 'the % policy is disabled; automation may not act on it', v_cat USING ERRCODE = '55000'; END IF;
        IF array_position(v_rank, v_rec) > array_position(v_rank, v_pol.max_auto_action) THEN
          RAISE EXCEPTION 'action % exceeds the maximum automatic action (%) of the % policy', v_rec, v_pol.max_auto_action, v_cat USING ERRCODE = '55000';
        END IF;
        IF v_pol.always_human_review AND v_rec IN ('hide_pending_review', 'warn', 'restrict_temporary') THEN
          RAISE EXCEPTION 'the % policy always requires human review; automation may only flag', v_cat USING ERRCODE = '55000';
        END IF;
      END IF;
      IF v_pol.always_human_review AND v_outcome IN ('uncertain', 'violation_likely') THEN v_human := true; END IF;
    END IF;
  END IF;
  IF v_source = 'user_report' THEN v_human := true; END IF;      -- a person asked for a review: a person must give it
  v_need_case := v_human OR v_rec <> 'no_action' OR v_source IN ('user_report', 'owner');
  IF v_rec IN ('hide_pending_review', 'restrict_temporary') THEN v_expires := now() + make_interval(hours => v_hours); END IF;

  BEGIN
    IF v_need_case THEN
      SELECT id INTO v_case FROM public.pi_moderation_cases
       WHERE subject_type = v_type AND subject_id = v_subject AND status IN ('open', 'awaiting_review')
       ORDER BY opened_at LIMIT 1 FOR UPDATE;
      IF FOUND THEN
        UPDATE public.pi_moderation_cases
           SET risk_score = greatest(coalesce(risk_score, 0), coalesce(v_risk, 0)), confidence = coalesce(v_conf, confidence),
               primary_category = coalesce(v_cat::public.pi_category, primary_category), priority = least(priority, v_prio),
               requires_human_review = requires_human_review OR v_human,
               status = CASE WHEN requires_human_review OR v_human THEN 'awaiting_review' ELSE status END
         WHERE id = v_case;
      ELSE
        INSERT INTO public.pi_moderation_cases (subject_type, subject_id, subject_user_id, source, report_id, status, priority, primary_category,
                                                risk_score, confidence, requires_human_review, idempotency_key)
        VALUES (v_type, v_subject, v_user, v_source, nullif(p ->> 'report_id', '')::uuid,
                CASE WHEN v_human THEN 'awaiting_review' ELSE 'open' END, v_prio, v_cat::public.pi_category, v_risk, v_conf, v_human, 'case:' || v_key)
        RETURNING id INTO v_case;
      END IF;
    END IF;

    INSERT INTO public.pi_content_analyses (case_id, subject_type, subject_id, subject_user_id, analysis_kind, content_hash, content_length, language,
        provider, model, model_version, policy_version, category_scores, top_category, risk_score, confidence, outcome, error, latency_ms, idempotency_key)
    VALUES (v_case, v_type, v_subject, v_user, coalesce(p ->> 'analysis_kind', 'text'), p ->> 'content_hash', nullif(p ->> 'content_length', '')::integer,
        nullif(p ->> 'language', ''), p ->> 'provider', nullif(p ->> 'model', ''), nullif(p ->> 'model_version', ''), v_pol.version,
        coalesce(p -> 'category_scores', '{}'::jsonb), v_cat::public.pi_category, v_risk, v_conf, v_outcome, nullif(p ->> 'error', ''),
        nullif(p ->> 'latency_ms', '')::integer, v_key)
    RETURNING id INTO v_analysis;

    IF v_rec IN ('flag', 'hide_pending_review', 'warn', 'restrict_temporary') THEN
      INSERT INTO public.pi_moderation_actions (case_id, target_user_id, subject_type, subject_id, action_type, actor_type, mode, reason_code,
          user_visible_reason, internal_note, policy_id, policy_version, analysis_id, confidence, expires_at, appealable, idempotency_key)
      VALUES (v_case, v_user, v_type, v_subject, v_rec, 'system', v_mode, v_cat::public.pi_category,
          nullif(p #>> '{decision,user_visible_reason}', ''), left(array_to_string(ARRAY(SELECT jsonb_array_elements_text(coalesce(p #> '{decision,reasons}', '[]'::jsonb))), '; '), 1000),
          v_pol.id, v_pol.version, v_analysis, v_conf, v_expires, true, 'act:' || v_key)
      RETURNING id INTO v_action;
    END IF;

    INSERT INTO public.pi_policy_decisions (decision_kind, subject_type, subject_id, subject_user_id, policy_category, policy_version, rule_set_key, rule_set_version,
        outcome, recommended_action, mode, risk_score, confidence, requires_human_review, reasons, inputs, case_id, analysis_id, idempotency_key)
    VALUES ('content_moderation', v_type, v_subject, v_user, v_cat::public.pi_category, v_pol.version, 'moderation_rules', v_rule_ver,
        coalesce(v_outcome, 'unknown'), v_rec, v_mode, v_risk, v_conf, v_human,
        ARRAY(SELECT jsonb_array_elements_text(coalesce(p #> '{decision,reasons}', '[]'::jsonb))),
        coalesce(p #> '{decision,inputs}', '{}'::jsonb), v_case, v_analysis, 'decision:' || v_key)
    RETURNING id INTO v_decision;

    PERFORM public.pi_write_audit(NULL, 'system', 'content_analysed', v_type, v_subject::text, NULL,
        jsonb_build_object('analysis_id', v_analysis, 'case_id', v_case, 'action_id', v_action, 'outcome', v_outcome, 'recommended_action', v_rec,
                           'mode', v_mode, 'risk_score', v_risk, 'confidence', v_conf, 'policy_version', v_pol.version, 'rule_set_version', v_rule_ver),
        left(array_to_string(ARRAY(SELECT jsonb_array_elements_text(coalesce(p #> '{decision,reasons}', '[]'::jsonb))), '; '), 500));
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_exist FROM public.pi_content_analyses WHERE idempotency_key = v_key;
    RETURN jsonb_build_object('duplicate', true, 'analysis_id', v_exist);
  END;
  RETURN jsonb_build_object('duplicate', false, 'analysis_id', v_analysis, 'case_id', v_case, 'action_id', v_action, 'decision_id', v_decision, 'mode', v_mode);
END $$;

-- ---------------------------------------------------------------- COMMIT: account risk assessment -> events / investigation / restrictions / alert
CREATE OR REPLACE FUNCTION public.pi_commit_account_assessment(p jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_key text := p ->> 'idempotency_key';
  v_user uuid := (p ->> 'user_id')::uuid;
  v_level text := p ->> 'risk_level';
  v_score numeric := (p ->> 'risk_score')::numeric;
  v_rec text := coalesce(p #>> '{decision,recommended_action}', 'no_action');
  v_mode text := coalesce(p #>> '{decision,mode}', 'shadow');
  v_rule_ver integer := coalesce((p ->> 'rule_set_version')::integer, 1);
  v_reasons text[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(p -> 'reason_codes', '[]'::jsonb)));
  v_assess uuid; v_inv uuid; v_prev_sev text; v_decision uuid; e jsonb; rs jsonb; v_hours integer; v_n integer := 0; v_events integer := 0; v_restr integer := 0;
  v_sev_rank text[] := ARRAY['low', 'medium', 'high', 'critical'];
BEGIN
  IF v_key IS NULL OR btrim(v_key) = '' THEN RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = '22023'; END IF;
  IF NOT public.pi_flag_on('account_risk_scoring') THEN RAISE EXCEPTION 'account risk scoring is switched off or automation is halted' USING ERRCODE = '55000'; END IF;
  IF v_rec NOT IN ('no_action', 'flag', 'restrict_temporary', 'refer_to_human') THEN RAISE EXCEPTION 'recommended action % is not allowed for automation', v_rec USING ERRCODE = '22023'; END IF;
  IF v_mode NOT IN ('shadow', 'enforced') THEN RAISE EXCEPTION 'invalid mode' USING ERRCODE = '22023'; END IF;
  IF v_mode = 'enforced' AND NOT public.pi_restrictions_enforceable() THEN
    RAISE EXCEPTION 'enforced restrictions are not available (flag off, halted, or hooks not installed); record in shadow mode' USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_user) THEN RETURN jsonb_build_object('skipped', true, 'reason', 'account no longer exists'); END IF;
  IF EXISTS (SELECT 1 FROM public.pi_policy_decisions WHERE idempotency_key = 'decision:' || v_key) THEN RETURN jsonb_build_object('duplicate', true); END IF;

  BEGIN
    UPDATE public.pi_account_risk_assessments SET is_current = false WHERE user_id = v_user AND is_current;
    INSERT INTO public.pi_account_risk_assessments (user_id, risk_score, risk_level, reason_codes, signals, explanation, model_version, expires_at)
    VALUES (v_user, v_score, v_level, v_reasons, coalesce(p -> 'signals', '[]'::jsonb), p ->> 'explanation', coalesce(p ->> 'model_version', 'bmn_rules'),
            now() + interval '7 days')
    RETURNING id INTO v_assess;

    FOR e IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'events', '[]'::jsonb)) LOOP
      INSERT INTO public.pi_security_events (user_id, event_type, severity, source, ip_hash, device_hash, details, dedupe_key)
      VALUES (v_user, e ->> 'event_type', e ->> 'severity', coalesce(e ->> 'source', 'bmn_rules'), nullif(e ->> 'ip_hash', ''), nullif(e ->> 'device_hash', ''),
              coalesce(e -> 'details', '{}'::jsonb), nullif(e ->> 'dedupe_key', ''))
      ON CONFLICT (dedupe_key) DO NOTHING;
      GET DIAGNOSTICS v_n = ROW_COUNT; v_events := v_events + v_n;
    END LOOP;

    IF coalesce((p ->> 'open_investigation')::boolean, false) AND v_level IN ('medium', 'high', 'critical') THEN
      SELECT id, severity INTO v_inv, v_prev_sev FROM public.pi_investigations WHERE user_id = v_user AND status <> 'closed' FOR UPDATE;
      IF NOT FOUND THEN
        INSERT INTO public.pi_investigations (user_id, assessment_id, severity, summary) VALUES (v_user, v_assess, v_level, left(p ->> 'explanation', 1000)) RETURNING id INTO v_inv;
        INSERT INTO public.pi_investigation_notes (investigation_id, author_type, note) VALUES (v_inv, 'system', 'Opened automatically: ' || left(p ->> 'explanation', 1000));
      ELSE
        IF array_position(v_sev_rank, v_level) > array_position(v_sev_rank, v_prev_sev) THEN
          UPDATE public.pi_investigations SET severity = v_level, assessment_id = v_assess WHERE id = v_inv;
          INSERT INTO public.pi_investigation_notes (investigation_id, author_type, note) VALUES (v_inv, 'system', 'Risk increased to ' || v_level || ': ' || left(p ->> 'explanation', 1000));
        ELSE
          UPDATE public.pi_investigations SET assessment_id = v_assess WHERE id = v_inv;
        END IF;
      END IF;
    END IF;

    FOR rs IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'restrictions', '[]'::jsonb)) LOOP
      v_hours := least(greatest(coalesce((rs ->> 'hours')::integer, 24), 1), 72);
      IF NOT EXISTS (SELECT 1 FROM public.pi_protective_restrictions WHERE user_id = v_user AND restriction_type = rs ->> 'restriction_type'
                       AND lifted_at IS NULL AND expires_at > now()) THEN
        INSERT INTO public.pi_protective_restrictions (user_id, restriction_type, reason_code, assessment_id, actor_type, mode, expires_at)
        VALUES (v_user, rs ->> 'restriction_type', coalesce(nullif(rs ->> 'reason_code', ''), 'unspecified'), v_assess, 'system', v_mode, now() + make_interval(hours => v_hours));
        v_restr := v_restr + 1;
      END IF;
    END LOOP;

    INSERT INTO public.pi_policy_decisions (decision_kind, subject_type, subject_id, subject_user_id, rule_set_key, rule_set_version, outcome, recommended_action, mode,
        risk_score, confidence, requires_human_review, reasons, inputs, idempotency_key)
    VALUES ('account_risk', 'account', v_user, v_user, 'account_risk_rules', v_rule_ver, 'risk_level:' || v_level, v_rec, v_mode, v_score,
        nullif(p ->> 'confidence', '')::numeric, coalesce((p #>> '{decision,requires_human_review}')::boolean, false), v_reasons,
        coalesce(p #> '{decision,inputs}', '{}'::jsonb), 'decision:' || v_key)
    RETURNING id INTO v_decision;

    IF v_level IN ('high', 'critical') THEN
      PERFORM public.pi_raise_alert('account_risk', CASE WHEN v_level = 'critical' THEN 'critical' ELSE 'high' END,
        'Account risk ' || v_level || ': ' || left(p ->> 'explanation', 300), jsonb_build_object('user_id', v_user, 'assessment_id', v_assess, 'reason_codes', v_reasons),
        'account_risk:' || v_user);
    ELSE
      PERFORM public.pi_clear_alert('account_risk:' || v_user);
    END IF;

    PERFORM public.pi_write_audit(NULL, 'system', 'account_assessed', 'account', v_user::text, NULL,
        jsonb_build_object('assessment_id', v_assess, 'risk_level', v_level, 'risk_score', v_score, 'mode', v_mode, 'investigation_id', v_inv,
                           'restrictions_created', v_restr, 'events_created', v_events, 'rule_set_version', v_rule_ver), left(p ->> 'explanation', 500));
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('duplicate', true);
  END;
  RETURN jsonb_build_object('duplicate', false, 'assessment_id', v_assess, 'investigation_id', v_inv, 'decision_id', v_decision,
                            'restrictions_created', v_restr, 'events_created', v_events, 'mode', v_mode);
END $$;

-- ---------------------------------------------------------------- COMMIT: verification evaluation (+ automatic approval when, and only when, every gate passes)
CREATE OR REPLACE FUNCTION public.pi_commit_verification_evaluation(p jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_req uuid := (p ->> 'request_id')::uuid;
  v_ver integer := coalesce((p ->> 'criteria_version')::integer, 1);
  v_checks jsonb := p -> 'checks';
  v_outcome text := p ->> 'outcome';
  v_imp numeric := nullif(p ->> 'impersonation_risk', '')::numeric;
  v_force boolean := coalesce((p ->> 'force')::boolean, false);
  q public.bmn_verification_requests; v_eval uuid; v_dup public.pi_verification_evaluations; v_gate text; v_owner uuid; v_n integer;
  v_decision text; v_reason text; v_mode text; v_rec text; v_dec_id uuid; v_failing text;
BEGIN
  IF NOT public.pi_flag_on('verification_evaluation') THEN RAISE EXCEPTION 'verification evaluation is switched off or automation is halted' USING ERRCODE = '55000'; END IF;
  SELECT * INTO q FROM public.bmn_verification_requests WHERE id = v_req FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'verification request not found' USING ERRCODE = 'P0002'; END IF;
  IF q.status <> 'pending' THEN RETURN jsonb_build_object('skipped', true, 'reason', 'request is no longer pending'); END IF;
  IF NOT v_force THEN
    SELECT * INTO v_dup FROM public.pi_verification_evaluations WHERE verification_request_id = v_req AND criteria_version = v_ver ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN RETURN jsonb_build_object('duplicate', true, 'evaluation_id', v_dup.id); END IF;
  END IF;

  INSERT INTO public.pi_verification_evaluations (verification_request_id, user_id, criteria_version, checks, outcome, impersonation_risk)
  VALUES (v_req, q.user_id, v_ver, v_checks, v_outcome, v_imp)       -- CHECK: 'eligible_for_auto_approval' is only storable when every check passed
  RETURNING id INTO v_eval;

  v_failing := coalesce((SELECT string_agg(c ->> 'check', ', ') FROM jsonb_array_elements(v_checks) c WHERE c ->> 'result' IS DISTINCT FROM 'pass'), '');
  v_gate := NULL;
  IF v_outcome = 'eligible_for_auto_approval' THEN
    IF NOT public.pi_flag_on('auto_verification') THEN v_gate := 'eligible, but automatic approval is switched off';
    ELSIF EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = q.user_id) THEN v_gate := 'account is already verified';
    ELSIF EXISTS (SELECT 1 FROM public.pi_verification_decisions WHERE user_id = q.user_id AND (fraud_related OR decision = 'revoked')) THEN v_gate := 'previous revocation or fraud record';
    ELSIF public.pi_violation_count(q.user_id, interval '180 days') > 0 THEN v_gate := 'recent enforced moderation action';
    ELSIF EXISTS (SELECT 1 FROM public.pi_account_risk_assessments WHERE user_id = q.user_id AND is_current AND risk_level IN ('high', 'critical') AND (expires_at IS NULL OR expires_at > now())) THEN v_gate := 'high account risk';
    ELSIF EXISTS (SELECT 1 FROM public.pi_protective_restrictions WHERE user_id = q.user_id AND lifted_at IS NULL AND expires_at > now()) THEN v_gate := 'active protective restriction';
    ELSIF EXISTS (SELECT 1 FROM public.pi_moderation_cases WHERE subject_user_id = q.user_id AND status IN ('open', 'awaiting_review')) THEN v_gate := 'open moderation case';
    ELSIF coalesce((SELECT status FROM public.bmn_user_moderation WHERE user_id = q.user_id AND (expires_at IS NULL OR expires_at > now())), 'active') <> 'active' THEN v_gate := 'account is suspended or banned';
    ELSE
      SELECT updated_by INTO v_owner FROM public.pi_feature_flags WHERE key = 'auto_verification';
      IF v_owner IS NULL OR NOT public.pi_is_owner(v_owner) THEN v_gate := 'no valid owner has delegated automatic verification';
      END IF;
    END IF;
    IF v_gate IS NULL THEN
      UPDATE public.bmn_verification_requests
         SET status = 'approved', reviewed_at = now(), reviewed_by = v_owner,
             review_note = 'Automatically approved by BMN Platform Intelligence (all ' || jsonb_array_length(v_checks) || ' required checks passed; criteria v' || v_ver ||
                           '; evaluation ' || v_eval || '). Automation acts under the delegated authority of the owner who enabled it.'
       WHERE id = v_req AND status = 'pending';
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n <> 1 THEN
        v_gate := 'the request changed while it was being evaluated';
      ELSE
        INSERT INTO public.bmn_verified_users (user_id, verified_at, verified_by, verification_note)
        VALUES (q.user_id, now(), v_owner, 'Automatically approved by BMN Platform Intelligence after all required checks passed (evaluation ' || v_eval || ').')
        ON CONFLICT (user_id) DO NOTHING;
      END IF;
    END IF;
  ELSE
    v_gate := CASE WHEN v_outcome = 'insufficient_evidence' THEN 'not enough reliable evidence' ELSE 'one or more checks did not pass' END;
  END IF;

  IF v_gate IS NULL THEN
    v_decision := 'approved'; v_mode := 'enforced'; v_rec := 'approve_verification';
    v_reason := 'All ' || jsonb_array_length(v_checks) || ' required checks passed (criteria v' || v_ver || ').';
  ELSE
    v_decision := 'referred_to_human';
    v_mode := CASE WHEN v_outcome = 'eligible_for_auto_approval' THEN 'shadow' ELSE 'enforced' END;
    v_rec := CASE WHEN v_outcome = 'eligible_for_auto_approval' THEN 'approve_verification' ELSE 'refer_to_human' END;
    v_reason := 'Needs human review: ' || v_gate || CASE WHEN v_failing <> '' THEN ' [' || v_failing || ']' ELSE '' END || '.';
  END IF;

  INSERT INTO public.pi_verification_decisions (user_id, verification_request_id, evaluation_id, decision, decided_by_type, reason)
  VALUES (q.user_id, v_req, v_eval, v_decision, 'system', v_reason);

  INSERT INTO public.pi_policy_decisions (decision_kind, subject_type, subject_id, subject_user_id, rule_set_key, rule_set_version, outcome, recommended_action, mode,
      risk_score, requires_human_review, reasons, inputs, idempotency_key)
  VALUES ('verification', 'verification_request', v_req, q.user_id, 'verification_criteria', v_ver, v_outcome, v_rec, v_mode, v_imp, v_decision <> 'approved',
      ARRAY[v_reason], jsonb_build_object('evaluation_id', v_eval, 'auto_verification_on', public.pi_flag_on('auto_verification')), 'decision:verify:' || v_eval)
  RETURNING id INTO v_dec_id;

  PERFORM public.pi_write_audit(NULL, 'system', CASE WHEN v_decision = 'approved' THEN 'verification_auto_approved' ELSE 'verification_referred' END,
      'verification_request', v_req::text, jsonb_build_object('status', 'pending'),
      jsonb_build_object('decision', v_decision, 'evaluation_id', v_eval, 'outcome', v_outcome, 'criteria_version', v_ver), v_reason);
  RETURN jsonb_build_object('duplicate', false, 'evaluation_id', v_eval, 'decision', v_decision, 'auto_approved', v_decision = 'approved', 'reason', v_reason);
END $$;

-- ---------------------------------------------------------------- provider health / circuit breaker
CREATE OR REPLACE FUNCTION public.pi_report_provider(p_provider text, p_ok boolean, p_error text DEFAULT NULL) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE h public.pi_provider_health;
BEGIN
  IF p_provider IS NULL OR btrim(p_provider) = '' THEN RAISE EXCEPTION 'provider required' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.pi_provider_health (provider) VALUES (p_provider) ON CONFLICT (provider) DO NOTHING;
  IF p_ok THEN
    UPDATE public.pi_provider_health SET state = 'healthy', consecutive_failures = 0, last_success_at = now(), circuit_open_until = NULL WHERE provider = p_provider
      RETURNING * INTO h;
    PERFORM public.pi_clear_alert('provider_down:' || p_provider);
  ELSE
    UPDATE public.pi_provider_health
       SET consecutive_failures = consecutive_failures + 1, last_failure_at = now(), last_error = left(coalesce(nullif(btrim(p_error), ''), 'unspecified error'), 500),
           state = CASE WHEN consecutive_failures + 1 >= 5 THEN 'down' ELSE 'degraded' END,
           circuit_open_until = CASE WHEN consecutive_failures + 1 >= 5 THEN now() + interval '5 minutes' ELSE circuit_open_until END
     WHERE provider = p_provider RETURNING * INTO h;
    IF h.state = 'down' THEN
      PERFORM public.pi_raise_alert('provider_down', 'medium', 'AI provider ' || p_provider || ' is failing; its circuit is open for 5 minutes. Rules-only analysis continues.',
        jsonb_build_object('provider', p_provider, 'failures', h.consecutive_failures, 'last_error', h.last_error), 'provider_down:' || p_provider);
    END IF;
  END IF;
  RETURN h.state;
END $$;

CREATE OR REPLACE FUNCTION public.pi_provider_available(p_provider text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.pi_flag_on('ai_providers')
     AND coalesce((SELECT state <> 'disabled' AND (circuit_open_until IS NULL OR circuit_open_until <= now()) FROM public.pi_provider_health WHERE provider = p_provider), true);
$$;

-- =====================================================================================  HUMAN DECISIONS (owner only; owner status is re-checked in the database)
-- Resolve a moderation case. The only content action available here is removal of a POST, applied exactly like the
-- existing bmn_remove_post() (status -> 'removed' + a row in moderation_actions), but atomically with the PI records.
CREATE OR REPLACE FUNCTION public.pi_owner_resolve_case(p_actor uuid, p_case_id uuid, p_resolution text, p_action_type text,
    p_user_visible_reason text, p_note text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.pi_moderation_cases; v_action uuid; v_res text; v_n integer; v_reversed integer := 0; a record; v_pv integer;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_resolution NOT IN ('no_violation', 'violation_confirmed', 'insufficient_information', 'duplicate') THEN RAISE EXCEPTION 'invalid resolution' USING ERRCODE = '22023'; END IF;
  IF p_action_type NOT IN ('no_action', 'warn', 'remove_content') THEN RAISE EXCEPTION 'invalid action type' USING ERRCODE = '22023'; END IF;
  IF p_note IS NULL OR btrim(p_note) = '' THEN RAISE EXCEPTION 'a decision note is required' USING ERRCODE = '22023'; END IF;
  IF p_resolution <> 'violation_confirmed' AND p_action_type <> 'no_action' THEN RAISE EXCEPTION 'an action can only be taken when the violation is confirmed' USING ERRCODE = '22023'; END IF;
  IF p_action_type IN ('warn', 'remove_content') AND (p_user_visible_reason IS NULL OR btrim(p_user_visible_reason) = '') THEN
    RAISE EXCEPTION 'a reason the user can be shown is required for this action' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM public.pi_moderation_cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002'; END IF;
  IF c.status IN ('resolved', 'dismissed') THEN RAISE EXCEPTION 'case already resolved' USING ERRCODE = 'P0001'; END IF;
  SELECT version INTO v_pv FROM public.pi_policies WHERE category = c.primary_category;

  IF p_action_type = 'remove_content' THEN
    IF c.subject_type <> 'post' THEN RAISE EXCEPTION 'content removal is supported for posts only in this version' USING ERRCODE = '22023'; END IF;
    PERFORM 1 FROM public.posts WHERE id = c.subject_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'post not found' USING ERRCODE = 'P0002'; END IF;
    UPDATE public.posts SET status = 'removed', updated_at = now() WHERE id = c.subject_id AND status <> 'removed';
    INSERT INTO public.moderation_actions (admin_id, target_user_id, post_id, action, reason)
    VALUES (p_actor, c.subject_user_id, c.subject_id, 'post_removed', coalesce(nullif(btrim(p_user_visible_reason), ''), 'Removed by BMN owner'));
  END IF;

  IF p_action_type <> 'no_action' THEN
    INSERT INTO public.pi_moderation_actions (case_id, target_user_id, subject_type, subject_id, action_type, actor_type, actor_id, mode, reason_code,
        user_visible_reason, internal_note, policy_version, confidence, appealable, idempotency_key)
    VALUES (p_case_id, c.subject_user_id, c.subject_type, c.subject_id, p_action_type, 'owner', p_actor, 'enforced', c.primary_category,
        btrim(p_user_visible_reason), p_note, v_pv, c.confidence, true, 'human:' || p_case_id || ':' || p_action_type)
    RETURNING id INTO v_action;
  END IF;

  -- "No violation": undo any automated hold that is still standing for this case, and let the worker lift its platform effect.
  IF p_resolution = 'no_violation' THEN
    FOR a IN SELECT id FROM public.pi_moderation_actions
              WHERE case_id = p_case_id AND actor_type = 'system' AND reversed_at IS NULL AND action_type IN ('hide_pending_review', 'restrict_temporary', 'warn') LOOP
      UPDATE public.pi_moderation_actions SET reversed_at = now(), reversed_by = p_actor, reversal_reason = 'cleared by owner review: no violation' WHERE id = a.id;
      PERFORM public.pi_enqueue_job('reverse_action', jsonb_build_object('action_id', a.id, 'case_id', p_case_id), 2::smallint, 'reverse_action:' || a.id);
      v_reversed := v_reversed + 1;
    END LOOP;
  END IF;

  v_res := CASE p_resolution
             WHEN 'no_violation' THEN 'no_violation'
             WHEN 'violation_confirmed' THEN CASE p_action_type WHEN 'remove_content' THEN 'content_removed' WHEN 'warn' THEN 'user_actioned' ELSE 'violation_confirmed' END
             ELSE p_resolution END;
  UPDATE public.pi_moderation_cases
     SET status = CASE WHEN p_resolution = 'no_violation' THEN 'dismissed' ELSE 'resolved' END, resolution = v_res, resolved_at = now(),
         assigned_to = p_actor, requires_human_review = false
   WHERE id = p_case_id;
  PERFORM public.pi_write_audit(p_actor, 'owner', 'case_resolved', 'moderation_case', p_case_id::text,
      jsonb_build_object('status', c.status), jsonb_build_object('resolution', v_res, 'action_type', p_action_type, 'action_id', v_action, 'automated_holds_reversed', v_reversed), p_note);
  RETURN jsonb_build_object('case_id', p_case_id, 'resolution', v_res, 'action_id', v_action, 'automated_holds_reversed', v_reversed);
END $$;

-- Owner reverses any earlier action (also used by the appeals flow of migration 001 through the worker).
CREATE OR REPLACE FUNCTION public.pi_owner_reverse_action(p_actor uuid, p_action_id uuid, p_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.pi_moderation_actions;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO a FROM public.pi_moderation_actions WHERE id = p_action_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'action not found' USING ERRCODE = 'P0002'; END IF;
  IF a.reversed_at IS NOT NULL THEN RAISE EXCEPTION 'action already reversed' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.pi_moderation_actions SET reversed_at = now(), reversed_by = p_actor, reversal_reason = left(p_reason, 500) WHERE id = p_action_id;
  PERFORM public.pi_enqueue_job('reverse_action', jsonb_build_object('action_id', p_action_id), 2::smallint, 'reverse_action:' || p_action_id);
  PERFORM public.pi_write_audit(p_actor, 'owner', 'action_reversed', 'moderation_action', p_action_id::text,
      jsonb_build_object('action_type', a.action_type), jsonb_build_object('reversed', true), p_reason);
  RETURN jsonb_build_object('action_id', p_action_id, 'queued_reversal', true);
END $$;

-- Applies the platform effect of a reversal (idempotent). Only content removal has a platform effect in this version.
CREATE OR REPLACE FUNCTION public.pi_apply_reversal(p_action_id uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.pi_moderation_actions; v_n integer;
BEGIN
  SELECT * INTO a FROM public.pi_moderation_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('applied', false, 'detail', 'action not found'); END IF;
  IF a.reversed_at IS NULL THEN RETURN jsonb_build_object('applied', false, 'detail', 'action is not reversed'); END IF;
  IF a.action_type <> 'remove_content' OR a.subject_type <> 'post' THEN
    RETURN jsonb_build_object('applied', false, 'detail', 'nothing to undo on the platform for ' || a.action_type);
  END IF;
  IF EXISTS (SELECT 1 FROM public.pi_moderation_actions WHERE subject_type = 'post' AND subject_id = a.subject_id AND action_type = 'remove_content'
               AND reversed_at IS NULL AND id <> a.id AND mode = 'enforced') THEN
    RETURN jsonb_build_object('applied', false, 'detail', 'another removal of this post still stands');
  END IF;
  UPDATE public.posts SET status = 'published', updated_at = now() WHERE id = a.subject_id AND status = 'removed';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 1 THEN
    INSERT INTO public.moderation_actions (admin_id, target_user_id, post_id, action, reason)
    VALUES (a.reversed_by, a.target_user_id, a.subject_id, 'post_restored', 'Restored after review: ' || coalesce(left(a.reversal_reason, 300), 'action reversed'));
  END IF;
  PERFORM public.pi_write_audit(NULL, 'system', 'reversal_applied', 'moderation_action', p_action_id::text, NULL, jsonb_build_object('post_restored', v_n = 1), a.reversal_reason);
  RETURN jsonb_build_object('applied', v_n = 1, 'detail', CASE WHEN v_n = 1 THEN 'post restored' ELSE 'post was not removed' END);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_decide_verification(p_actor uuid, p_request_id uuid, p_decision text, p_note text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE q public.bmn_verification_requests; v_eval uuid;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_decision NOT IN ('approved', 'rejected') THEN RAISE EXCEPTION 'decision must be approved or rejected' USING ERRCODE = '22023'; END IF;
  IF p_note IS NULL OR btrim(p_note) = '' THEN RAISE EXCEPTION 'a review note is required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO q FROM public.bmn_verification_requests WHERE id = p_request_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pending verification request not found' USING ERRCODE = 'P0002'; END IF;
  UPDATE public.bmn_verification_requests SET status = p_decision, reviewed_at = now(), reviewed_by = p_actor, review_note = p_note WHERE id = p_request_id;
  IF p_decision = 'approved' THEN
    INSERT INTO public.bmn_verified_users (user_id, verified_at, verified_by, verification_note) VALUES (q.user_id, now(), p_actor, p_note)
    ON CONFLICT (user_id) DO UPDATE SET verified_at = EXCLUDED.verified_at, verified_by = EXCLUDED.verified_by, verification_note = EXCLUDED.verification_note;
  END IF;
  SELECT id INTO v_eval FROM public.pi_verification_evaluations WHERE verification_request_id = p_request_id ORDER BY created_at DESC LIMIT 1;
  INSERT INTO public.pi_verification_decisions (user_id, verification_request_id, evaluation_id, decision, decided_by_type, decided_by, reason)
  VALUES (q.user_id, p_request_id, v_eval, p_decision, 'owner', p_actor, left(p_note, 1000));
  PERFORM public.pi_write_audit(p_actor, 'owner', 'verification_' || p_decision, 'verification_request', p_request_id::text,
      jsonb_build_object('status', 'pending'), jsonb_build_object('status', p_decision, 'evaluation_id', v_eval), p_note);
  RETURN jsonb_build_object('request_id', p_request_id, 'decision', p_decision);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_update_investigation(p_actor uuid, p_id uuid, p_status text, p_note text, p_resolution text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.pi_investigations;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_status NOT IN ('open', 'in_review', 'closed') THEN RAISE EXCEPTION 'invalid status' USING ERRCODE = '22023'; END IF;
  IF p_note IS NULL OR btrim(p_note) = '' THEN RAISE EXCEPTION 'a note is required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO i FROM public.pi_investigations WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'investigation not found' USING ERRCODE = 'P0002'; END IF;
  IF i.status = 'closed' THEN RAISE EXCEPTION 'investigation is already closed' USING ERRCODE = 'P0001'; END IF;
  IF p_status = 'closed' AND p_resolution IS NULL THEN RAISE EXCEPTION 'a resolution is required to close an investigation' USING ERRCODE = '22023'; END IF;
  UPDATE public.pi_investigations
     SET status = p_status, assigned_to = coalesce(assigned_to, p_actor),
         resolution = CASE WHEN p_status = 'closed' THEN p_resolution ELSE NULL END,
         closed_at = CASE WHEN p_status = 'closed' THEN now() END, closed_by = CASE WHEN p_status = 'closed' THEN p_actor END
   WHERE id = p_id;
  INSERT INTO public.pi_investigation_notes (investigation_id, author_id, author_type, note) VALUES (p_id, p_actor, 'owner', left(p_note, 2000));
  PERFORM public.pi_write_audit(p_actor, 'owner', 'investigation_' || p_status, 'investigation', p_id::text,
      jsonb_build_object('status', i.status), jsonb_build_object('status', p_status, 'resolution', p_resolution), p_note);
  RETURN jsonb_build_object('id', p_id, 'status', p_status);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_lift_restriction(p_actor uuid, p_id uuid, p_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.pi_protective_restrictions;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO r FROM public.pi_protective_restrictions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'restriction not found' USING ERRCODE = 'P0002'; END IF;
  IF r.lifted_at IS NOT NULL THEN RAISE EXCEPTION 'restriction already lifted' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.pi_protective_restrictions SET lifted_at = now(), lifted_by = p_actor, lift_reason = left(p_reason, 500) WHERE id = p_id;
  PERFORM public.pi_write_audit(p_actor, 'owner', 'restriction_lifted', 'restriction', p_id::text, jsonb_build_object('type', r.restriction_type, 'mode', r.mode), NULL, p_reason);
  RETURN jsonb_build_object('id', p_id, 'lifted', true);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_ack_event(p_actor uuid, p_event_id bigint) RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n integer;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  UPDATE public.pi_security_events SET acknowledged_at = now(), acknowledged_by = p_actor WHERE id = p_event_id AND acknowledged_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 1 THEN PERFORM public.pi_write_audit(p_actor, 'owner', 'security_event_acknowledged', 'security_event', p_event_id::text, NULL, NULL, NULL); END IF;
  RETURN n = 1;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_ack_alert(p_actor uuid, p_alert_id bigint) RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n integer;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  UPDATE public.pi_system_alerts SET acknowledged_at = now(), acknowledged_by = p_actor WHERE id = p_alert_id AND acknowledged_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 1 THEN PERFORM public.pi_write_audit(p_actor, 'owner', 'system_alert_acknowledged', 'system_alert', p_alert_id::text, NULL, NULL, NULL); END IF;
  RETURN n = 1;
END $$;

-- Owner can ask for a verification re-evaluation or an immediate health check (nothing else can be enqueued from the console).
CREATE OR REPLACE FUNCTION public.pi_owner_enqueue(p_actor uuid, p_type text, p_payload jsonb) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid; v_key text;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_type = 'evaluate_verification' THEN
    IF NOT EXISTS (SELECT 1 FROM public.bmn_verification_requests WHERE id = (p_payload ->> 'request_id')::uuid AND status = 'pending') THEN
      RAISE EXCEPTION 'pending verification request not found' USING ERRCODE = 'P0002';
    END IF;
    p_payload := jsonb_build_object('request_id', p_payload ->> 'request_id', 'force', true);
  ELSIF p_type = 'provider_healthcheck' THEN
    p_payload := '{}'::jsonb;
  ELSE
    RAISE EXCEPTION 'this job type cannot be queued from the console' USING ERRCODE = '22023';
  END IF;
  v_key := 'owner:' || p_type || ':' || coalesce(p_payload ->> 'request_id', '') || ':' || (extract(epoch FROM now()))::bigint / 30;
  v := public.pi_enqueue_job(p_type, p_payload, 3::smallint, v_key);
  PERFORM public.pi_write_audit(p_actor, 'owner', 'job_requested', 'job', coalesce(v::text, 'duplicate'), NULL, jsonb_build_object('type', p_type), NULL);
  RETURN v;
END $$;

-- =====================================================================================  EXPIRY, HEALTH, MAINTENANCE
CREATE OR REPLACE FUNCTION public.pi_expire_automated() RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_restr integer; v_holds integer := 0; a record; v_cases integer := 0;
BEGIN
  UPDATE public.pi_protective_restrictions SET lifted_at = now(), lift_reason = 'expired automatically' WHERE lifted_at IS NULL AND expires_at <= now();
  GET DIAGNOSTICS v_restr = ROW_COUNT;
  FOR a IN SELECT id, case_id FROM public.pi_moderation_actions
            WHERE actor_type = 'system' AND action_type IN ('hide_pending_review', 'restrict_temporary') AND reversed_at IS NULL AND expires_at <= now() LOOP
    UPDATE public.pi_moderation_actions SET reversed_at = now(), reversal_reason = 'expired automatically (no human decision before expiry)' WHERE id = a.id;
    PERFORM public.pi_enqueue_job('reverse_action', jsonb_build_object('action_id', a.id, 'expired', true), 2::smallint, 'reverse_action:' || a.id);
    v_holds := v_holds + 1;
    -- the hold ended but the human decision is still outstanding: make it the most urgent item in the queue
    IF a.case_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.pi_moderation_cases WHERE id = a.case_id AND status IN ('open', 'awaiting_review')) THEN
      UPDATE public.pi_moderation_cases SET priority = 1, status = 'awaiting_review', requires_human_review = true WHERE id = a.case_id;
      PERFORM public.pi_raise_alert('hold_expired_unreviewed', 'medium', 'An automated hold expired before a human reviewed the case.',
                                    jsonb_build_object('case_id', a.case_id, 'action_id', a.id), 'hold_expired:' || a.case_id);
      v_cases := v_cases + 1;
    END IF;
  END LOOP;
  IF v_restr > 0 OR v_holds > 0 THEN
    PERFORM public.pi_write_audit(NULL, 'system', 'automated_holds_expired', 'system', 'expiry', NULL,
        jsonb_build_object('restrictions_lifted', v_restr, 'holds_ended', v_holds, 'cases_escalated', v_cases), NULL);
  END IF;
  RETURN jsonb_build_object('restrictions_lifted', v_restr, 'holds_ended', v_holds, 'cases_escalated', v_cases);
END $$;

CREATE OR REPLACE FUNCTION public.pi_worker_heartbeat(p_worker text, p_version text, p_succeeded bigint DEFAULT 0, p_failed bigint DEFAULT 0,
                                                      p_last_error text DEFAULT NULL, p_meta jsonb DEFAULT '{}'::jsonb) RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.pi_worker_heartbeats (worker_id, version, jobs_succeeded, jobs_failed, last_error, meta)
  VALUES (p_worker, p_version, greatest(p_succeeded, 0), greatest(p_failed, 0), left(p_last_error, 500), coalesce(p_meta, '{}'::jsonb))
  ON CONFLICT (worker_id) DO UPDATE SET last_seen_at = now(), version = EXCLUDED.version, jobs_succeeded = EXCLUDED.jobs_succeeded,
      jobs_failed = EXCLUDED.jobs_failed, last_error = EXCLUDED.last_error, meta = EXCLUDED.meta;
$$;

-- Computes system health and raises / clears alerts. Safe to call often.
CREATE OR REPLACE FUNCTION public.pi_system_health() RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_workers integer; v_dead integer; v_backlog_s numeric; v_stuck integer; v_review_old integer; v_auto boolean; v_down text;
BEGIN
  SELECT count(*) INTO v_workers FROM public.pi_worker_heartbeats WHERE last_seen_at > now() - interval '3 minutes';
  SELECT count(*) INTO v_dead FROM public.pi_jobs WHERE status = 'dead' AND finished_at > now() - interval '24 hours';
  SELECT extract(epoch FROM (now() - min(run_after))) INTO v_backlog_s FROM public.pi_jobs WHERE status = 'queued' AND run_after <= now();
  SELECT count(*) INTO v_stuck FROM public.pi_jobs WHERE status = 'running' AND lease_expires_at < now();
  SELECT count(*) INTO v_review_old FROM public.pi_moderation_cases WHERE status = 'awaiting_review' AND opened_at < now() - interval '48 hours';
  SELECT coalesce(bool_or(enabled), false) INTO v_auto FROM public.pi_feature_flags
   WHERE key IN ('moderation_analysis', 'account_risk_scoring', 'verification_evaluation') ;
  IF v_auto AND v_workers = 0 THEN
    PERFORM public.pi_raise_alert('worker_offline', 'high', 'Automation is switched on but no worker has reported in the last 3 minutes.', '{}'::jsonb, 'worker_offline');
  ELSE PERFORM public.pi_clear_alert('worker_offline'); END IF;
  IF v_dead > 0 THEN
    PERFORM public.pi_raise_alert('jobs_dead', 'medium', v_dead || ' background job(s) failed permanently in the last 24 hours.', jsonb_build_object('dead_jobs_24h', v_dead), 'jobs_dead');
  ELSE PERFORM public.pi_clear_alert('jobs_dead'); END IF;
  IF coalesce(v_backlog_s, 0) > 600 THEN
    PERFORM public.pi_raise_alert('queue_backlog', 'medium', 'The oldest waiting job is ' || round(v_backlog_s / 60) || ' minutes old.', jsonb_build_object('oldest_seconds', round(v_backlog_s)), 'queue_backlog');
  ELSE PERFORM public.pi_clear_alert('queue_backlog'); END IF;
  IF v_review_old > 0 THEN
    PERFORM public.pi_raise_alert('review_backlog', 'low', v_review_old || ' case(s) have waited more than 48 hours for human review.', jsonb_build_object('cases', v_review_old), 'review_backlog');
  ELSE PERFORM public.pi_clear_alert('review_backlog'); END IF;
  RETURN jsonb_build_object('workers_active', v_workers, 'dead_jobs_24h', v_dead, 'oldest_queued_seconds', coalesce(round(v_backlog_s), 0),
                            'expired_leases', v_stuck, 'cases_waiting_over_48h', v_review_old, 'automation_enabled', v_auto);
END $$;

-- Privacy / hygiene: removes only low-value operational data. Never touches audit, decisions, cases, actions or evaluations.
CREATE OR REPLACE FUNCTION public.pi_purge_retention(p_observations interval DEFAULT interval '90 days', p_jobs interval DEFAULT interval '30 days') RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a integer; b integer; c integer; d integer;
BEGIN
  IF p_observations < interval '7 days' OR p_jobs < interval '1 day' THEN RAISE EXCEPTION 'retention windows are too short' USING ERRCODE = '22023'; END IF;
  DELETE FROM public.pi_session_observations WHERE last_seen_at < now() - p_observations;       GET DIAGNOSTICS a = ROW_COUNT;
  DELETE FROM public.pi_jobs WHERE status IN ('succeeded', 'cancelled', 'dead') AND finished_at < now() - p_jobs; GET DIAGNOSTICS b = ROW_COUNT;
  DELETE FROM public.pi_system_alerts WHERE resolved_at < now() - interval '90 days';            GET DIAGNOSTICS c = ROW_COUNT;
  DELETE FROM public.pi_worker_heartbeats WHERE last_seen_at < now() - interval '7 days';        GET DIAGNOSTICS d = ROW_COUNT;
  RETURN jsonb_build_object('session_observations', a, 'jobs', b, 'alerts', c, 'heartbeats', d);
END $$;

-- =====================================================================================  OWNER READ MODELS (jsonb; nothing private is stored in them)
CREATE OR REPLACE FUNCTION public.pi_subject_preview(p_type text, p_id uuid) RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE p_type
    WHEN 'post'    THEN (SELECT left(concat_ws(' · ', nullif(nullif(btrim(title), ''), 'Community post'), caption, content), 400) FROM public.posts WHERE id = p_id)
    WHEN 'comment' THEN (SELECT left(coalesce(content, body), 400) FROM public.comments WHERE id = p_id)
    WHEN 'profile' THEN (SELECT left(concat_ws(' · ', '@' || username, display_name, bio), 400) FROM public.profiles WHERE id = p_id)
    ELSE NULL END;     -- private messages are deliberately never previewed
$$;

CREATE OR REPLACE FUNCTION public.pi_owner_overview(p_actor uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  RETURN jsonb_build_object(
    'halted', public.pi_automation_halted(),
    'flags', (SELECT coalesce(jsonb_object_agg(key, enabled), '{}'::jsonb) FROM public.pi_feature_flags),
    'cases', jsonb_build_object(
      'awaiting_review', (SELECT count(*) FROM public.pi_moderation_cases WHERE status = 'awaiting_review'),
      'open', (SELECT count(*) FROM public.pi_moderation_cases WHERE status = 'open'),
      'urgent', (SELECT count(*) FROM public.pi_moderation_cases WHERE status IN ('open', 'awaiting_review') AND priority = 1),
      'oldest_waiting_hours', (SELECT round((extract(epoch FROM (now() - min(opened_at))) / 3600)::numeric, 1) FROM public.pi_moderation_cases WHERE status = 'awaiting_review')),
    'accounts', jsonb_build_object(
      'high_risk', (SELECT count(*) FROM public.pi_account_risk_assessments WHERE is_current AND risk_level = 'high' AND (expires_at IS NULL OR expires_at > now())),
      'critical_risk', (SELECT count(*) FROM public.pi_account_risk_assessments WHERE is_current AND risk_level = 'critical' AND (expires_at IS NULL OR expires_at > now())),
      'open_investigations', (SELECT count(*) FROM public.pi_investigations WHERE status <> 'closed'),
      'unacknowledged_events', (SELECT count(*) FROM public.pi_security_events WHERE acknowledged_at IS NULL AND severity IN ('high', 'critical')),
      'active_restrictions', (SELECT count(*) FROM public.pi_protective_restrictions WHERE lifted_at IS NULL AND expires_at > now())),
    'verification', jsonb_build_object(
      'pending', (SELECT count(*) FROM public.bmn_verification_requests WHERE status = 'pending'),
      'evaluated_pending', (SELECT count(*) FROM public.bmn_verification_requests q WHERE q.status = 'pending'
                              AND EXISTS (SELECT 1 FROM public.pi_verification_evaluations e WHERE e.verification_request_id = q.id)),
      'auto_approved_7d', (SELECT count(*) FROM public.pi_verification_decisions WHERE decision = 'approved' AND decided_by_type = 'system' AND created_at > now() - interval '7 days')),
    'appeals', jsonb_build_object('pending', (SELECT count(*) FROM public.pi_appeals WHERE status IN ('pending', 'under_review'))),
    'alerts_open', (SELECT count(*) FROM public.pi_system_alerts WHERE resolved_at IS NULL),
    'jobs', jsonb_build_object(
      'queued', (SELECT count(*) FROM public.pi_jobs WHERE status = 'queued'),
      'running', (SELECT count(*) FROM public.pi_jobs WHERE status = 'running'),
      'dead', (SELECT count(*) FROM public.pi_jobs WHERE status = 'dead'),
      'succeeded_24h', (SELECT count(*) FROM public.pi_jobs WHERE status = 'succeeded' AND finished_at > now() - interval '24 hours')),
    'workers', (SELECT coalesce(jsonb_agg(jsonb_build_object('worker_id', worker_id, 'version', version, 'seen_seconds_ago', round(extract(epoch FROM (now() - last_seen_at))),
                   'jobs_succeeded', jobs_succeeded, 'jobs_failed', jobs_failed, 'last_error', last_error) ORDER BY last_seen_at DESC), '[]'::jsonb) FROM public.pi_worker_heartbeats),
    'providers', (SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY provider), '[]'::jsonb) FROM public.pi_provider_health h),
    'decisions', jsonb_build_object(
      'shadow_7d', (SELECT count(*) FROM public.pi_policy_decisions WHERE mode = 'shadow' AND decided_at > now() - interval '7 days'),
      'enforced_7d', (SELECT count(*) FROM public.pi_policy_decisions WHERE mode = 'enforced' AND decided_at > now() - interval '7 days'),
      'last_decision_at', (SELECT max(decided_at) FROM public.pi_policy_decisions)),
    'enforcement_available', public.pi_enforcement_available());
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_cases(p_actor uuid, p_status text DEFAULT 'awaiting_review', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_status NOT IN ('open', 'awaiting_review', 'resolved', 'dismissed', 'all') THEN RAISE EXCEPTION 'invalid status' USING ERRCODE = '22023'; END IF;
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200); p_offset := greatest(coalesce(p_offset, 0), 0);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.priority, t.opened_at), '[]'::jsonb) INTO r FROM (
    SELECT c.priority, c.opened_at,
           to_jsonb(c) - 'idempotency_key' || jsonb_build_object(
             'subject_username', (SELECT username FROM public.profiles WHERE id = c.subject_user_id),
             'preview', public.pi_subject_preview(c.subject_type, c.subject_id),
             'latest_analysis', (SELECT to_jsonb(a) - 'idempotency_key' - 'subject_user_id' FROM public.pi_content_analyses a WHERE a.case_id = c.id ORDER BY a.analysed_at DESC LIMIT 1),
             'actions', coalesce((SELECT jsonb_agg(to_jsonb(x) - 'idempotency_key' ORDER BY x.created_at DESC) FROM public.pi_moderation_actions x WHERE x.case_id = c.id), '[]'::jsonb)) AS item
      FROM public.pi_moderation_cases c WHERE p_status = 'all' OR c.status = p_status
     ORDER BY c.priority, c.opened_at LIMIT p_limit OFFSET p_offset) t;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_case_detail(p_actor uuid, p_case_id uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c public.pi_moderation_cases;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  SELECT * INTO c FROM public.pi_moderation_cases WHERE id = p_case_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002'; END IF;
  RETURN jsonb_build_object('case', to_jsonb(c) - 'idempotency_key',
    'preview', public.pi_subject_preview(c.subject_type, c.subject_id),
    'subject_username', (SELECT username FROM public.profiles WHERE id = c.subject_user_id),
    'analyses', (SELECT coalesce(jsonb_agg(to_jsonb(a) - 'idempotency_key' ORDER BY a.analysed_at DESC), '[]'::jsonb) FROM public.pi_content_analyses a WHERE a.case_id = c.id),
    'actions', (SELECT coalesce(jsonb_agg(to_jsonb(x) - 'idempotency_key' ORDER BY x.created_at DESC), '[]'::jsonb) FROM public.pi_moderation_actions x WHERE x.case_id = c.id),
    'decisions', (SELECT coalesce(jsonb_agg(to_jsonb(d) - 'idempotency_key' ORDER BY d.decided_at DESC), '[]'::jsonb) FROM public.pi_policy_decisions d WHERE d.case_id = c.id),
    'violations_90d', CASE WHEN c.subject_user_id IS NULL THEN 0 ELSE public.pi_violation_count(c.subject_user_id, interval '90 days') END);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_accounts(p_actor uuid, p_min_level text DEFAULT 'medium', p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; v_min integer;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  v_min := array_position(ARRAY['low', 'medium', 'high', 'critical'], p_min_level);
  IF v_min IS NULL THEN RAISE EXCEPTION 'invalid level' USING ERRCODE = '22023'; END IF;
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.risk_score DESC), '[]'::jsonb) INTO r FROM (
    SELECT a.risk_score, to_jsonb(a) || jsonb_build_object('username', p.username, 'display_name', p.display_name,
             'investigation_id', (SELECT id FROM public.pi_investigations i WHERE i.user_id = a.user_id AND i.status <> 'closed'),
             'active_restrictions', (SELECT count(*) FROM public.pi_protective_restrictions x WHERE x.user_id = a.user_id AND x.lifted_at IS NULL AND x.expires_at > now())) AS item
      FROM public.pi_account_risk_assessments a LEFT JOIN public.profiles p ON p.id = a.user_id
     WHERE a.is_current AND array_position(ARRAY['low', 'medium', 'high', 'critical'], a.risk_level) >= v_min AND (a.expires_at IS NULL OR a.expires_at > now())
     ORDER BY a.risk_score DESC LIMIT p_limit) t;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_investigations(p_actor uuid, p_status text DEFAULT 'open', p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  IF p_status NOT IN ('open', 'in_review', 'closed', 'active', 'all') THEN RAISE EXCEPTION 'invalid status' USING ERRCODE = '22023'; END IF;
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.sev, t.opened_at), '[]'::jsonb) INTO r FROM (
    SELECT array_position(ARRAY['critical', 'high', 'medium', 'low'], i.severity) AS sev, i.opened_at,
           to_jsonb(i) || jsonb_build_object('username', p.username, 'display_name', p.display_name) AS item
      FROM public.pi_investigations i LEFT JOIN public.profiles p ON p.id = i.user_id
     WHERE (p_status = 'all') OR (p_status = 'active' AND i.status <> 'closed') OR i.status = p_status
     ORDER BY 1, i.opened_at LIMIT p_limit) t;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_investigation_detail(p_actor uuid, p_id uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.pi_investigations;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  SELECT * INTO i FROM public.pi_investigations WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'investigation not found' USING ERRCODE = 'P0002'; END IF;
  RETURN jsonb_build_object('investigation', to_jsonb(i),
    'profile', (SELECT jsonb_build_object('username', username, 'display_name', display_name, 'created_at', created_at) FROM public.profiles WHERE id = i.user_id),
    'assessment', (SELECT to_jsonb(a) FROM public.pi_account_risk_assessments a WHERE a.id = i.assessment_id),
    'notes', (SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.created_at), '[]'::jsonb) FROM public.pi_investigation_notes n WHERE n.investigation_id = i.id),
    'events', (SELECT coalesce(jsonb_agg(to_jsonb(e) - 'dedupe_key' ORDER BY e.occurred_at DESC), '[]'::jsonb) FROM (SELECT * FROM public.pi_security_events WHERE user_id = i.user_id ORDER BY occurred_at DESC LIMIT 30) e),
    'restrictions', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb) FROM (SELECT * FROM public.pi_protective_restrictions WHERE user_id = i.user_id ORDER BY created_at DESC LIMIT 20) r),
    'activity', public.pi_user_activity_summary(i.user_id));
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_events(p_actor uuid, p_only_open boolean DEFAULT true, p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.occurred_at DESC), '[]'::jsonb) INTO r FROM (
    SELECT e.occurred_at, to_jsonb(e) - 'dedupe_key' || jsonb_build_object('username', p.username) AS item
      FROM public.pi_security_events e LEFT JOIN public.profiles p ON p.id = e.user_id
     WHERE (NOT p_only_open) OR e.acknowledged_at IS NULL ORDER BY e.occurred_at DESC LIMIT p_limit) t;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_alerts(p_actor uuid, p_include_resolved boolean DEFAULT false, p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(to_jsonb(a) - 'dedupe_key' ORDER BY a.created_at DESC), '[]'::jsonb) INTO r
    FROM (SELECT * FROM public.pi_system_alerts WHERE p_include_resolved OR resolved_at IS NULL ORDER BY created_at DESC LIMIT p_limit) a;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_restrictions(p_actor uuid, p_active_only boolean DEFAULT true, p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.created_at DESC), '[]'::jsonb) INTO r FROM (
    SELECT x.created_at, to_jsonb(x) || jsonb_build_object('username', p.username) AS item
      FROM public.pi_protective_restrictions x LEFT JOIN public.profiles p ON p.id = x.user_id
     WHERE (NOT p_active_only) OR (x.lifted_at IS NULL AND x.expires_at > now()) ORDER BY x.created_at DESC LIMIT p_limit) t;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_verification(p_actor uuid, p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pending jsonb; recent jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.created_at), '[]'::jsonb) INTO pending FROM (
    SELECT q.created_at, jsonb_build_object('request_id', q.id, 'user_id', q.user_id, 'username', p.username, 'display_name', p.display_name,
             'request_reason', q.request_reason, 'evidence_url', q.evidence_url, 'created_at', q.created_at,
             'evaluation', (SELECT to_jsonb(e) FROM public.pi_verification_evaluations e WHERE e.verification_request_id = q.id ORDER BY e.created_at DESC LIMIT 1),
             'system_decision', (SELECT to_jsonb(d) - 'evaluation_id' FROM public.pi_verification_decisions d WHERE d.verification_request_id = q.id ORDER BY d.created_at DESC LIMIT 1)) AS item
      FROM public.bmn_verification_requests q LEFT JOIN public.profiles p ON p.id = q.user_id
     WHERE q.status = 'pending' ORDER BY q.created_at LIMIT p_limit) t;
  SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.created_at DESC), '[]'::jsonb) INTO recent
    FROM (SELECT * FROM public.pi_verification_decisions ORDER BY created_at DESC LIMIT 30) d;
  RETURN jsonb_build_object('pending', pending, 'recent_decisions', recent);
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_appeals(p_actor uuid, p_status text DEFAULT 'pending', p_limit integer DEFAULT 50) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  SELECT coalesce(jsonb_agg(t.item ORDER BY t.created_at), '[]'::jsonb) INTO r FROM (
    SELECT ap.created_at, to_jsonb(ap) || jsonb_build_object('username', p.username,
             'action', (SELECT jsonb_build_object('action_type', x.action_type, 'user_visible_reason', x.user_visible_reason, 'created_at', x.created_at, 'subject_type', x.subject_type)
                          FROM public.pi_moderation_actions x WHERE x.id = ap.action_id)) AS item
      FROM public.pi_appeals ap LEFT JOIN public.profiles p ON p.id = ap.user_id
     WHERE p_status = 'all' OR (p_status = 'pending' AND ap.status IN ('pending', 'under_review')) OR ap.status = p_status
     ORDER BY ap.created_at LIMIT p_limit) t;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_list_audit(p_actor uuid, p_limit integer DEFAULT 100, p_before bigint DEFAULT NULL, p_action_prefix text DEFAULT NULL) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  SELECT coalesce(jsonb_agg(to_jsonb(a) - 'ip_hash' ORDER BY a.id DESC), '[]'::jsonb) INTO r
    FROM (SELECT * FROM public.pi_audit_log WHERE (p_before IS NULL OR id < p_before) AND (p_action_prefix IS NULL OR action LIKE replace(replace(p_action_prefix, '%', ''), '_', '\_') || '%')
          ORDER BY id DESC LIMIT p_limit) a;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pi_owner_policy_overview(p_actor uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.pi_assert_owner(p_actor);
  RETURN jsonb_build_object(
    'flags', (SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.key), '[]'::jsonb) FROM public.pi_feature_flags f),
    'policies', (SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.category), '[]'::jsonb) FROM public.pi_policies p),
    'policy_history', (SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.changed_at DESC), '[]'::jsonb) FROM (SELECT * FROM public.pi_policy_versions ORDER BY changed_at DESC, id DESC LIMIT 60) v),
    'rule_sets', (SELECT coalesce(jsonb_agg(jsonb_build_object('rule_key', rule_key, 'version', version, 'status', status, 'note', note, 'created_at', created_at, 'config', CASE WHEN status = 'active' THEN config END)
                                           ORDER BY rule_key, version DESC), '[]'::jsonb) FROM public.pi_rule_sets),
    'halted', public.pi_automation_halted(),
    'enforcement_available', public.pi_enforcement_available());
END $$;

-- =====================================================================================  RLS + GRANTS
-- Same model as migration 001: RLS on, owner may SELECT, nobody else can read. ALL writes go through the
-- SECURITY DEFINER functions above, so service_role only needs SELECT on these tables.
DO $$
DECLARE
  t text; s text;
  tables text[] := ARRAY['pi_rule_sets', 'pi_policy_versions', 'pi_policy_decisions', 'pi_session_observations', 'pi_scan_cursors',
                         'pi_investigations', 'pi_investigation_notes', 'pi_system_alerts', 'pi_worker_heartbeats'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS pi_owner_select ON public.%I', t);
    EXECUTE format('CREATE POLICY pi_owner_select ON public.%I FOR SELECT TO authenticated USING ((SELECT public.is_bmn_owner()))', t);
    s := NULL;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = t AND column_name = 'id' AND is_identity = 'YES') THEN
      s := pg_get_serial_sequence('public.' || t, 'id');
    END IF;
    IF s IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated, service_role', s);
      EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO service_role', s);
    END IF;
  END LOOP;
END $$;

-- Functions: nobody by default; then service_role (the Render API) only. Every pi_ function that is not from migration 001.
DO $$
DECLARE f record;
  v_001 text[] := ARRAY['pi_touch_updated_at', 'pi_policy_bump_version', 'pi_actions_guard', 'pi_audit_guard', 'pi_block_truncate', 'pi_cases_guard_delete',
                        'pi_jobs_guard', 'pi_all_checks_pass', 'pi_write_audit', 'pi_claim_jobs', 'pi_complete_job', 'pi_fail_job', 'pi_violation_count',
                        'pi_my_moderation_notices', 'pi_submit_appeal', 'pi_decide_appeal'];
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%' AND NOT (p.proname = ANY (v_001)) LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', f.sig);
    IF f.proname NOT IN ('pi_rule_sets_guard', 'pi_policy_versions_guard', 'pi_policy_decisions_guard', 'pi_investigations_touch', 'pi_policy_snapshot') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    END IF;
  END LOOP;
END $$;

-- remember whether this run is the first install (re-runs must not be blamed for flags the owner switched on since)
SELECT set_config('pi.fresh_install', (NOT EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 2))::text, true);
INSERT INTO public.pi_schema_version (version, name) VALUES (2, '002_pi_engine') ON CONFLICT (version) DO NOTHING;

-- ---------------------------------------------------------------- post-install verification (everything is rolled back if this fails)
DO $$
DECLARE
  t text; v_bad text[] := '{}'; v_n integer;
  tables text[] := ARRAY['pi_rule_sets', 'pi_policy_versions', 'pi_policy_decisions', 'pi_session_observations', 'pi_scan_cursors',
                         'pi_investigations', 'pi_investigation_notes', 'pi_system_alerts', 'pi_worker_heartbeats'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF to_regclass('public.' || t) IS NULL THEN v_bad := v_bad || (t || ' missing');
    ELSIF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass) THEN v_bad := v_bad || (t || ' has no RLS');
    ELSIF has_table_privilege('anon', 'public.' || t, 'SELECT') OR has_table_privilege('anon', 'public.' || t, 'INSERT')
       OR has_table_privilege('authenticated', 'public.' || t, 'INSERT') OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       OR has_table_privilege('authenticated', 'public.' || t, 'DELETE') THEN v_bad := v_bad || (t || ' has unexpected privileges');
    END IF;
  END LOOP;
  SELECT count(*) INTO v_n FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('public', p.oid, 'EXECUTE'))
     AND p.proname NOT IN ('pi_my_moderation_notices', 'pi_submit_appeal');
  IF v_n > 0 THEN v_bad := v_bad || (v_n || ' pi_ function(s) callable by anon/public'); END IF;
  SELECT count(*) INTO v_n FROM public.pi_feature_flags WHERE enabled AND key = 'verification_evaluation';
  IF v_n > 0 AND coalesce(current_setting('pi.fresh_install', true), 'true') = 'true' THEN
    v_bad := v_bad || ('the new verification_evaluation flag is ON immediately after install; 002 must not enable anything');
  END IF;
  IF (SELECT count(*) FROM public.pi_policies) > (SELECT count(*) FROM public.pi_policy_versions) THEN v_bad := v_bad || 'policy version snapshots are missing'; END IF;
  IF cardinality(v_bad) > 0 THEN
    RAISE EXCEPTION 'Migration 002 verification failed (nothing was changed): %', array_to_string(v_bad, '; ') USING ERRCODE = 'P0001';
  END IF;
END $$;

COMMIT;
