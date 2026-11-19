-- =====================================================================================
-- BMN Platform Intelligence — migration 002 (DOWN / ROLLBACK)
-- Removes ONLY what 002_pi_engine.up.sql added: the nine 002 tables, every pi_ function that is not from
-- migration 001, the policy-snapshot trigger on pi_policies, the verification_evaluation flag row and the
-- version-2 marker. Migration 001 (tables, data, history, audit log) and every BMN table are left untouched.
--
-- Run this BEFORE 001_pi_schema.down.sql (001's tables are referenced by 002 tables).
--
-- SAFETY: this destroys 002 data (rule-set versions, policy decisions, investigations, system alerts, session
-- observations). If any exists the rollback REFUSES until you export it and confirm in the same session:
--     SET pi.confirm_rollback = 'yes';
-- Partial/damaged installs (002 objects present but no version-2 marker) additionally need:
--     SET pi.confirm_partial_cleanup = 'yes';
-- =====================================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
DECLARE
  v_confirmed boolean := coalesce(current_setting('pi.confirm_rollback', true), '') = 'yes';
  v_partial_ok boolean := coalesce(current_setting('pi.confirm_partial_cleanup', true), '') = 'yes';
  v_marker boolean;
  v_rows bigint := 0; n bigint; t text;
  v_002 text[] := ARRAY['pi_rule_sets', 'pi_policy_versions', 'pi_policy_decisions', 'pi_session_observations', 'pi_scan_cursors',
                        'pi_investigations', 'pi_investigation_notes', 'pi_system_alerts', 'pi_worker_heartbeats'];
BEGIN
  IF to_regclass('public.pi_schema_version') IS NULL THEN
    RAISE EXCEPTION 'Rollback refused: migration 001 is not installed, so this is not a normal installation. Nothing was changed.' USING ERRCODE = 'P0001';
  END IF;
  v_marker := EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version = 2 AND name = '002_pi_engine');
  IF EXISTS (SELECT 1 FROM public.pi_schema_version WHERE version > 2) THEN
    RAISE EXCEPTION 'Rollback refused: a newer Platform Intelligence schema is installed; roll that back first.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_marker THEN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname = ANY (v_002)) AND NOT v_partial_ok THEN
      RAISE EXCEPTION 'Rollback refused: 002 objects exist but the version-2 marker is missing (partial or damaged install). Inspect, export, then SET pi.confirm_partial_cleanup = ''yes'' and retry.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  FOREACH t IN ARRAY ARRAY['pi_rule_sets', 'pi_policy_decisions', 'pi_session_observations', 'pi_investigations', 'pi_investigation_notes', 'pi_system_alerts'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
      v_rows := v_rows + n;
    END IF;
  END LOOP;
  -- policy history beyond the version-1 snapshots taken at install time counts as data
  IF to_regclass('public.pi_policy_versions') IS NOT NULL THEN
    SELECT count(*) INTO n FROM public.pi_policy_versions WHERE version > 1;
    v_rows := v_rows + n;
  END IF;
  IF v_rows > 0 AND NOT v_confirmed THEN
    RAISE EXCEPTION 'Rollback refused: % rows of 002 data exist (rule sets, decisions, investigations, alerts, sessions or policy history). Export them, then run  SET pi.confirm_rollback = ''yes'';  and retry.', v_rows
      USING ERRCODE = 'P0001';
  END IF;
END $$;

DROP TRIGGER IF EXISTS pi_policy_snapshot_trg ON public.pi_policies;

-- the two indexes 002 added to migration-001 tables
DROP INDEX IF EXISTS public.pi_restrictions_expiry_ix;
DROP INDEX IF EXISTS public.pi_actions_expiry_ix;
DROP TABLE IF EXISTS public.pi_investigation_notes;
DROP TABLE IF EXISTS public.pi_investigations;
DROP TABLE IF EXISTS public.pi_policy_decisions;
DROP TABLE IF EXISTS public.pi_policy_versions;
DROP TABLE IF EXISTS public.pi_rule_sets;
DROP TABLE IF EXISTS public.pi_session_observations;
DROP TABLE IF EXISTS public.pi_scan_cursors;
DROP TABLE IF EXISTS public.pi_system_alerts;
DROP TABLE IF EXISTS public.pi_worker_heartbeats;


-- every pi_ function that migration 001 did not create (explicit exclusion list; nothing outside pi_ is ever named)
DO $$
DECLARE f record;
  v_001 text[] := ARRAY['pi_touch_updated_at', 'pi_policy_bump_version', 'pi_actions_guard', 'pi_audit_guard', 'pi_block_truncate', 'pi_cases_guard_delete',
                        'pi_jobs_guard', 'pi_all_checks_pass', 'pi_write_audit', 'pi_claim_jobs', 'pi_complete_job', 'pi_fail_job', 'pi_violation_count',
                        'pi_my_moderation_notices', 'pi_submit_appeal', 'pi_decide_appeal'];
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%' AND NOT (p.proname = ANY (v_001)) LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s', f.sig);
  END LOOP;
END $$;

DELETE FROM public.pi_feature_flags WHERE key = 'verification_evaluation';
DELETE FROM public.pi_schema_version WHERE version = 2 AND name = '002_pi_engine';

COMMIT;
