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
--
-- Hardening (Batch 1 review):
--   * INSTALL VERIFIER. A built-in manifest of every expected pi_ object (tables, columns, constraints,
--     indexes, triggers, policies, functions + body hashes, privileges) is compared with the database
--     BEFORE anything is changed and again AFTER. A database holding a partial, damaged, foreign or
--     newer pi_ installation is refused with a list of differences; a re-run is only accepted when the
--     existing installation is exactly complete. The manifest is regenerated from the real catalog by
--     db/tools/refresh_manifest.py and the test suite fails if it is stale.
--   * JOB QUEUE. Lease, retry, attempt and state rules are enforced by CHECK constraints, a transition
--     guard trigger and validated function arguments, not only by application code.
--   * HISTORY. Deleting a case never deletes moderation history: actions keep existing with case_id cleared,
--     the deletion is written to the append-only audit log, unresolved cases cannot be deleted, and the
--     history tables cannot be truncated.
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
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    RAISE EXCEPTION 'Precondition failed: roles anon / authenticated / service_role must exist';
  END IF;
END $$;

-- ---------------------------------------------------------------- install verifier
-- Two TEMPORARY functions (they vanish at the end of this transaction and leave nothing behind):
--   pg_temp.pi_actual()    describes every pi_ object that EXISTS right now, one text line per object.
--   pg_temp.pi_problems()  compares that with the manifest of what this migration creates.
-- The manifest is generated, never hand-edited: run db/tools/refresh_manifest.py after changing the DDL.
-- @@PI_ACTUAL_BEGIN@@
CREATE OR REPLACE FUNCTION pg_temp.pi_actual() RETURNS SETOF text LANGUAGE sql STABLE AS $f$
  SELECT 'table|' || c.relname || '|rls=' || c.relrowsecurity::text
    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind IN ('r', 'p')
  UNION ALL
  SELECT 'sequence|' || c.relname
    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind = 'S'
  UNION ALL
  SELECT 'otherrelation|' || c.relname || '|kind=' || c.relkind::text
    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind NOT IN ('r', 'p', 'i', 'S')
  UNION ALL
  SELECT 'column|' || c.relname || '.' || a.attname || '|' || format_type(a.atttypid, a.atttypmod)
         || '|notnull=' || a.attnotnull::text
         || '|identity=' || CASE a.attidentity WHEN 'a' THEN 'always' WHEN 'd' THEN 'default' ELSE 'none' END
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
   WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind IN ('r', 'p')
     AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL
  SELECT 'constraint|' || c.relname || '|' || o.conname || '|' || o.contype::text
    FROM pg_constraint o JOIN pg_class c ON c.oid = o.conrelid
   WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND o.contype IN ('p', 'u', 'c', 'f')
  UNION ALL
  SELECT 'index|' || t.relname || '|' || i.relname || '|unique=' || x.indisunique::text || '|partial=' || (x.indpred IS NOT NULL)::text
    FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid
   WHERE i.relnamespace = 'public'::regnamespace AND (i.relname LIKE 'pi\_%' OR t.relname LIKE 'pi\_%')
  UNION ALL
  SELECT 'trigger|' || c.relname || '|' || g.tgname || '|enabled=' || g.tgenabled::text
    FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid
   WHERE NOT g.tgisinternal AND c.relnamespace = 'public'::regnamespace AND (c.relname LIKE 'pi\_%' OR g.tgname LIKE 'pi\_%')
  UNION ALL
  SELECT 'policy|' || c.relname || '|' || p.polname || '|' || p.polcmd::text || '|'
         || array_to_string(ARRAY(SELECT CASE WHEN r.o = 0 THEN 'public' ELSE (SELECT rolname::text FROM pg_roles WHERE oid = r.o) END
                                    FROM unnest(p.polroles) AS r(o) ORDER BY 1), ',')
    FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
   WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%'
  UNION ALL
  SELECT 'domain|' || t.typname || '|' || format_type(t.typbasetype, t.typtypmod)
    FROM pg_type t WHERE t.typnamespace = 'public'::regnamespace AND t.typname LIKE 'pi\_%' AND t.typtype = 'd'
  UNION ALL
  SELECT 'domainconstraint|' || t.typname || '|' || o.conname
    FROM pg_constraint o JOIN pg_type t ON t.oid = o.contypid
   WHERE t.typnamespace = 'public'::regnamespace AND t.typname LIKE 'pi\_%' AND o.contype = 'c'
  UNION ALL
  SELECT 'othertype|' || t.typname || '|kind=' || t.typtype::text
    FROM pg_type t WHERE t.typnamespace = 'public'::regnamespace AND t.typname LIKE 'pi\_%' AND t.typtype <> 'd' AND t.typrelid = 0
  UNION ALL
  SELECT 'function|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|secdef=' || p.prosecdef::text
         || '|volatility=' || p.provolatile::text || '|config=' || coalesce(array_to_string(p.proconfig, ','), '')
         || '|body=' || md5(p.prosrc)
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%'
  UNION ALL
  SELECT 'execute|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || r.rolname || '|'
         || has_function_privilege(r.rolname, p.oid, 'EXECUTE')::text
    FROM pg_proc p CROSS JOIN pg_roles r
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%' AND r.rolname IN ('anon', 'authenticated', 'service_role')
  UNION ALL
  SELECT 'privileges|' || c.relname || '|' || r.rolname || '|'
         || coalesce((SELECT string_agg(pr, ',' ORDER BY pr)
                        FROM unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS pr
                       WHERE has_table_privilege(r.rolname, c.oid, pr)), 'none')
    FROM pg_class c CROSS JOIN pg_roles r
   WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind IN ('r', 'p')
     AND r.rolname IN ('anon', 'authenticated', 'service_role')
$f$;
-- @@PI_ACTUAL_END@@

