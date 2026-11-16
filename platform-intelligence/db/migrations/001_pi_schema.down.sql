-- =====================================================================================
-- BMN Platform Intelligence — migration 001 (DOWN / ROLLBACK)
-- Removes ONLY objects created by 001_pi_schema.up.sql (everything named pi_*).
-- Never touches any existing BMN table, function, policy, trigger, index or row.
--
-- SAFETY: this destroys Platform Intelligence data, including the moderation audit trail.
-- If any real (non-seed) data exists, the rollback REFUSES to run until you explicitly confirm:
--     SET pi.confirm_rollback = 'yes';      -- in the same session, before running this file
-- Export what you need first (e.g. pg_dump --table='public.pi_*').
--
-- Partial or damaged installs: if pi_ objects exist but the install marker table (pi_schema_version) is
-- missing, this file cannot tell whether those objects are ours. It then REFUSES until you also run
--     SET pi.confirm_partial_cleanup = 'yes';
-- and it will then drop every object that carries one of the exact names created by migration 001
-- (including a foreign object that happens to share such a name), and nothing else. Unknown extra pi_
-- objects are left in place and reported.
-- =====================================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
DECLARE
  v_confirmed boolean := coalesce(current_setting('pi.confirm_rollback', true), '') = 'yes';
  v_partial_ok boolean := coalesce(current_setting('pi.confirm_partial_cleanup', true), '') = 'yes';
  v_any boolean;
  v_rows bigint := 0;
  t text;
  n bigint;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname LIKE 'pi\_%' AND relkind IN ('r', 'p', 'S', 'v', 'm', 'f'))
      OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'pi\_%')
      OR EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname LIKE 'pi\_%' AND typtype = 'd')
    INTO v_any;
  IF v_any AND to_regclass('public.pi_schema_version') IS NULL AND NOT v_partial_ok THEN
    RAISE EXCEPTION 'Rollback refused: pi_ objects exist but the install marker (pi_schema_version) is missing, so this is a partial, damaged or foreign installation. Inspect it, export anything you need, then run  SET pi.confirm_partial_cleanup = ''yes'';  and retry.'
      USING ERRCODE = 'P0001';
  END IF;
  -- Seed/config tables (flags, policies, schema version, provider health) don't count as "data"
  -- in a normal rollback; in a partial cleanup every named table is counted.
  FOREACH t IN ARRAY ARRAY['pi_moderation_cases', 'pi_content_analyses', 'pi_moderation_actions', 'pi_appeals',
                           'pi_account_risk_assessments', 'pi_security_events', 'pi_protective_restrictions',
                           'pi_verification_evaluations', 'pi_verification_decisions', 'pi_ai_provider_usage',
                           'pi_jobs', 'pi_audit_log']
                   || CASE WHEN to_regclass('public.pi_schema_version') IS NULL
                           THEN ARRAY['pi_feature_flags', 'pi_policies', 'pi_provider_health'] ELSE ARRAY[]::text[] END LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
      v_rows := v_rows + n;
    END IF;
  END LOOP;
  IF v_rows > 0 AND NOT v_confirmed THEN
    RAISE EXCEPTION 'Rollback refused: % rows of Platform Intelligence data exist (including audit history). Export them, then run  SET pi.confirm_rollback = ''yes'';  and retry.', v_rows
      USING ERRCODE = 'P0001';
  END IF;
END $$;

-- functions (explicit signatures; nothing outside pi_ is named here)
DROP FUNCTION IF EXISTS public.pi_decide_appeal(uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.pi_submit_appeal(uuid, text);
DROP FUNCTION IF EXISTS public.pi_my_moderation_notices();
DROP FUNCTION IF EXISTS public.pi_violation_count(uuid, interval);
DROP FUNCTION IF EXISTS public.pi_fail_job(uuid, text, text, interval);
DROP FUNCTION IF EXISTS public.pi_complete_job(uuid, text);
DROP FUNCTION IF EXISTS public.pi_claim_jobs(text, integer, interval, text[]);
DROP FUNCTION IF EXISTS public.pi_write_audit(uuid, text, text, text, text, jsonb, jsonb, text);

-- tables (children first; CASCADE is not used so nothing outside pi_ can be dropped by accident)
DROP TABLE IF EXISTS public.pi_audit_log;
DROP TABLE IF EXISTS public.pi_jobs;
DROP TABLE IF EXISTS public.pi_provider_health;
DROP TABLE IF EXISTS public.pi_ai_provider_usage;
DROP TABLE IF EXISTS public.pi_verification_decisions;
DROP TABLE IF EXISTS public.pi_verification_evaluations;
DROP TABLE IF EXISTS public.pi_protective_restrictions;
DROP TABLE IF EXISTS public.pi_security_events;
DROP TABLE IF EXISTS public.pi_account_risk_assessments;
DROP TABLE IF EXISTS public.pi_appeals;
DROP TABLE IF EXISTS public.pi_moderation_actions;
DROP TABLE IF EXISTS public.pi_content_analyses;
DROP TABLE IF EXISTS public.pi_moderation_cases;
DROP TABLE IF EXISTS public.pi_policies;
DROP TABLE IF EXISTS public.pi_feature_flags;
DROP TABLE IF EXISTS public.pi_schema_version;

-- trigger functions, helper, domain (after the tables that used them)
DROP FUNCTION IF EXISTS public.pi_jobs_guard();
DROP FUNCTION IF EXISTS public.pi_cases_guard_delete();
DROP FUNCTION IF EXISTS public.pi_block_truncate();
DROP FUNCTION IF EXISTS public.pi_audit_guard();
DROP FUNCTION IF EXISTS public.pi_actions_guard();
DROP FUNCTION IF EXISTS public.pi_policy_bump_version();
DROP FUNCTION IF EXISTS public.pi_all_checks_pass(jsonb);
DROP FUNCTION IF EXISTS public.pi_touch_updated_at();
DROP DOMAIN IF EXISTS public.pi_job_type;
DROP DOMAIN IF EXISTS public.pi_category;

COMMIT;