-- @@PI_MANIFEST_BEGIN@@
CREATE OR REPLACE FUNCTION pg_temp.pi_problems() RETURNS SETOF text LANGUAGE sql STABLE AS $f$
  WITH exp AS (
    SELECT l FROM unnest(string_to_array($manifest$
-- @@PI_MANIFEST_DATA_BEGIN@@
column|pi_account_risk_assessments.assessed_at|timestamp with time zone|notnull=true|identity=none
column|pi_account_risk_assessments.escalated_at|timestamp with time zone|notnull=false|identity=none
column|pi_account_risk_assessments.expires_at|timestamp with time zone|notnull=false|identity=none
column|pi_account_risk_assessments.explanation|text|notnull=true|identity=none
column|pi_account_risk_assessments.id|uuid|notnull=true|identity=none
column|pi_account_risk_assessments.is_current|boolean|notnull=true|identity=none
column|pi_account_risk_assessments.model_version|text|notnull=true|identity=none
column|pi_account_risk_assessments.reason_codes|text[]|notnull=true|identity=none
column|pi_account_risk_assessments.risk_level|text|notnull=true|identity=none
column|pi_account_risk_assessments.risk_score|numeric(5,4)|notnull=true|identity=none
column|pi_account_risk_assessments.signals|jsonb|notnull=true|identity=none
column|pi_account_risk_assessments.user_id|uuid|notnull=true|identity=none
column|pi_ai_provider_usage.analysis_id|uuid|notnull=false|identity=none
column|pi_ai_provider_usage.billable_units|numeric(14,3)|notnull=false|identity=none
column|pi_ai_provider_usage.cost_basis|text|notnull=true|identity=none
column|pi_ai_provider_usage.cost_usd|numeric(12,6)|notnull=false|identity=none
column|pi_ai_provider_usage.id|bigint|notnull=true|identity=always
column|pi_ai_provider_usage.input_tokens|bigint|notnull=false|identity=none
column|pi_ai_provider_usage.latency_ms|integer|notnull=false|identity=none
column|pi_ai_provider_usage.model|text|notnull=false|identity=none
column|pi_ai_provider_usage.occurred_at|timestamp with time zone|notnull=true|identity=none
column|pi_ai_provider_usage.operation|text|notnull=true|identity=none
column|pi_ai_provider_usage.output_tokens|bigint|notnull=false|identity=none
column|pi_ai_provider_usage.provider|text|notnull=true|identity=none
column|pi_ai_provider_usage.request_count|integer|notnull=true|identity=none
column|pi_ai_provider_usage.request_id|text|notnull=false|identity=none
column|pi_ai_provider_usage.status|text|notnull=true|identity=none
column|pi_appeals.action_id|uuid|notnull=true|identity=none
column|pi_appeals.created_at|timestamp with time zone|notnull=true|identity=none
column|pi_appeals.decided_at|timestamp with time zone|notnull=false|identity=none
column|pi_appeals.decision_note|text|notnull=false|identity=none
column|pi_appeals.id|uuid|notnull=true|identity=none
column|pi_appeals.reviewer_id|uuid|notnull=false|identity=none
column|pi_appeals.statement|text|notnull=true|identity=none
column|pi_appeals.status|text|notnull=true|identity=none
column|pi_appeals.updated_at|timestamp with time zone|notnull=true|identity=none
column|pi_appeals.user_id|uuid|notnull=true|identity=none
column|pi_audit_log.action|text|notnull=true|identity=none
column|pi_audit_log.actor_id|uuid|notnull=false|identity=none
column|pi_audit_log.actor_type|text|notnull=true|identity=none
column|pi_audit_log.after_state|jsonb|notnull=false|identity=none
column|pi_audit_log.before_state|jsonb|notnull=false|identity=none
column|pi_audit_log.id|bigint|notnull=true|identity=always
column|pi_audit_log.ip_hash|text|notnull=false|identity=none
column|pi_audit_log.occurred_at|timestamp with time zone|notnull=true|identity=none
column|pi_audit_log.reason|text|notnull=false|identity=none
column|pi_audit_log.request_id|text|notnull=false|identity=none
column|pi_audit_log.target_id|text|notnull=false|identity=none
column|pi_audit_log.target_type|text|notnull=false|identity=none
column|pi_content_analyses.analysed_at|timestamp with time zone|notnull=true|identity=none
column|pi_content_analyses.analysis_kind|text|notnull=true|identity=none
column|pi_content_analyses.case_id|uuid|notnull=false|identity=none
column|pi_content_analyses.category_scores|jsonb|notnull=true|identity=none
column|pi_content_analyses.confidence|numeric(5,4)|notnull=false|identity=none
column|pi_content_analyses.content_hash|text|notnull=true|identity=none
column|pi_content_analyses.content_length|integer|notnull=false|identity=none
column|pi_content_analyses.error|text|notnull=false|identity=none
column|pi_content_analyses.idempotency_key|text|notnull=false|identity=none
column|pi_content_analyses.id|uuid|notnull=true|identity=none
column|pi_content_analyses.language|text|notnull=false|identity=none
column|pi_content_analyses.latency_ms|integer|notnull=false|identity=none
column|pi_content_analyses.model_version|text|notnull=false|identity=none
column|pi_content_analyses.model|text|notnull=false|identity=none
column|pi_content_analyses.outcome|text|notnull=true|identity=none
column|pi_content_analyses.policy_version|integer|notnull=false|identity=none
column|pi_content_analyses.provider|text|notnull=true|identity=none
column|pi_content_analyses.risk_score|numeric(5,4)|notnull=false|identity=none
column|pi_content_analyses.subject_id|uuid|notnull=true|identity=none
column|pi_content_analyses.subject_type|text|notnull=true|identity=none
column|pi_content_analyses.subject_user_id|uuid|notnull=false|identity=none
column|pi_content_analyses.top_category|pi_category|notnull=false|identity=none
column|pi_feature_flags.config|jsonb|notnull=true|identity=none
column|pi_feature_flags.description|text|notnull=true|identity=none
column|pi_feature_flags.enabled|boolean|notnull=true|identity=none
column|pi_feature_flags.key|text|notnull=true|identity=none
column|pi_feature_flags.updated_at|timestamp with time zone|notnull=true|identity=none
column|pi_feature_flags.updated_by|uuid|notnull=false|identity=none
column|pi_jobs.attempts|integer|notnull=true|identity=none
column|pi_jobs.created_at|timestamp with time zone|notnull=true|identity=none
column|pi_jobs.finished_at|timestamp with time zone|notnull=false|identity=none
column|pi_jobs.idempotency_key|text|notnull=false|identity=none
column|pi_jobs.id|uuid|notnull=true|identity=none
column|pi_jobs.job_type|pi_job_type|notnull=true|identity=none
column|pi_jobs.last_error|text|notnull=false|identity=none
column|pi_jobs.lease_expires_at|timestamp with time zone|notnull=false|identity=none
column|pi_jobs.locked_at|timestamp with time zone|notnull=false|identity=none
column|pi_jobs.locked_by|text|notnull=false|identity=none
column|pi_jobs.max_attempts|integer|notnull=true|identity=none
column|pi_jobs.payload|jsonb|notnull=true|identity=none
column|pi_jobs.priority|smallint|notnull=true|identity=none
column|pi_jobs.run_after|timestamp with time zone|notnull=true|identity=none
column|pi_jobs.started_at|timestamp with time zone|notnull=false|identity=none
column|pi_jobs.status|text|notnull=true|identity=none
column|pi_jobs.updated_at|timestamp with time zone|notnull=true|identity=none
column|pi_moderation_actions.action_type|text|notnull=true|identity=none
column|pi_moderation_actions.actor_id|uuid|notnull=false|identity=none
column|pi_moderation_actions.actor_type|text|notnull=true|identity=none
column|pi_moderation_actions.analysis_id|uuid|notnull=false|identity=none
column|pi_moderation_actions.appealable|boolean|notnull=true|identity=none
column|pi_moderation_actions.case_id|uuid|notnull=false|identity=none
column|pi_moderation_actions.confidence|numeric(5,4)|notnull=false|identity=none
column|pi_moderation_actions.created_at|timestamp with time zone|notnull=true|identity=none
column|pi_moderation_actions.expires_at|timestamp with time zone|notnull=false|identity=none
column|pi_moderation_actions.idempotency_key|text|notnull=false|identity=none
column|pi_moderation_actions.id|uuid|notnull=true|identity=none
column|pi_moderation_actions.internal_note|text|notnull=false|identity=none
column|pi_moderation_actions.mode|text|notnull=true|identity=none
column|pi_moderation_actions.policy_id|uuid|notnull=false|identity=none
column|pi_moderation_actions.policy_version|integer|notnull=false|identity=none
column|pi_moderation_actions.reason_code|pi_category|notnull=false|identity=none
column|pi_moderation_actions.reversal_reason|text|notnull=false|identity=none
column|pi_moderation_actions.reversed_at|timestamp with time zone|notnull=false|identity=none
column|pi_moderation_actions.reversed_by|uuid|notnull=false|identity=none
column|pi_moderation_actions.subject_id|uuid|notnull=true|identity=none
column|pi_moderation_actions.subject_type|text|notnull=true|identity=none
column|pi_moderation_actions.target_user_id|uuid|notnull=false|identity=none
column|pi_moderation_actions.user_visible_reason|text|notnull=false|identity=none
column|pi_moderation_cases.assigned_to|uuid|notnull=false|identity=none
column|pi_moderation_cases.confidence|numeric(5,4)|notnull=false|identity=none
column|pi_moderation_cases.idempotency_key|text|notnull=false|identity=none
column|pi_moderation_cases.id|uuid|notnull=true|identity=none
column|pi_moderation_cases.opened_at|timestamp with time zone|notnull=true|identity=none
column|pi_moderation_cases.primary_category|pi_category|notnull=false|identity=none
column|pi_moderation_cases.priority|smallint|notnull=true|identity=none
column|pi_moderation_cases.report_id|uuid|notnull=false|identity=none
column|pi_moderation_cases.requires_human_review|boolean|notnull=true|identity=none
column|pi_moderation_cases.resolution|text|notnull=false|identity=none
column|pi_moderation_cases.resolved_at|timestamp with time zone|notnull=false|identity=none
column|pi_moderation_cases.risk_score|numeric(5,4)|notnull=false|identity=none
column|pi_moderation_cases.source|text|notnull=true|identity=none
column|pi_moderation_cases.status|text|notnull=true|identity=none
column|pi_moderation_cases.subject_id|uuid|notnull=true|identity=none
column|pi_moderation_cases.subject_type|text|notnull=true|identity=none
column|pi_moderation_cases.subject_user_id|uuid|notnull=false|identity=none
column|pi_moderation_cases.updated_at|timestamp with time zone|notnull=true|identity=none
column|pi_policies.always_human_review|boolean|notnull=true|identity=none
column|pi_policies.auto_action_threshold|numeric(4,3)|notnull=false|identity=none
column|pi_policies.category|pi_category|notnull=true|identity=none
column|pi_policies.description|text|notnull=true|identity=none
column|pi_policies.enabled|boolean|notnull=true|identity=none
column|pi_policies.id|uuid|notnull=true|identity=none
column|pi_policies.max_auto_action|text|notnull=true|identity=none
column|pi_policies.review_threshold|numeric(4,3)|notnull=false|identity=none
column|pi_policies.updated_at|timestamp with time zone|notnull=true|identity=none
column|pi_policies.updated_by|uuid|notnull=false|identity=none
column|pi_policies.version|integer|notnull=true|identity=none
column|pi_protective_restrictions.actor_type|text|notnull=true|identity=none
column|pi_protective_restrictions.assessment_id|uuid|notnull=false|identity=none
column|pi_protective_restrictions.created_at|timestamp with time zone|notnull=true|identity=none
column|pi_protective_restrictions.created_by|uuid|notnull=false|identity=none
column|pi_protective_restrictions.expires_at|timestamp with time zone|notnull=true|identity=none
column|pi_protective_restrictions.id|uuid|notnull=true|identity=none
column|pi_protective_restrictions.lift_reason|text|notnull=false|identity=none
column|pi_protective_restrictions.lifted_at|timestamp with time zone|notnull=false|identity=none
column|pi_protective_restrictions.lifted_by|uuid|notnull=false|identity=none
column|pi_protective_restrictions.mode|text|notnull=true|identity=none
column|pi_protective_restrictions.reason_code|text|notnull=true|identity=none
column|pi_protective_restrictions.restriction_type|text|notnull=true|identity=none
column|pi_protective_restrictions.starts_at|timestamp with time zone|notnull=true|identity=none
column|pi_protective_restrictions.user_id|uuid|notnull=true|identity=none
column|pi_provider_health.circuit_open_until|timestamp with time zone|notnull=false|identity=none
column|pi_provider_health.consecutive_failures|integer|notnull=true|identity=none
column|pi_provider_health.last_error|text|notnull=false|identity=none
column|pi_provider_health.last_failure_at|timestamp with time zone|notnull=false|identity=none
column|pi_provider_health.last_success_at|timestamp with time zone|notnull=false|identity=none
column|pi_provider_health.provider|text|notnull=true|identity=none
column|pi_provider_health.state|text|notnull=true|identity=none
column|pi_provider_health.updated_at|timestamp with time zone|notnull=true|identity=none
column|pi_schema_version.applied_at|timestamp with time zone|notnull=true|identity=none
column|pi_schema_version.name|text|notnull=true|identity=none
column|pi_schema_version.version|integer|notnull=true|identity=none
column|pi_security_events.acknowledged_at|timestamp with time zone|notnull=false|identity=none
column|pi_security_events.acknowledged_by|uuid|notnull=false|identity=none
column|pi_security_events.case_id|uuid|notnull=false|identity=none
column|pi_security_events.dedupe_key|text|notnull=false|identity=none
column|pi_security_events.details|jsonb|notnull=true|identity=none
column|pi_security_events.device_hash|text|notnull=false|identity=none
column|pi_security_events.event_type|text|notnull=true|identity=none
column|pi_security_events.id|bigint|notnull=true|identity=always
column|pi_security_events.ip_hash|text|notnull=false|identity=none
column|pi_security_events.occurred_at|timestamp with time zone|notnull=true|identity=none
column|pi_security_events.severity|text|notnull=true|identity=none
column|pi_security_events.source|text|notnull=true|identity=none
column|pi_security_events.user_id|uuid|notnull=false|identity=none
column|pi_verification_decisions.created_at|timestamp with time zone|notnull=true|identity=none
column|pi_verification_decisions.decided_by_type|text|notnull=true|identity=none
column|pi_verification_decisions.decided_by|uuid|notnull=false|identity=none
column|pi_verification_decisions.decision|text|notnull=true|identity=none
column|pi_verification_decisions.evaluation_id|uuid|notnull=false|identity=none
column|pi_verification_decisions.fraud_related|boolean|notnull=true|identity=none
column|pi_verification_decisions.id|uuid|notnull=true|identity=none
column|pi_verification_decisions.reason|text|notnull=true|identity=none
column|pi_verification_decisions.user_id|uuid|notnull=true|identity=none
column|pi_verification_decisions.verification_request_id|uuid|notnull=false|identity=none
column|pi_verification_evaluations.checks|jsonb|notnull=true|identity=none
column|pi_verification_evaluations.created_at|timestamp with time zone|notnull=true|identity=none
column|pi_verification_evaluations.criteria_version|integer|notnull=true|identity=none
column|pi_verification_evaluations.id|uuid|notnull=true|identity=none
column|pi_verification_evaluations.impersonation_risk|numeric(5,4)|notnull=false|identity=none
column|pi_verification_evaluations.outcome|text|notnull=true|identity=none
column|pi_verification_evaluations.user_id|uuid|notnull=true|identity=none
column|pi_verification_evaluations.verification_request_id|uuid|notnull=true|identity=none
constraint|pi_account_risk_assessments|pi_account_risk_assessments_explanation_check|c
constraint|pi_account_risk_assessments|pi_account_risk_assessments_pkey|p
constraint|pi_account_risk_assessments|pi_account_risk_assessments_risk_level_check|c
constraint|pi_account_risk_assessments|pi_account_risk_assessments_risk_score_check|c
constraint|pi_account_risk_assessments|pi_account_risk_assessments_signals_check|c
constraint|pi_account_risk_assessments|pi_account_risk_assessments_user_id_fkey|f
constraint|pi_account_risk_assessments|pi_risk_explainable|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_analysis_id_fkey|f
constraint|pi_ai_provider_usage|pi_ai_provider_usage_billable_units_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_cost_basis_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_cost_usd_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_input_tokens_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_latency_ms_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_operation_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_output_tokens_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_pkey|p
constraint|pi_ai_provider_usage|pi_ai_provider_usage_provider_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_request_count_check|c
constraint|pi_ai_provider_usage|pi_ai_provider_usage_status_check|c
constraint|pi_ai_provider_usage|pi_usage_cost_consistent|c
constraint|pi_appeals|pi_appeals_action_id_fkey|f
constraint|pi_appeals|pi_appeals_action_id_key|u
constraint|pi_appeals|pi_appeals_decided_consistent|c
constraint|pi_appeals|pi_appeals_decision_has_note|c
constraint|pi_appeals|pi_appeals_pkey|p
constraint|pi_appeals|pi_appeals_reviewer_id_fkey|f
constraint|pi_appeals|pi_appeals_statement_check|c
constraint|pi_appeals|pi_appeals_status_check|c
constraint|pi_appeals|pi_appeals_user_id_fkey|f
constraint|pi_audit_log|pi_audit_log_action_check|c
constraint|pi_audit_log|pi_audit_log_actor_type_check|c
constraint|pi_audit_log|pi_audit_log_ip_hash_check|c
constraint|pi_audit_log|pi_audit_log_pkey|p
constraint|pi_content_analyses|pi_analyses_error_recorded|c
constraint|pi_content_analyses|pi_analyses_scored|c
constraint|pi_content_analyses|pi_content_analyses_analysis_kind_check|c
constraint|pi_content_analyses|pi_content_analyses_case_id_fkey|f
constraint|pi_content_analyses|pi_content_analyses_category_scores_check|c
constraint|pi_content_analyses|pi_content_analyses_confidence_check|c
constraint|pi_content_analyses|pi_content_analyses_content_hash_check|c
constraint|pi_content_analyses|pi_content_analyses_content_length_check|c
constraint|pi_content_analyses|pi_content_analyses_idempotency_key_key|u
constraint|pi_content_analyses|pi_content_analyses_latency_ms_check|c
constraint|pi_content_analyses|pi_content_analyses_outcome_check|c
constraint|pi_content_analyses|pi_content_analyses_pkey|p
constraint|pi_content_analyses|pi_content_analyses_provider_check|c
constraint|pi_content_analyses|pi_content_analyses_risk_score_check|c
constraint|pi_content_analyses|pi_content_analyses_subject_type_check|c
constraint|pi_content_analyses|pi_content_analyses_subject_user_id_fkey|f
constraint|pi_feature_flags|pi_feature_flags_config_check|c
constraint|pi_feature_flags|pi_feature_flags_key_check|c
constraint|pi_feature_flags|pi_feature_flags_pkey|p
constraint|pi_feature_flags|pi_feature_flags_updated_by_fkey|f
constraint|pi_jobs|pi_jobs_attempts_not_negative|c
constraint|pi_jobs|pi_jobs_attempts_within_max|c
constraint|pi_jobs|pi_jobs_finished_consistent|c
constraint|pi_jobs|pi_jobs_idempotency_key_key|u
constraint|pi_jobs|pi_jobs_lease_after_lock|c
constraint|pi_jobs|pi_jobs_lock_consistent|c
constraint|pi_jobs|pi_jobs_max_attempts_range|c
constraint|pi_jobs|pi_jobs_payload_is_object|c
constraint|pi_jobs|pi_jobs_pkey|p
constraint|pi_jobs|pi_jobs_priority_range|c
constraint|pi_jobs|pi_jobs_running_has_attempt|c
constraint|pi_jobs|pi_jobs_status_valid|c
constraint|pi_jobs|pi_jobs_worker_id_valid|c
constraint|pi_moderation_actions|pi_actions_reversal_consistent|c
constraint|pi_moderation_actions|pi_actions_severe_needs_reason|c
constraint|pi_moderation_actions|pi_actions_system_limited|c
constraint|pi_moderation_actions|pi_actions_system_temp_expires|c
constraint|pi_moderation_actions|pi_moderation_actions_action_type_check|c
constraint|pi_moderation_actions|pi_moderation_actions_actor_id_fkey|f
constraint|pi_moderation_actions|pi_moderation_actions_actor_type_check|c
constraint|pi_moderation_actions|pi_moderation_actions_analysis_id_fkey|f
constraint|pi_moderation_actions|pi_moderation_actions_case_id_fkey|f
constraint|pi_moderation_actions|pi_moderation_actions_confidence_check|c
constraint|pi_moderation_actions|pi_moderation_actions_idempotency_key_key|u
constraint|pi_moderation_actions|pi_moderation_actions_mode_check|c
constraint|pi_moderation_actions|pi_moderation_actions_pkey|p
constraint|pi_moderation_actions|pi_moderation_actions_policy_id_fkey|f
constraint|pi_moderation_actions|pi_moderation_actions_reversed_by_fkey|f
constraint|pi_moderation_actions|pi_moderation_actions_subject_type_check|c
constraint|pi_moderation_actions|pi_moderation_actions_target_user_id_fkey|f
constraint|pi_moderation_cases|pi_cases_resolved_consistent|c
constraint|pi_moderation_cases|pi_moderation_cases_assigned_to_fkey|f
constraint|pi_moderation_cases|pi_moderation_cases_confidence_check|c
constraint|pi_moderation_cases|pi_moderation_cases_idempotency_key_key|u
constraint|pi_moderation_cases|pi_moderation_cases_pkey|p
constraint|pi_moderation_cases|pi_moderation_cases_priority_check|c
constraint|pi_moderation_cases|pi_moderation_cases_resolution_check|c
constraint|pi_moderation_cases|pi_moderation_cases_risk_score_check|c
constraint|pi_moderation_cases|pi_moderation_cases_source_check|c
constraint|pi_moderation_cases|pi_moderation_cases_status_check|c
constraint|pi_moderation_cases|pi_moderation_cases_subject_type_check|c
constraint|pi_moderation_cases|pi_moderation_cases_subject_user_id_fkey|f
constraint|pi_policies|pi_policies_auto_action_threshold_check|c
constraint|pi_policies|pi_policies_auto_needs_threshold|c
constraint|pi_policies|pi_policies_auto_not_below_review|c
constraint|pi_policies|pi_policies_category_key|u
constraint|pi_policies|pi_policies_enabled_needs_threshold|c
constraint|pi_policies|pi_policies_max_auto_action_check|c
constraint|pi_policies|pi_policies_pkey|p
constraint|pi_policies|pi_policies_review_threshold_check|c
constraint|pi_policies|pi_policies_updated_by_fkey|f
constraint|pi_protective_restrictions|pi_protective_restrictions_actor_type_check|c
constraint|pi_protective_restrictions|pi_protective_restrictions_assessment_id_fkey|f
constraint|pi_protective_restrictions|pi_protective_restrictions_created_by_fkey|f
constraint|pi_protective_restrictions|pi_protective_restrictions_lifted_by_fkey|f
constraint|pi_protective_restrictions|pi_protective_restrictions_mode_check|c
constraint|pi_protective_restrictions|pi_protective_restrictions_pkey|p
constraint|pi_protective_restrictions|pi_protective_restrictions_reason_code_check|c
constraint|pi_protective_restrictions|pi_protective_restrictions_restriction_type_check|c
constraint|pi_protective_restrictions|pi_protective_restrictions_user_id_fkey|f
constraint|pi_protective_restrictions|pi_restrictions_window|c
constraint|pi_provider_health|pi_provider_health_consecutive_failures_check|c
constraint|pi_provider_health|pi_provider_health_pkey|p
constraint|pi_provider_health|pi_provider_health_provider_check|c
constraint|pi_provider_health|pi_provider_health_state_check|c
constraint|pi_schema_version|pi_schema_version_pkey|p
constraint|pi_security_events|pi_security_events_acknowledged_by_fkey|f
constraint|pi_security_events|pi_security_events_case_id_fkey|f
constraint|pi_security_events|pi_security_events_dedupe_key_key|u
constraint|pi_security_events|pi_security_events_details_check|c
constraint|pi_security_events|pi_security_events_device_hash_check|c
constraint|pi_security_events|pi_security_events_event_type_check|c
constraint|pi_security_events|pi_security_events_ip_hash_check|c
constraint|pi_security_events|pi_security_events_pkey|p
constraint|pi_security_events|pi_security_events_severity_check|c
constraint|pi_security_events|pi_security_events_source_check|c
constraint|pi_security_events|pi_security_events_user_id_fkey|f
constraint|pi_verification_decisions|pi_verif_fraud_is_revocation|c
constraint|pi_verification_decisions|pi_verif_system_approval_has_evaluation|c
constraint|pi_verification_decisions|pi_verif_system_limited|c
constraint|pi_verification_decisions|pi_verification_decisions_decided_by_fkey|f
constraint|pi_verification_decisions|pi_verification_decisions_decided_by_type_check|c
constraint|pi_verification_decisions|pi_verification_decisions_decision_check|c
constraint|pi_verification_decisions|pi_verification_decisions_evaluation_id_fkey|f
constraint|pi_verification_decisions|pi_verification_decisions_pkey|p
constraint|pi_verification_decisions|pi_verification_decisions_reason_check|c
constraint|pi_verification_decisions|pi_verification_decisions_user_id_fkey|f
constraint|pi_verification_evaluations|pi_verif_eligible_requires_all_pass|c
constraint|pi_verification_evaluations|pi_verification_evaluations_checks_check|c
constraint|pi_verification_evaluations|pi_verification_evaluations_criteria_version_check|c
constraint|pi_verification_evaluations|pi_verification_evaluations_impersonation_risk_check|c
constraint|pi_verification_evaluations|pi_verification_evaluations_outcome_check|c
constraint|pi_verification_evaluations|pi_verification_evaluations_pkey|p
constraint|pi_verification_evaluations|pi_verification_evaluations_user_id_fkey|f
domainconstraint|pi_category|pi_category_check
domainconstraint|pi_job_type|pi_job_type_check
domain|pi_category|text
domain|pi_job_type|text
execute|pi_actions_guard()|anon|false
execute|pi_actions_guard()|authenticated|false
execute|pi_actions_guard()|service_role|false
execute|pi_all_checks_pass(p_checks jsonb)|anon|false
execute|pi_all_checks_pass(p_checks jsonb)|authenticated|false
execute|pi_all_checks_pass(p_checks jsonb)|service_role|true
execute|pi_audit_guard()|anon|false
execute|pi_audit_guard()|authenticated|false
execute|pi_audit_guard()|service_role|false
execute|pi_block_truncate()|anon|false
execute|pi_block_truncate()|authenticated|false
execute|pi_block_truncate()|service_role|false
execute|pi_cases_guard_delete()|anon|false
execute|pi_cases_guard_delete()|authenticated|false
execute|pi_cases_guard_delete()|service_role|false
execute|pi_claim_jobs(p_worker text, p_limit integer, p_lease interval, p_types text[])|anon|false
execute|pi_claim_jobs(p_worker text, p_limit integer, p_lease interval, p_types text[])|authenticated|false
execute|pi_claim_jobs(p_worker text, p_limit integer, p_lease interval, p_types text[])|service_role|true
execute|pi_complete_job(p_job_id uuid, p_worker text)|anon|false
execute|pi_complete_job(p_job_id uuid, p_worker text)|authenticated|false
execute|pi_complete_job(p_job_id uuid, p_worker text)|service_role|true
execute|pi_decide_appeal(p_actor uuid, p_appeal_id uuid, p_decision text, p_note text)|anon|false
execute|pi_decide_appeal(p_actor uuid, p_appeal_id uuid, p_decision text, p_note text)|authenticated|false
execute|pi_decide_appeal(p_actor uuid, p_appeal_id uuid, p_decision text, p_note text)|service_role|true
execute|pi_fail_job(p_job_id uuid, p_worker text, p_error text, p_retry_in interval)|anon|false
execute|pi_fail_job(p_job_id uuid, p_worker text, p_error text, p_retry_in interval)|authenticated|false
execute|pi_fail_job(p_job_id uuid, p_worker text, p_error text, p_retry_in interval)|service_role|true
execute|pi_jobs_guard()|anon|false
execute|pi_jobs_guard()|authenticated|false
execute|pi_jobs_guard()|service_role|false
execute|pi_my_moderation_notices()|anon|false
execute|pi_my_moderation_notices()|authenticated|true
execute|pi_my_moderation_notices()|service_role|true
execute|pi_policy_bump_version()|anon|false
execute|pi_policy_bump_version()|authenticated|false
execute|pi_policy_bump_version()|service_role|false
execute|pi_submit_appeal(p_action_id uuid, p_statement text)|anon|false
execute|pi_submit_appeal(p_action_id uuid, p_statement text)|authenticated|true
execute|pi_submit_appeal(p_action_id uuid, p_statement text)|service_role|true
execute|pi_touch_updated_at()|anon|false
execute|pi_touch_updated_at()|authenticated|false
execute|pi_touch_updated_at()|service_role|false
execute|pi_violation_count(p_user uuid, p_window interval)|anon|false
execute|pi_violation_count(p_user uuid, p_window interval)|authenticated|false
execute|pi_violation_count(p_user uuid, p_window interval)|service_role|true
execute|pi_write_audit(p_actor uuid, p_actor_type text, p_action text, p_target_type text, p_target_id text, p_before jsonb, p_after jsonb, p_reason text)|anon|false
execute|pi_write_audit(p_actor uuid, p_actor_type text, p_action text, p_target_type text, p_target_id text, p_before jsonb, p_after jsonb, p_reason text)|authenticated|false
execute|pi_write_audit(p_actor uuid, p_actor_type text, p_action text, p_target_type text, p_target_id text, p_before jsonb, p_after jsonb, p_reason text)|service_role|true
function|pi_actions_guard()|secdef=false|volatility=v|config=search_path=""|body=232a4b6b289f58c684e338e5da684cbc
function|pi_all_checks_pass(p_checks jsonb)|secdef=false|volatility=i|config=search_path=""|body=82c99a6567744c49e93e67df909b810c
function|pi_audit_guard()|secdef=false|volatility=v|config=search_path=""|body=f09127fdbfb1ef23a2421e1ed136bb86
function|pi_block_truncate()|secdef=false|volatility=v|config=search_path=""|body=2a1d56ac014403135534d269c5badef6
function|pi_cases_guard_delete()|secdef=true|volatility=v|config=search_path=""|body=9c32c76d3d5da13f9a5c4ff937d7bdce
function|pi_claim_jobs(p_worker text, p_limit integer, p_lease interval, p_types text[])|secdef=false|volatility=v|config=search_path=""|body=95545144e9ba34ba013159ff6668bc43
function|pi_complete_job(p_job_id uuid, p_worker text)|secdef=false|volatility=v|config=search_path=""|body=2d8623d4c106212fc1feb983a09268b3
function|pi_decide_appeal(p_actor uuid, p_appeal_id uuid, p_decision text, p_note text)|secdef=true|volatility=v|config=search_path=""|body=0ab667dc422fde45ae1f0d9a94945fac
function|pi_fail_job(p_job_id uuid, p_worker text, p_error text, p_retry_in interval)|secdef=false|volatility=v|config=search_path=""|body=29cb9cac42518e15e80eb577ad1962b0
function|pi_jobs_guard()|secdef=false|volatility=v|config=search_path=""|body=23a876329b8208605fbc1e08618afe32
function|pi_my_moderation_notices()|secdef=true|volatility=s|config=search_path=""|body=55612885ac2d7584eacc6de19fed8b6f
function|pi_policy_bump_version()|secdef=false|volatility=v|config=search_path=""|body=cf2fe101901309c154db1fcd548404c1
function|pi_submit_appeal(p_action_id uuid, p_statement text)|secdef=true|volatility=v|config=search_path=""|body=1d24cefe60a2d0c18c0a0fe7736ba279
function|pi_touch_updated_at()|secdef=false|volatility=v|config=search_path=""|body=c28bbd99ced3dfcd7ff6c2a1298a90e1
function|pi_violation_count(p_user uuid, p_window interval)|secdef=false|volatility=s|config=search_path=""|body=9e86b2a264948ee50e75034e7316a6ad
function|pi_write_audit(p_actor uuid, p_actor_type text, p_action text, p_target_type text, p_target_id text, p_before jsonb, p_after jsonb, p_reason text)|secdef=false|volatility=v|config=search_path=""|body=30327bd414f3a63cc9a0db3d6d366938
index|pi_account_risk_assessments|pi_account_risk_assessments_pkey|unique=true|partial=false
index|pi_account_risk_assessments|pi_risk_level_idx|unique=false|partial=true
index|pi_account_risk_assessments|pi_risk_one_current_per_user|unique=true|partial=true
index|pi_ai_provider_usage|pi_ai_provider_usage_pkey|unique=true|partial=false
index|pi_ai_provider_usage|pi_usage_provider_idx|unique=false|partial=false
index|pi_ai_provider_usage|pi_usage_time_idx|unique=false|partial=false
index|pi_appeals|pi_appeals_action_id_key|unique=true|partial=false
index|pi_appeals|pi_appeals_open_idx|unique=false|partial=true
index|pi_appeals|pi_appeals_pkey|unique=true|partial=false
index|pi_appeals|pi_appeals_user_idx|unique=false|partial=false
index|pi_audit_log|pi_audit_actor_idx|unique=false|partial=false
index|pi_audit_log|pi_audit_log_pkey|unique=true|partial=false
index|pi_audit_log|pi_audit_target_idx|unique=false|partial=false
index|pi_audit_log|pi_audit_time_idx|unique=false|partial=false
index|pi_content_analyses|pi_analyses_case_idx|unique=false|partial=true
index|pi_content_analyses|pi_analyses_hash_idx|unique=false|partial=false
index|pi_content_analyses|pi_analyses_subject_idx|unique=false|partial=false
index|pi_content_analyses|pi_content_analyses_idempotency_key_key|unique=true|partial=false
index|pi_content_analyses|pi_content_analyses_pkey|unique=true|partial=false
index|pi_feature_flags|pi_feature_flags_pkey|unique=true|partial=false
index|pi_jobs|pi_jobs_claim_idx|unique=false|partial=true
index|pi_jobs|pi_jobs_idempotency_key_key|unique=true|partial=false
index|pi_jobs|pi_jobs_lease_idx|unique=false|partial=true
index|pi_jobs|pi_jobs_pkey|unique=true|partial=false
index|pi_jobs|pi_jobs_type_status_idx|unique=false|partial=false
index|pi_moderation_actions|pi_actions_case_idx|unique=false|partial=false
index|pi_moderation_actions|pi_actions_target_idx|unique=false|partial=false
index|pi_moderation_actions|pi_moderation_actions_idempotency_key_key|unique=true|partial=false
index|pi_moderation_actions|pi_moderation_actions_pkey|unique=true|partial=false
index|pi_moderation_cases|pi_cases_queue_idx|unique=false|partial=true
index|pi_moderation_cases|pi_cases_subject_idx|unique=false|partial=false
index|pi_moderation_cases|pi_cases_user_idx|unique=false|partial=false
index|pi_moderation_cases|pi_moderation_cases_idempotency_key_key|unique=true|partial=false
index|pi_moderation_cases|pi_moderation_cases_pkey|unique=true|partial=false
index|pi_policies|pi_policies_category_key|unique=true|partial=false
index|pi_policies|pi_policies_pkey|unique=true|partial=false
index|pi_protective_restrictions|pi_protective_restrictions_pkey|unique=true|partial=false
index|pi_protective_restrictions|pi_restrictions_active_idx|unique=false|partial=true
index|pi_provider_health|pi_provider_health_pkey|unique=true|partial=false
index|pi_schema_version|pi_schema_version_pkey|unique=true|partial=false
index|pi_security_events|pi_secevents_ip_idx|unique=false|partial=true
index|pi_security_events|pi_secevents_open_idx|unique=false|partial=true
index|pi_security_events|pi_secevents_type_idx|unique=false|partial=false
index|pi_security_events|pi_secevents_user_idx|unique=false|partial=false
index|pi_security_events|pi_security_events_dedupe_key_key|unique=true|partial=false
index|pi_security_events|pi_security_events_pkey|unique=true|partial=false
index|pi_verification_decisions|pi_verif_dec_user_idx|unique=false|partial=false
index|pi_verification_decisions|pi_verification_decisions_pkey|unique=true|partial=false
index|pi_verification_evaluations|pi_verif_eval_user_idx|unique=false|partial=false
index|pi_verification_evaluations|pi_verification_evaluations_pkey|unique=true|partial=false
policy|pi_account_risk_assessments|pi_owner_select|r|authenticated
policy|pi_ai_provider_usage|pi_owner_select|r|authenticated
policy|pi_appeals|pi_appeals_select_own|r|authenticated
policy|pi_appeals|pi_owner_select|r|authenticated
policy|pi_audit_log|pi_owner_select|r|authenticated
policy|pi_content_analyses|pi_owner_select|r|authenticated
policy|pi_feature_flags|pi_owner_select|r|authenticated
policy|pi_jobs|pi_owner_select|r|authenticated
policy|pi_moderation_actions|pi_owner_select|r|authenticated
policy|pi_moderation_cases|pi_owner_select|r|authenticated
policy|pi_policies|pi_owner_select|r|authenticated
policy|pi_protective_restrictions|pi_owner_select|r|authenticated
policy|pi_provider_health|pi_owner_select|r|authenticated
policy|pi_schema_version|pi_owner_select|r|authenticated
policy|pi_security_events|pi_owner_select|r|authenticated
policy|pi_verification_decisions|pi_owner_select|r|authenticated
policy|pi_verification_evaluations|pi_owner_select|r|authenticated
privileges|pi_account_risk_assessments|anon|none
privileges|pi_account_risk_assessments|authenticated|SELECT
privileges|pi_account_risk_assessments|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_ai_provider_usage|anon|none
privileges|pi_ai_provider_usage|authenticated|SELECT
privileges|pi_ai_provider_usage|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_appeals|anon|none
privileges|pi_appeals|authenticated|SELECT
privileges|pi_appeals|service_role|INSERT,SELECT,UPDATE
privileges|pi_audit_log|anon|none
privileges|pi_audit_log|authenticated|SELECT
privileges|pi_audit_log|service_role|INSERT,SELECT
privileges|pi_content_analyses|anon|none
privileges|pi_content_analyses|authenticated|SELECT
privileges|pi_content_analyses|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_feature_flags|anon|none
privileges|pi_feature_flags|authenticated|SELECT
privileges|pi_feature_flags|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_jobs|anon|none
privileges|pi_jobs|authenticated|SELECT
privileges|pi_jobs|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_moderation_actions|anon|none
privileges|pi_moderation_actions|authenticated|SELECT
privileges|pi_moderation_actions|service_role|INSERT,SELECT,UPDATE
privileges|pi_moderation_cases|anon|none
privileges|pi_moderation_cases|authenticated|SELECT
privileges|pi_moderation_cases|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_policies|anon|none
privileges|pi_policies|authenticated|SELECT
privileges|pi_policies|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_protective_restrictions|anon|none
privileges|pi_protective_restrictions|authenticated|SELECT
privileges|pi_protective_restrictions|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_provider_health|anon|none
privileges|pi_provider_health|authenticated|SELECT
privileges|pi_provider_health|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_schema_version|anon|none
privileges|pi_schema_version|authenticated|SELECT
privileges|pi_schema_version|service_role|INSERT,SELECT
privileges|pi_security_events|anon|none
privileges|pi_security_events|authenticated|SELECT
privileges|pi_security_events|service_role|DELETE,INSERT,SELECT,UPDATE
privileges|pi_verification_decisions|anon|none
privileges|pi_verification_decisions|authenticated|SELECT
privileges|pi_verification_decisions|service_role|INSERT,SELECT
privileges|pi_verification_evaluations|anon|none
privileges|pi_verification_evaluations|authenticated|SELECT
privileges|pi_verification_evaluations|service_role|DELETE,INSERT,SELECT,UPDATE
sequence|pi_ai_provider_usage_id_seq
sequence|pi_audit_log_id_seq
sequence|pi_security_events_id_seq
table|pi_account_risk_assessments|rls=true
table|pi_ai_provider_usage|rls=true
table|pi_appeals|rls=true
table|pi_audit_log|rls=true
table|pi_content_analyses|rls=true
table|pi_feature_flags|rls=true
table|pi_jobs|rls=true
table|pi_moderation_actions|rls=true
table|pi_moderation_cases|rls=true
table|pi_policies|rls=true
table|pi_protective_restrictions|rls=true
table|pi_provider_health|rls=true
table|pi_schema_version|rls=true
table|pi_security_events|rls=true
table|pi_verification_decisions|rls=true
table|pi_verification_evaluations|rls=true
trigger|pi_appeals|pi_appeals_no_truncate|enabled=O
trigger|pi_appeals|pi_touch_appeals|enabled=O
trigger|pi_audit_log|pi_audit_no_change|enabled=O
trigger|pi_audit_log|pi_audit_no_truncate|enabled=O
trigger|pi_feature_flags|pi_touch_flags|enabled=O
trigger|pi_jobs|pi_jobs_state_guard|enabled=O
trigger|pi_moderation_actions|pi_actions_immutable|enabled=O
trigger|pi_moderation_actions|pi_actions_no_truncate|enabled=O
trigger|pi_moderation_cases|pi_cases_before_delete|enabled=O
trigger|pi_moderation_cases|pi_touch_cases|enabled=O
trigger|pi_policies|pi_policy_version|enabled=O
trigger|pi_provider_health|pi_touch_health|enabled=O
trigger|pi_verification_decisions|pi_decisions_no_truncate|enabled=O
-- @@PI_MANIFEST_DATA_END@@
$manifest$, E'\n')) AS l WHERE l <> '' AND l NOT LIKE '--%'),
  act AS (SELECT l FROM pg_temp.pi_actual() AS l)
  SELECT 'MISSING     ' || l FROM (SELECT l FROM exp EXCEPT SELECT l FROM act) m
  UNION ALL
  SELECT 'UNEXPECTED  ' || l FROM (SELECT l FROM act EXCEPT SELECT l FROM exp) u
$f$;
-- @@PI_MANIFEST_END@@

-- Classify the database before touching anything:
--   nothing named pi_*            -> fresh install, continue
--   exactly the expected install  -> safe re-run, continue (every statement below is idempotent)
--   anything else                 -> STOP with the list of differences (partial, damaged, foreign or newer)
DO $$
DECLARE
  n_objects integer; n_problems integer; v_list text; v_max integer;
BEGIN
  SELECT count(*) INTO n_objects FROM pg_temp.pi_actual();
  IF n_objects = 0 THEN
    RETURN;
  END IF;
  BEGIN
    IF to_regclass('public.pi_schema_version') IS NOT NULL THEN
      EXECUTE 'SELECT max(version) FROM public.pi_schema_version' INTO v_max;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_max := NULL;
  END;
  IF v_max IS NOT NULL AND v_max > 1 THEN
    RAISE EXCEPTION 'Platform Intelligence schema version % is already installed; migration 001 will not run over it.', v_max
      USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO n_problems FROM pg_temp.pi_problems();
  IF n_problems > 0 THEN
    SELECT string_agg(p, E'\n  ') INTO v_list FROM (SELECT p FROM pg_temp.pi_problems() AS p ORDER BY p LIMIT 15) AS s;
    RAISE EXCEPTION E'Inconsistent or partial Platform Intelligence installation detected: % difference(s) from what migration 001 creates. Nothing was changed. First differences:\n  %\nDo not re-run until this is understood. If this database only holds an old draft or a damaged install, export any data and run 001_pi_schema.down.sql first.', n_problems, v_list
      USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 1 AND name = '001_pi_schema') THEN
    RAISE EXCEPTION 'Inconsistent Platform Intelligence installation: every object is present but pi_schema_version has no row for 001_pi_schema. Nothing was changed.'
      USING ERRCODE = 'P0001';
  END IF;
END $$;

-- @@PI_DDL_BEGIN@@
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
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE n.nspname = 'public' AND t.typname = 'pi_job_type') THEN
    CREATE DOMAIN public.pi_job_type AS text CHECK (VALUE IN (
      'analyze_content', 'assess_account', 'evaluate_verification', 'apply_action',
      'reverse_action', 'expire_restrictions', 'purge_retention', 'provider_healthcheck'));
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
  -- Deleting a case must never delete the moderation history that hangs off it: the action stays, case_id is cleared.
  case_id             uuid REFERENCES public.pi_moderation_cases(id) ON DELETE SET NULL,
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
-- Only reversal fields may be written (once), and reference columns (case, user, policy, analysis) may only be
-- CLEARED, which is what ON DELETE SET NULL does when a case, account, policy or analysis is deleted.
CREATE OR REPLACE FUNCTION public.pi_actions_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'pi_moderation_actions rows cannot be deleted' USING ERRCODE = '42501';
  END IF;
  IF ROW(NEW.id, NEW.subject_type, NEW.subject_id, NEW.action_type, NEW.actor_type, NEW.mode,
         NEW.reason_code, NEW.user_visible_reason, NEW.internal_note, NEW.policy_version, NEW.confidence,
         NEW.expires_at, NEW.appealable, NEW.idempotency_key, NEW.created_at)
     IS DISTINCT FROM
     ROW(OLD.id, OLD.subject_type, OLD.subject_id, OLD.action_type, OLD.actor_type, OLD.mode,
         OLD.reason_code, OLD.user_visible_reason, OLD.internal_note, OLD.policy_version, OLD.confidence,
         OLD.expires_at, OLD.appealable, OLD.idempotency_key, OLD.created_at) THEN
    RAISE EXCEPTION 'pi_moderation_actions core fields are immutable' USING ERRCODE = '42501';
  END IF;
  IF (NEW.case_id IS DISTINCT FROM OLD.case_id AND NEW.case_id IS NOT NULL)
     OR (NEW.target_user_id IS DISTINCT FROM OLD.target_user_id AND NEW.target_user_id IS NOT NULL)
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
  -- NO ACTION (checked at the end of the statement): an evaluation that a decision relies on cannot be deleted on its own,
  -- but an account deletion, which removes both together, still succeeds.
  evaluation_id           uuid REFERENCES public.pi_verification_evaluations(id) ON DELETE NO ACTION,
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
  job_type         public.pi_job_type NOT NULL,
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT pi_jobs_payload_is_object CHECK (jsonb_typeof(payload) = 'object'),
  status           text NOT NULL DEFAULT 'queued' CONSTRAINT pi_jobs_status_valid CHECK (status IN ('queued', 'running', 'succeeded', 'dead', 'cancelled')),
  priority         smallint NOT NULL DEFAULT 5 CONSTRAINT pi_jobs_priority_range CHECK (priority BETWEEN 1 AND 9),   -- 1 runs first
  attempts         integer NOT NULL DEFAULT 0 CONSTRAINT pi_jobs_attempts_not_negative CHECK (attempts >= 0),
  max_attempts     integer NOT NULL DEFAULT 5 CONSTRAINT pi_jobs_max_attempts_range CHECK (max_attempts BETWEEN 1 AND 20),
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
  CONSTRAINT pi_jobs_attempts_within_max CHECK (attempts <= max_attempts),
  -- A job is locked if and only if it is running; a running job always names its worker and its lease.
  CONSTRAINT pi_jobs_lock_consistent CHECK (
    (status = 'running' AND locked_by IS NOT NULL AND locked_at IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR (status <> 'running' AND locked_by IS NULL AND locked_at IS NULL AND lease_expires_at IS NULL)),
  CONSTRAINT pi_jobs_worker_id_valid CHECK (locked_by IS NULL OR (btrim(locked_by) <> '' AND char_length(locked_by) <= 200)),
  CONSTRAINT pi_jobs_lease_after_lock CHECK (lease_expires_at IS NULL OR lease_expires_at > locked_at),
  CONSTRAINT pi_jobs_running_has_attempt CHECK (status <> 'running' OR attempts >= 1),
  -- Final states carry a finish time; live states never do.
  CONSTRAINT pi_jobs_finished_consistent CHECK ((status IN ('succeeded', 'dead', 'cancelled')) = (finished_at IS NOT NULL))
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

-- History tables can never be emptied in one statement (also stops TRUNCATE ... CASCADE reaching them).
CREATE OR REPLACE FUNCTION public.pi_block_truncate() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION '% is protected history and cannot be truncated', TG_TABLE_NAME USING ERRCODE = '42501';
END $$;

-- Case deletion: refuse while a human decision is still pending; otherwise allow it, keep every moderation
-- action (the FK clears case_id), and leave a permanent audit entry so the deletion is never silent.
-- SECURITY DEFINER so the audit entry is written whoever is allowed to delete the case.
CREATE OR REPLACE FUNCTION public.pi_cases_guard_delete() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actions integer;
BEGIN
  IF OLD.status IN ('open', 'awaiting_review') THEN
    RAISE EXCEPTION 'case % is still % and has not been decided; resolve or dismiss it before deleting it', OLD.id, OLD.status
      USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO v_actions FROM public.pi_moderation_actions WHERE case_id = OLD.id;
  INSERT INTO public.pi_audit_log (actor_id, actor_type, action, target_type, target_id, before_state, reason)
  VALUES (NULL, 'service', 'case_deleted', 'moderation_case', OLD.id::text,
          jsonb_build_object('subject_type', OLD.subject_type, 'subject_id', OLD.subject_id, 'status', OLD.status,
                             'resolution', OLD.resolution, 'primary_category', OLD.primary_category, 'actions_retained', v_actions),
          'case deleted; its moderation actions are retained with the case reference cleared');
  RETURN OLD;
END $$;

-- Job state machine: terminal states are final, identity and limits never change, attempts never go backwards.
CREATE OR REPLACE FUNCTION public.pi_jobs_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.job_type IS DISTINCT FROM OLD.job_type OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key OR NEW.max_attempts IS DISTINCT FROM OLD.max_attempts
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'a job''s type, payload, idempotency key, attempt limit and creation time cannot be changed; enqueue a new job instead'
      USING ERRCODE = '55000';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'job attempts can never go backwards' USING ERRCODE = '55000';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status
     AND (OLD.status, NEW.status) NOT IN (('queued', 'running'), ('running', 'queued'), ('running', 'succeeded'),
                                          ('running', 'dead'), ('queued', 'cancelled'), ('running', 'cancelled')) THEN
    RAISE EXCEPTION 'illegal job state change % -> % (succeeded, dead and cancelled are final)', OLD.status, NEW.status
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
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
DROP TRIGGER IF EXISTS pi_actions_no_truncate ON public.pi_moderation_actions;
CREATE TRIGGER pi_actions_no_truncate BEFORE TRUNCATE ON public.pi_moderation_actions FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_appeals_no_truncate ON public.pi_appeals;
CREATE TRIGGER pi_appeals_no_truncate BEFORE TRUNCATE ON public.pi_appeals FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_decisions_no_truncate ON public.pi_verification_decisions;
CREATE TRIGGER pi_decisions_no_truncate BEFORE TRUNCATE ON public.pi_verification_decisions FOR EACH STATEMENT EXECUTE FUNCTION public.pi_block_truncate();
DROP TRIGGER IF EXISTS pi_cases_before_delete ON public.pi_moderation_cases;
CREATE TRIGGER pi_cases_before_delete BEFORE DELETE ON public.pi_moderation_cases FOR EACH ROW EXECUTE FUNCTION public.pi_cases_guard_delete();
DROP TRIGGER IF EXISTS pi_jobs_state_guard ON public.pi_jobs;
CREATE TRIGGER pi_jobs_state_guard BEFORE UPDATE ON public.pi_jobs FOR EACH ROW EXECUTE FUNCTION public.pi_jobs_guard();

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
-- p_lease: how long this worker may hold the job before another worker may take it over (1 second to 1 hour).
-- p_types: NULL = any type, otherwise a non-empty list of known job types.
CREATE OR REPLACE FUNCTION public.pi_claim_jobs(
  p_worker text, p_limit integer DEFAULT 10, p_lease interval DEFAULT interval '5 minutes', p_types text[] DEFAULT NULL)
  RETURNS SETOF public.pi_jobs
  LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF p_worker IS NULL OR btrim(p_worker) = '' OR char_length(p_worker) > 200 THEN
    RAISE EXCEPTION 'worker id required (1 to 200 characters)' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;
  IF p_lease IS NULL OR p_lease < interval '1 second' OR p_lease > interval '1 hour' THEN
    RAISE EXCEPTION 'lease must be between 1 second and 1 hour (got %)', coalesce(p_lease::text, 'NULL') USING ERRCODE = '22023';
  END IF;
  IF p_types IS NOT NULL THEN
    IF cardinality(p_types) = 0 OR array_position(p_types, NULL) IS NOT NULL THEN
      RAISE EXCEPTION 'job type filter must be NULL (all types) or a non-empty list without NULLs' USING ERRCODE = '22023';
    END IF;
    BEGIN
      PERFORM p_types::public.pi_job_type[];
    EXCEPTION WHEN check_violation OR invalid_text_representation OR datatype_mismatch THEN
      RAISE EXCEPTION 'unknown job type in filter' USING ERRCODE = '22023';
    END;
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
         lease_expires_at = now() + p_lease, started_at = coalesce(j.started_at, now()), updated_at = now(),
         last_error = CASE WHEN j.status = 'running' THEN left(coalesce(j.last_error, '') || ' [lease expired; reclaimed]', 2000)
                           ELSE j.last_error END
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
-- caller does not hold the job. p_retry_in: NULL = automatic back-off (10s, 20s, 40s ... capped at 1 hour),
-- otherwise an explicit delay between 1 second and 7 days.
CREATE OR REPLACE FUNCTION public.pi_fail_job(p_job_id uuid, p_worker text, p_error text, p_retry_in interval DEFAULT NULL)
  RETURNS text
  LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE j public.pi_jobs; v_status text;
BEGIN
  IF p_worker IS NULL OR btrim(p_worker) = '' THEN
    RAISE EXCEPTION 'worker id required' USING ERRCODE = '22023';
  END IF;
  IF p_retry_in IS NOT NULL AND (p_retry_in < interval '1 second' OR p_retry_in > interval '7 days') THEN
    RAISE EXCEPTION 'retry delay must be NULL (automatic back-off) or between 1 second and 7 days (got %)', p_retry_in
      USING ERRCODE = '22023';
  END IF;
  SELECT * INTO j FROM public.pi_jobs WHERE id = p_job_id AND status = 'running' AND locked_by = p_worker FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_status := CASE WHEN j.attempts >= j.max_attempts THEN 'dead' ELSE 'queued' END;
  UPDATE public.pi_jobs
     SET status = v_status, locked_by = NULL, locked_at = NULL, lease_expires_at = NULL,
         last_error = left(coalesce(nullif(btrim(p_error), ''), 'unspecified error'), 2000),
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
-- Privileges are set EXPLICITLY (REVOKE ALL first, including service_role) so the result never depends on
-- the database's default privileges, which differ between environments.
DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'pi_schema_version', 'pi_feature_flags', 'pi_policies', 'pi_moderation_cases', 'pi_content_analyses',
    'pi_moderation_actions', 'pi_appeals', 'pi_account_risk_assessments', 'pi_security_events',
    'pi_protective_restrictions', 'pi_verification_evaluations', 'pi_verification_decisions',
    'pi_ai_provider_usage', 'pi_provider_health', 'pi_jobs', 'pi_audit_log'];
  s text;
  v_service_privs text;
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);     -- still filtered by RLS below
    -- The API (service_role) never gets TRUNCATE, REFERENCES or TRIGGER, and history tables are append-only
    -- or update-only at the privilege level as well as by trigger.
    v_service_privs := CASE t
      WHEN 'pi_audit_log'              THEN 'SELECT, INSERT'
      WHEN 'pi_moderation_actions'     THEN 'SELECT, INSERT, UPDATE'
      WHEN 'pi_appeals'                THEN 'SELECT, INSERT, UPDATE'
      WHEN 'pi_verification_decisions' THEN 'SELECT, INSERT'
      WHEN 'pi_schema_version'         THEN 'SELECT, INSERT'
      ELSE 'SELECT, INSERT, UPDATE, DELETE' END;
    EXECUTE format('GRANT %s ON public.%I TO service_role', v_service_privs, t);
    EXECUTE format('DROP POLICY IF EXISTS pi_owner_select ON public.%I', t);
    EXECUTE format('CREATE POLICY pi_owner_select ON public.%I FOR SELECT TO authenticated USING ((SELECT public.is_bmn_owner()))', t);
    -- pg_get_serial_sequence() raises an error for a table with no such column, so check first.
    s := NULL;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = t AND column_name = 'id' AND is_identity = 'YES') THEN
      s := pg_get_serial_sequence('public.' || t, 'id');
    END IF;
    IF s IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated, service_role', s);
      EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO service_role', s);
    END IF;
  END LOOP;
END $$;

-- A user may read their own appeals; nothing else in pi_ is readable by ordinary users.
DROP POLICY IF EXISTS pi_appeals_select_own ON public.pi_appeals;
CREATE POLICY pi_appeals_select_own ON public.pi_appeals FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Functions: nobody by default (including service_role); then grant exactly what each caller needs.
REVOKE ALL ON FUNCTION
  public.pi_touch_updated_at(), public.pi_policy_bump_version(), public.pi_actions_guard(), public.pi_audit_guard(),
  public.pi_block_truncate(), public.pi_cases_guard_delete(), public.pi_jobs_guard(),
  public.pi_all_checks_pass(jsonb),
  public.pi_write_audit(uuid, text, text, text, text, jsonb, jsonb, text),
  public.pi_claim_jobs(text, integer, interval, text[]),
  public.pi_complete_job(uuid, text),
  public.pi_fail_job(uuid, text, text, interval),
  public.pi_violation_count(uuid, interval),
  public.pi_my_moderation_notices(),
  public.pi_submit_appeal(uuid, text),
  public.pi_decide_appeal(uuid, uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

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
-- @@PI_DDL_END@@

-- ---------------------------------------------------------------- post-install verification
-- The finished installation must match the manifest exactly, otherwise EVERYTHING above is rolled back.
DO $$
DECLARE n integer; v_list text;
BEGIN
  SELECT count(*) INTO n FROM pg_temp.pi_problems();
  IF n > 0 THEN
    SELECT string_agg(p, E'\n  ') INTO v_list FROM (SELECT p FROM pg_temp.pi_problems() AS p ORDER BY p LIMIT 15) AS s;
    RAISE EXCEPTION E'Post-install verification FAILED with % difference(s); the migration has been rolled back. First differences:\n  %', n, v_list
      USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 1 AND name = '001_pi_schema') THEN
    RAISE EXCEPTION 'Post-install verification FAILED: schema version row missing; the migration has been rolled back.' USING ERRCODE = 'P0001';
  END IF;
END $$;

DROP FUNCTION pg_temp.pi_problems();
DROP FUNCTION pg_temp.pi_actual();

COMMIT;
