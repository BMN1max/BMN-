-- Platform Intelligence ENGINE tests (migration 002): policy engine, rule sets, moderation / account / verification commits,
-- human decisions, expiry, health, privileges, immutability. Run AFTER 001 and 002 on the disposable test database. Never run on production.
-- Identities: u(1)=owner, u(2)/u(3)/u(4)=seeded users, u(5)..u(12)=users created below, u(20)=throw-away user (deletion test).

GRANT USAGE ON SCHEMA pgtest TO PUBLIC;
SET request.jwt.claim.role = 'service_role';       -- session default for direct setup statements (as the Render API would run)

-- ---------------------------------------------------------------- test helpers (schema pgtest only)
CREATE OR REPLACE FUNCTION pgtest.mp(p_key text, p_type text, p_subject uuid, p_user uuid, p_cat text, p_outcome text, p_action text,
                                     p_dec jsonb DEFAULT '{}'::jsonb, p_extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('idempotency_key', p_key, 'subject_type', p_type, 'subject_id', p_subject, 'subject_user_id', p_user,
           'top_category', p_cat, 'outcome', p_outcome, 'risk_score', 0.7, 'confidence', 0.8,
           'content_hash', md5(p_key) || md5(p_key), 'content_length', 50, 'provider', 'bmn_rules', 'rule_set_version', 1,
           'category_scores', jsonb_build_object(coalesce(p_cat, 'spam_scams'), 0.7),
           'decision', jsonb_build_object('recommended_action', p_action, 'mode', 'shadow', 'requires_human_review', false,
                                          'reasons', jsonb_build_array('test reason'), 'inputs', '{}'::jsonb) || p_dec) || p_extra
$$;

-- account assessment payload
CREATE OR REPLACE FUNCTION pgtest.ap(p_key text, p_user uuid, p_level text, p_dec jsonb DEFAULT '{}'::jsonb, p_extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('idempotency_key', p_key, 'user_id', p_user, 'risk_level', p_level,
           'risk_score', CASE p_level WHEN 'low' THEN 0.1 WHEN 'medium' THEN 0.45 WHEN 'high' THEN 0.7 ELSE 0.9 END,
           'reason_codes', CASE WHEN p_level = 'low' THEN '[]'::jsonb ELSE '["mass_follow"]'::jsonb END,
           'signals', '[{"code":"mass_follow","weight":0.4}]'::jsonb, 'explanation', 'test explanation for ' || p_level, 'rule_set_version', 1,
           'decision', jsonb_build_object('recommended_action', 'flag', 'mode', 'shadow', 'requires_human_review', false, 'inputs', '{}'::jsonb) || p_dec) || p_extra
$$;

-- verification evaluation payload (every check passes unless p_fail)
CREATE OR REPLACE FUNCTION pgtest.vp(p_req uuid, p_outcome text, p_fail boolean DEFAULT false, p_extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_id', p_req, 'criteria_version', 1, 'outcome', p_outcome, 'impersonation_risk', 0.05,
           'checks', jsonb_build_array(
             jsonb_build_object('check', 'min_account_age_days', 'result', 'pass'),
             jsonb_build_object('check', 'profile_complete', 'result', 'pass'),
             jsonb_build_object('check', 'impersonation_screen', 'result', CASE WHEN p_fail THEN 'fail' ELSE 'pass' END))) || p_extra
$$;


-- qa(): call something that WRITES, then check the resulting state in a NEW statement (a volatile call and a check in one
-- statement would not see each other's writes). pgtest.lastj() returns the call's result as jsonb.
CREATE OR REPLACE FUNCTION pgtest.lastj() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('pgtest.last', true), '')::jsonb $$;
CREATE OR REPLACE FUNCTION pgtest.qa(p_name text, p_call text, p_check text, p_role text DEFAULT NULL, p_sub uuid DEFAULT NULL) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE v_ok boolean; v_res jsonb; v_msg text; v_state text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
    PERFORM set_config('request.jwt.claim.role', coalesce(p_role, ''), true);
    IF p_role IS NOT NULL THEN EXECUTE format('SET LOCAL ROLE %I', p_role); END IF;
    EXECUTE 'SELECT to_jsonb(' || p_call || ')' INTO v_res;
    RESET ROLE;
    PERFORM set_config('pgtest.last', coalesce(v_res::text, ''), true);
    EXECUTE 'SELECT (' || p_check || ')' INTO v_ok;
    INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, coalesce(v_ok, false),
      CASE WHEN coalesce(v_ok, false) THEN 'true as expected' ELSE 'check was ' || coalesce(v_ok::text, 'NULL') || '; call returned ' || left(coalesce(v_res::text, 'NULL'), 160) END);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_state := SQLSTATE;
    INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, false, 'error ' || v_state || ': ' || left(v_msg, 200));
  END;
END $$;

-- users used by this file
INSERT INTO auth.users (id, email) SELECT pgtest.u(n), 'u' || n || '@test.invalid' FROM generate_series(5, 12) n;
INSERT INTO public.profiles (id, username, display_name, bio) SELECT pgtest.u(n), 'user' || n || '_t', 'User ' || n, 'bio ' || n FROM generate_series(5, 12) n;
INSERT INTO auth.users (id, email) VALUES (pgtest.u(17), 'u17@test.invalid');
INSERT INTO public.profiles (id, username, display_name) VALUES (pgtest.u(17), 'user17_t', 'User 17');

-- ===================================================================== A. installation state, privileges, RLS
SELECT pgtest.q('A01 schema versions 1 and 2 are recorded', $$(SELECT count(*) = 2 FROM public.pi_schema_version WHERE (version, name) IN ((1, '001_pi_schema'), (2, '002_pi_engine')))$$);
SELECT pgtest.q('A02 all 9 new tables exist with RLS enabled', $$(SELECT count(*) = 9 AND bool_and(relrowsecurity) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN
  ('pi_rule_sets','pi_policy_versions','pi_policy_decisions','pi_session_observations','pi_scan_cursors','pi_investigations','pi_investigation_notes','pi_system_alerts','pi_worker_heartbeats'))$$);
SELECT pgtest.q('A03 all 9 feature flags exist and ALL are OFF (002 enabled nothing)', $$(SELECT count(*) = 9 AND bool_and(NOT enabled) FROM public.pi_feature_flags)$$);
SELECT pgtest.q('A04 the new verification_evaluation flag exists and is OFF', $$(SELECT NOT enabled FROM public.pi_feature_flags WHERE key = 'verification_evaluation')$$);
SELECT pgtest.q('A05 every existing policy has a version-1 snapshot', $$(SELECT count(*) FROM public.pi_policy_versions WHERE version = 1) = (SELECT count(*) FROM public.pi_policies)$$);
SELECT pgtest.q('A06 runtime config: not halted, enforcement NOT available, 9 flags, 10 policies', $$(public.pi_get_runtime_config() ->> 'halted')::boolean = false
  AND (public.pi_get_runtime_config() ->> 'enforcement_available')::boolean = false AND (public.pi_get_runtime_config() ->> 'restrictions_enforceable')::boolean = false
  AND (SELECT count(*) FROM jsonb_object_keys(public.pi_get_runtime_config() -> 'flags')) = 9 AND (SELECT count(*) FROM jsonb_object_keys(public.pi_get_runtime_config() -> 'policies')) = 10$$);
SELECT pgtest.q('A07 no pi_ function is callable by anon / authenticated / PUBLIC except the two user-facing 001 functions', $$(SELECT count(*) = 0 FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%' AND p.proname NOT IN ('pi_my_moderation_notices', 'pi_submit_appeal')
    AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('public', p.oid, 'EXECUTE')))$$);
SELECT pgtest.q('A08 service_role can run every callable 002 function', $$(SELECT count(*) = 0 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%'
  AND p.prorettype <> 'trigger'::regtype AND p.proname NOT IN ('pi_my_moderation_notices', 'pi_submit_appeal', 'pi_touch_updated_at','pi_policy_bump_version','pi_actions_guard','pi_audit_guard','pi_block_truncate','pi_cases_guard_delete','pi_jobs_guard')
  AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE'))$$);
SELECT pgtest.q('A09 an ordinary signed-in user sees ZERO rows of every 002 table (RLS)', $$(SELECT (SELECT count(*) FROM public.pi_policy_versions) + (SELECT count(*) FROM public.pi_rule_sets) + (SELECT count(*) FROM public.pi_policy_decisions)
  + (SELECT count(*) FROM public.pi_investigations) + (SELECT count(*) FROM public.pi_system_alerts) + (SELECT count(*) FROM public.pi_worker_heartbeats) + (SELECT count(*) FROM public.pi_session_observations) = 0)$$, 'authenticated', pgtest.u(2));
SELECT pgtest.q('A10 the owner (through RLS, as a signed-in user) can read the policy history', $$(SELECT count(*) > 0 FROM public.pi_policy_versions)$$, 'authenticated', pgtest.u(1));
SELECT pgtest.t('A11 anon cannot read a 002 table', $$SELECT count(*) FROM public.pi_policy_versions$$, 'anon', NULL, '42501');
SELECT pgtest.t('A12 a signed-in user cannot write a 002 table', $$INSERT INTO public.pi_system_alerts (kind, severity, message) VALUES ('x', 'low', 'x')$$, 'authenticated', pgtest.u(1), '42501');
SELECT pgtest.t('A13 not even the owner can call an owner function from a browser session (EXECUTE is service_role only)', $$SELECT public.pi_owner_overview(pgtest.u(1))$$, 'authenticated', pgtest.u(1), '42501');
SELECT pgtest.t('A14 anon cannot call a commit function', $$SELECT public.pi_commit_moderation_result('{}'::jsonb)$$, 'anon', NULL, '42501');
SELECT pgtest.t('A15 a signed-in user cannot call a commit function', $$SELECT public.pi_commit_account_assessment('{}'::jsonb)$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('A16 service_role with a NON-owner actor is refused by the database itself', $$SELECT public.pi_owner_overview(pgtest.u(2))$$, 'service_role', NULL, '42501');
SELECT pgtest.t('A17 service_role with the owner actor can read the overview', $$SELECT public.pi_owner_overview(pgtest.u(1))$$, 'service_role');
SELECT pgtest.q('A18 every pi_owner_* function re-checks owner status inside the database', $$(SELECT count(*) = 0 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'pi\_owner\_%' AND prosrc NOT LIKE '%pi_assert_owner%')$$);
SELECT pgtest.q('A19 no pi_ function lacks a fixed search_path (SECURITY DEFINER hardening)', $$(SELECT count(*) = 0 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%' AND NOT coalesce(p.proconfig::text LIKE '%search_path%', false))$$);
SELECT pgtest.q('A20 the content-analysis table has no column that could hold raw private text', $$(SELECT count(*) = 0 FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ('pi_content_analyses', 'pi_policy_decisions', 'pi_session_observations')
  AND column_name IN ('text', 'content', 'body', 'raw_text', 'message', 'ip', 'ip_address', 'raw_ip'))$$);

-- ===================================================================== B. feature flags (all OFF; dependencies; emergency halt)
SELECT pgtest.t('B01 a non-owner cannot change a flag', $$SELECT public.pi_owner_set_flag(pgtest.u(2), 'moderation_analysis', true, 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('B02 a reason is required', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_analysis', true, ' ')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('B03 unknown flag rejected', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'no_such_flag', true, 'x')$$, 'service_role', NULL, 'P0002');
SELECT pgtest.t('B04 enforcement cannot be enabled before analysis', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_enforcement', true, 'x')$$, 'service_role', NULL, '55000');
SELECT pgtest.q('B05 nothing changed after the refused attempts (still all OFF)', $$(SELECT bool_and(NOT enabled) FROM public.pi_feature_flags)$$);
SELECT pgtest.t('B06 owner enables moderation_analysis', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_analysis', true, 'test: enable analysis')$$, 'service_role');
SELECT pgtest.t('B07 enforcement STILL cannot be enabled: the enforcement hooks (migration 003) are not installed', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_enforcement', true, 'x')$$, 'service_role', NULL, '55000');
SELECT pgtest.t('B08 restrictions cannot be enabled before account_risk_scoring', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'account_protective_restrictions', true, 'x')$$, 'service_role', NULL, '55000');
SELECT pgtest.t('B09 owner enables account_risk_scoring', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'account_risk_scoring', true, 'test: enable scoring')$$, 'service_role');
SELECT pgtest.t('B10 restrictions STILL cannot be enabled (hooks not installed)', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'account_protective_restrictions', true, 'x')$$, 'service_role', NULL, '55000');
SELECT pgtest.t('B11 auto_verification cannot be enabled before verification_evaluation', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'auto_verification', true, 'x')$$, 'service_role', NULL, '55000');
SELECT pgtest.t('B12 owner enables verification_evaluation', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'verification_evaluation', true, 'test: enable evaluation')$$, 'service_role');
SELECT pgtest.t('B13 owner enables message scanning (analysis is on)', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_message_scanning', true, 'test')$$, 'service_role');
SELECT pgtest.t('B14 switching analysis OFF ...', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_analysis', false, 'test cascade')$$, 'service_role');
SELECT pgtest.q('B15 ... also switches message scanning off (nothing stays on without its foundation)', $$(SELECT NOT enabled FROM public.pi_feature_flags WHERE key = 'moderation_message_scanning')$$);
SELECT pgtest.t('B16 analysis back on', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_analysis', true, 'test: enable analysis again')$$, 'service_role');
SELECT pgtest.t('B17 owner enables auto_verification', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'auto_verification', true, 'test: delegate')$$, 'service_role');
SELECT pgtest.t('B18 switching verification_evaluation OFF ...', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'verification_evaluation', false, 'test cascade')$$, 'service_role');
SELECT pgtest.q('B19 ... also switches auto_verification off', $$(SELECT NOT enabled FROM public.pi_feature_flags WHERE key = 'auto_verification')$$);
SELECT pgtest.t('B20 verification_evaluation back on (auto_verification stays OFF until a test needs it)', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'verification_evaluation', true, 'test: enable evaluation again')$$, 'service_role');
SELECT pgtest.t('B21 emergency halt on', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', true, 'test: halt')$$, 'service_role');
SELECT pgtest.q('B22 while halted every other flag reads as OFF and automation is halted', $$public.pi_automation_halted() AND NOT public.pi_flag_on('moderation_analysis') AND NOT public.pi_flag_on('account_risk_scoring')
  AND (public.pi_get_runtime_config() ->> 'halted')::boolean$$);
SELECT pgtest.t('B23 emergency halt off', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', false, 'test: resume')$$, 'service_role');
SELECT pgtest.q('B24 after resuming, the flags work again', $$NOT public.pi_automation_halted() AND public.pi_flag_on('moderation_analysis') AND public.pi_flag_on('account_risk_scoring') AND public.pi_flag_on('verification_evaluation')$$);
SELECT pgtest.q('B25 every flag change is in the append-only audit log with its reason', $$(SELECT count(*) >= 10 FROM public.pi_audit_log WHERE action = 'feature_flag_changed' AND actor_type = 'owner' AND reason IS NOT NULL)$$);

-- ===================================================================== C. policies (thresholds, human-review rule, version history)
SELECT pgtest.t('C01 a non-owner cannot change a policy', $$SELECT public.pi_owner_update_policy(pgtest.u(2), 'spam_scams', true, 0.5, 0.8, 'hide_pending_review', NULL, 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('C02 a reason is required', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'spam_scams', true, 0.5, 0.8, 'hide_pending_review', NULL, '')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('C03 unknown category rejected', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'nope', true, 0.5, 0.8, 'flag', NULL, 'x')$$, 'service_role', NULL, 'P0002');
SELECT pgtest.t('C04 a serious category (threats_violence) can NOT be switched off from human review', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'threats_violence', true, 0.4, 0.6, 'flag', false, 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('C05 a severe automatic action cannot be configured (ban)', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'spam_scams', true, 0.5, 0.8, 'ban', NULL, 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('C06 a severe automatic action cannot be configured (remove_content)', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'spam_scams', true, 0.5, 0.8, 'remove_content', NULL, 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('C07 the automatic threshold may not be below the review threshold', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'spam_scams', true, 0.8, 0.5, 'flag', NULL, 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('C08 an enabled policy needs a review threshold', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'dangerous_prohibited', true, NULL, NULL, 'none', NULL, 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.q('C09 the refused changes left every policy at version 1 and disabled', $$(SELECT bool_and(version = 1 AND NOT enabled) FROM public.pi_policies)$$);
SELECT pgtest.t('C10 owner enables spam_scams (hide_pending_review at most)', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'spam_scams', true, 0.5, 0.8, 'hide_pending_review', NULL, 'test: enable spam policy')$$, 'service_role');
SELECT pgtest.q('C11 the change bumped the version and snapshotted it', $$(SELECT p.version = 2 AND p.updated_by = pgtest.u(1) FROM public.pi_policies p WHERE p.category = 'spam_scams')
  AND EXISTS (SELECT 1 FROM public.pi_policy_versions v WHERE v.category = 'spam_scams' AND v.version = 2 AND v.enabled AND v.max_auto_action = 'hide_pending_review' AND v.changed_by = pgtest.u(1))
  AND EXISTS (SELECT 1 FROM public.pi_policy_versions v WHERE v.category = 'spam_scams' AND v.version = 1 AND NOT v.enabled)$$);
SELECT pgtest.t('C12 owner enables threats_violence (serious: stays always-human-review)', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'threats_violence', true, 0.4, 0.6, 'hide_pending_review', NULL, 'test: enable threats policy')$$, 'service_role');
SELECT pgtest.q('C13 threats_violence still requires human review', $$(SELECT always_human_review FROM public.pi_policies WHERE category = 'threats_violence')$$);
SELECT pgtest.t('C14 owner enables harassment_bullying with a warn ceiling', $$SELECT public.pi_owner_update_policy(pgtest.u(1), 'harassment_bullying', true, 0.5, 0.9, 'warn', NULL, 'test: enable harassment policy')$$, 'service_role');
SELECT pgtest.t('C15 policy history cannot be edited', $$UPDATE public.pi_policy_versions SET enabled = false WHERE category = 'spam_scams'$$, NULL, NULL, '42501');
SELECT pgtest.t('C16 policy history cannot be deleted', $$DELETE FROM public.pi_policy_versions WHERE category = 'spam_scams'$$, NULL, NULL, '42501');
SELECT pgtest.t('C17 policy history cannot be truncated', $$TRUNCATE public.pi_policy_versions$$, NULL, NULL, '42501');
SELECT pgtest.q('C18 policy changes are audited with before / after', $$(SELECT count(*) >= 3 FROM public.pi_audit_log WHERE action = 'policy_changed' AND before_state IS NOT NULL AND after_state IS NOT NULL)$$);

-- ===================================================================== D. rule sets (versioned, validated, immutable)
SELECT pgtest.q('D01 before any publish there is no stored rule set (built-in version 1 lives in the server code)', $$(SELECT count(*) = 0 FROM public.pi_rule_sets) AND public.pi_get_active_rules('worker_settings') IS NULL$$);
SELECT pgtest.t('D02 a non-owner cannot publish', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(2), 'worker_settings', '{"tick_seconds":30,"batch_size":10,"scan_batch":100,"assess_interval_minutes":30}'::jsonb, 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('D03 a note is required', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'worker_settings', '{"tick_seconds":30,"batch_size":10,"scan_batch":100,"assess_interval_minutes":30}'::jsonb, '')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D04 unknown rule set rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'whatever', '{}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D05 out-of-range value rejected (tick_seconds 1)', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'worker_settings', '{"tick_seconds":1,"batch_size":10,"scan_batch":100,"assess_interval_minutes":30}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D06 missing field rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'worker_settings', '{"tick_seconds":30}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D07 non-object config rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'worker_settings', '[1,2]'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D08 moderation rules: unknown custom-term category rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'moderation_rules', '{"hold_hours":24,"min_confidence_auto":0.6,"max_text_length":5000,"custom_terms":{"lasers":[{"term":"abc","weight":0.5}]}}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D09 moderation rules: hold longer than 72 hours rejected (holds must stay temporary)', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'moderation_rules', '{"hold_hours":500,"min_confidence_auto":0.6,"max_text_length":5000}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D10 moderation rules: bad custom term weight rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'moderation_rules', '{"hold_hours":24,"min_confidence_auto":0.6,"max_text_length":5000,"custom_terms":{"spam_scams":[{"term":"abc","weight":7}]}}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D11 account rules: thresholds must ascend', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'account_risk_rules', '{"level_thresholds":{"medium":0.6,"high":0.5,"critical":0.9},"restriction_hours":24}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D12 account rules: restriction longer than 72 hours rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'account_risk_rules', '{"level_thresholds":{"medium":0.3,"high":0.5,"critical":0.8},"restriction_hours":200}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D13 verification criteria: unknown check type rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'verification_criteria', '{"checks":[{"id":"a1","type":"read_minds","required":true}]}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D14 verification criteria: duplicate check id rejected', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'verification_criteria', '{"checks":[{"id":"a1","type":"profile_complete","required":true},{"id":"a1","type":"good_standing","required":true}]}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('D15 verification criteria: a check must say whether it is required', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'verification_criteria', '{"checks":[{"id":"a1","type":"profile_complete"}]}'::jsonb, 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.q('D16 nothing was stored by the rejected publishes', $$(SELECT count(*) = 0 FROM public.pi_rule_sets)$$);
SELECT pgtest.t('D17 owner publishes worker_settings', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'worker_settings', '{"tick_seconds":30,"batch_size":10,"scan_batch":100,"assess_interval_minutes":30}'::jsonb, 'test: first publish')$$, 'service_role');
SELECT pgtest.q('D18 it is version 2 (version 1 is the built-in default) and active', $$(SELECT version = 2 AND status = 'active' AND created_by = pgtest.u(1) FROM public.pi_rule_sets WHERE rule_key = 'worker_settings')
  AND (public.pi_get_active_rules('worker_settings') ->> 'version')::int = 2$$);
SELECT pgtest.t('D19 owner publishes worker_settings again', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'worker_settings', '{"tick_seconds":20,"batch_size":5,"scan_batch":100,"assess_interval_minutes":30}'::jsonb, 'test: second publish')$$, 'service_role');
SELECT pgtest.q('D20 version 3 is active, version 2 retired; exactly one active', $$(SELECT count(*) FILTER (WHERE status = 'active') = 1 AND count(*) = 2 AND max(version) FILTER (WHERE status = 'active') = 3
  AND bool_and(status = 'retired' OR version = 3) FROM public.pi_rule_sets WHERE rule_key = 'worker_settings') AND (public.pi_get_active_rules('worker_settings') #>> '{config,tick_seconds}')::int = 20$$);
SELECT pgtest.t('D21 a published version cannot be edited', $$UPDATE public.pi_rule_sets SET config = '{"x":1}'::jsonb WHERE rule_key = 'worker_settings' AND version = 2$$, NULL, NULL, '42501');
SELECT pgtest.t('D22 a published version cannot be deleted', $$DELETE FROM public.pi_rule_sets WHERE rule_key = 'worker_settings'$$, NULL, NULL, '42501');
SELECT pgtest.t('D23 a retired version cannot be re-activated', $$UPDATE public.pi_rule_sets SET status = 'active', retired_at = NULL WHERE rule_key = 'worker_settings' AND version = 2$$, NULL, NULL, '42501');
SELECT pgtest.t('D24 rule sets cannot be truncated', $$TRUNCATE public.pi_rule_sets$$, NULL, NULL, '42501');
SELECT pgtest.t('D25 owner publishes moderation rules with custom terms', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'moderation_rules', '{"hold_hours":12,"min_confidence_auto":0.6,"max_text_length":5000,"custom_terms":{"spam_scams":[{"term":"free crypto","weight":0.9}]}}'::jsonb, 'test: custom terms')$$, 'service_role');
SELECT pgtest.t('D26 owner publishes verification criteria', $$SELECT public.pi_owner_publish_rule_set(pgtest.u(1), 'verification_criteria', '{"checks":[{"id":"age","type":"min_account_age_days","required":true,"value":7},{"id":"prof","type":"profile_complete","required":true}]}'::jsonb, 'test: criteria')$$, 'service_role');
SELECT pgtest.q('D27 runtime config lists the active rule sets', $$(SELECT count(*) = 3 FROM jsonb_object_keys(public.pi_get_runtime_config() -> 'rule_sets'))$$);
SELECT pgtest.q('D28 every publish is audited', $$(SELECT count(*) = 4 FROM public.pi_audit_log WHERE action = 'rule_set_published')$$);

-- ===================================================================== E. session beacon + security events (keyed hashes only)
-- (account_risk_scoring is ON from section B)
SELECT pgtest.q('E01 a first session is recorded as a new IP and a new device', $$(public.pi_record_session(pgtest.u(5), repeat('a', 64), repeat('b', 64)) ->> 'recorded')::boolean$$, 'service_role');
SELECT pgtest.qa('E02 the same session again is NOT new and is counted', $$public.pi_record_session(pgtest.u(5), repeat('a', 64), repeat('b', 64))$$,
  $$(pgtest.lastj() ->> 'new_ip')::boolean = false AND (pgtest.lastj() ->> 'new_device')::boolean = false AND (SELECT seen_count = 2 FROM public.pi_session_observations WHERE user_id = pgtest.u(5) AND ip_hash = repeat('a', 64) AND device_hash = repeat('b', 64))$$, 'service_role');
SELECT pgtest.q('E03 a second device for the same user is reported as new', $$(SELECT (r ->> 'new_device')::boolean AND (r ->> 'devices_24h')::int = 2 FROM (SELECT public.pi_record_session(pgtest.u(5), repeat('a', 64), repeat('c', 64)) r) s)$$, 'service_role');
SELECT pgtest.qa('E04 a second account on the same device is visible as a shared-device signal', $$public.pi_record_session(pgtest.u(6), repeat('a', 64), repeat('b', 64))$$,
  $$(pgtest.lastj() ->> 'users_on_device_7d')::int = 2 AND (public.pi_user_activity_summary(pgtest.u(5)) ->> 'shared_device_accounts_7d')::int >= 1$$, 'service_role');
SELECT pgtest.t('E05 a raw IP address is refused (hashes only)', $$SELECT public.pi_record_session(pgtest.u(5), '203.0.113.5', repeat('b', 64))$$, 'service_role', NULL, '23514');
SELECT pgtest.t('E06 a malformed device hash is refused', $$SELECT public.pi_record_session(pgtest.u(5), repeat('a', 64), 'not-a-hash')$$, 'service_role', NULL, '23514');
SELECT pgtest.q('E07 an unknown account is ignored, not stored', $$(public.pi_record_session(pgtest.u(99), repeat('a', 64), repeat('b', 64)) ->> 'recorded')::boolean = false AND NOT EXISTS (SELECT 1 FROM public.pi_session_observations WHERE user_id = pgtest.u(99))$$, 'service_role');
SELECT pgtest.t('E08 signed-in users cannot call the beacon function directly', $$SELECT public.pi_record_session(pgtest.u(2), repeat('a', 64), repeat('b', 64))$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.q('E09 security event: first insert returns an id, the same dedupe key returns NULL', $$(SELECT a IS NOT NULL AND b IS NULL FROM (SELECT public.pi_add_security_event('{"user_id":"00000000-0000-0000-0000-000000000005","event_type":"mass_follow","severity":"medium","source":"bmn_rules","dedupe_key":"t:e9"}'::jsonb) a,
  public.pi_add_security_event('{"user_id":"00000000-0000-0000-0000-000000000005","event_type":"mass_follow","severity":"medium","source":"bmn_rules","dedupe_key":"t:e9"}'::jsonb) b) s)$$, 'service_role');
SELECT pgtest.t('E10 an invented event type is refused', $$SELECT public.pi_add_security_event('{"user_id":"00000000-0000-0000-0000-000000000005","event_type":"mind_reading","severity":"low","source":"x"}'::jsonb)$$, 'service_role', NULL, '23514');
SELECT pgtest.q('E11 the activity summary reports counts for an account', $$(SELECT (s ->> 'account_exists')::boolean AND (s ->> 'follows_24h')::int = 0 AND (s ->> 'posts_24h')::int = 0 AND (s ->> 'verified')::boolean = false AND s ->> 'account_status' = 'active' FROM (SELECT public.pi_user_activity_summary(pgtest.u(5)) s) x)$$);
SELECT pgtest.t('E12 while scoring is off, beacon and events record nothing', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'account_risk_scoring', false, 'test off')$$, 'service_role');
SELECT pgtest.q('E13 (scoring off) beacon returns recorded=false and event returns NULL', $$(public.pi_record_session(pgtest.u(7), repeat('d', 64), repeat('e', 64)) ->> 'recorded')::boolean = false
  AND public.pi_add_security_event('{"user_id":"00000000-0000-0000-0000-000000000007","event_type":"mass_follow","severity":"low","source":"x"}'::jsonb) IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.pi_session_observations WHERE user_id = pgtest.u(7))$$, 'service_role');
SELECT pgtest.t('E14 scoring back on', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'account_risk_scoring', true, 'test on')$$, 'service_role');

-- ===================================================================== F. sweepers (new activity -> idempotent queued jobs; no back-fill; messages only when allowed)
SELECT pgtest.t('F00 analysis ON for the sweepers (halt is off)', $$SELECT 1$$);
SELECT pgtest.t('F01 sweeper limit validated', $$SELECT public.pi_enqueue_new_content(0)$$, 'service_role', NULL, '22023');
SELECT pgtest.qa('F02 first sweep creates the cursors at "now": existing history is NOT back-filled', $$public.pi_enqueue_new_content(200)$$,
  $$(pgtest.lastj() #>> '{}')::int = 0 AND (SELECT count(*) = 5 FROM public.pi_scan_cursors) AND (SELECT count(*) = 0 FROM public.pi_jobs WHERE job_type = 'analyze_content')$$, 'service_role');
-- move cursors back to just before the test content (as if the worker had been off for an hour)
UPDATE public.pi_scan_cursors SET last_created_at = now() - interval '1 hour', last_id = NULL;
INSERT INTO public.posts (id, user_id, title, caption, status, created_at) VALUES
  (pgtest.u(9101), pgtest.u(5), 'Sweep post A', 'hello world', 'published', now() - interval '30 minutes'),
  (pgtest.u(9102), pgtest.u(5), 'Sweep draft', 'not published', 'draft', now() - interval '29 minutes');
INSERT INTO public.comments (id, user_id, post_id, body, content, created_at) VALUES
  (pgtest.u(9201), pgtest.u(5), pgtest.u(9101), 'sweep comment', 'sweep comment', now() - interval '28 minutes');
INSERT INTO public.messages (id, sender_id, recipient_id, content, created_at) VALUES
  (pgtest.u(9301), pgtest.u(5), pgtest.u(6), 'private hello', now() - interval '27 minutes');
INSERT INTO public.content_reports (id, reporter_id, post_id, reported_user_id, reason, details, created_at) VALUES
  (pgtest.u(9401), pgtest.u(6), pgtest.u(9101), pgtest.u(5), 'spam', 'sweep report', now() - interval '26 minutes');
SELECT pgtest.qa('F03 the sweep queues new posts, comments and reports (and not drafts or messages)', $$public.pi_enqueue_new_content(200)$$,
  $$(pgtest.lastj() #>> '{}')::int >= 3
  AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'analyze:post:' || pgtest.u(9101)::text)
  AND NOT EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'analyze:post:' || pgtest.u(9102)::text)
  AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'analyze:comment:' || pgtest.u(9201)::text)
  AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'analyze:report:' || pgtest.u(9401)::text AND priority = 2)$$, 'service_role');
SELECT pgtest.q('F04 private messages are NOT queued while message scanning is off', $$NOT EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'analyze:message:' || pgtest.u(9301)::text)$$);
SELECT pgtest.q('F05 queued jobs carry only ids, never text', $$(SELECT bool_and(NOT (payload::text ~* '(hello|private|caption)')) FROM public.pi_jobs WHERE job_type = 'analyze_content')$$);
SELECT pgtest.q('F06 a second sweep adds nothing (cursors advanced)', $$public.pi_enqueue_new_content(200) = 0$$, 'service_role');
SELECT pgtest.q('F07 the report job carries the report reason for the engine', $$(SELECT payload ->> 'source' = 'user_report' AND payload ->> 'subject_type' = 'post' FROM public.pi_jobs WHERE idempotency_key = 'analyze:report:' || pgtest.u(9401)::text)$$);
SELECT pgtest.t('F08 enable message scanning', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_message_scanning', true, 'test scanning')$$, 'service_role');
UPDATE public.pi_scan_cursors SET last_created_at = now() - interval '1 hour', last_id = NULL WHERE source = 'messages';
SELECT pgtest.qa('F09 with scanning on, the message is queued', $$public.pi_enqueue_new_content(200)$$,
  $$(pgtest.lastj() #>> '{}')::int >= 1 AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'analyze:message:' || pgtest.u(9301)::text)$$, 'service_role');
SELECT pgtest.qa('F09b ... and only once', $$public.pi_enqueue_new_content(200)$$, $$(pgtest.lastj() #>> '{}')::int = 0$$, 'service_role');
SELECT pgtest.t('F10 disable message scanning again', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'moderation_message_scanning', false, 'test scanning off')$$, 'service_role');
SELECT pgtest.qa('F11 with scanning off the messages cursor follows "now" (no later back-fill of private messages)', $$public.pi_enqueue_new_content(200)$$,
  $$(pgtest.lastj() #>> '{}')::int = 0 AND (SELECT last_created_at > now() - interval '1 minute' FROM public.pi_scan_cursors WHERE source = 'messages')$$, 'service_role');
SELECT pgtest.qa('F12 the account sweep queues recently active accounts', $$public.pi_enqueue_account_assessments(100)$$,
  $$(pgtest.lastj() #>> '{}')::int >= 1 AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE job_type = 'assess_account' AND payload ->> 'user_id' = pgtest.u(5)::text)$$, 'service_role');
SELECT pgtest.qa('F12b ... once per interval (a second sweep adds nothing)', $$public.pi_enqueue_account_assessments(100)$$, $$(pgtest.lastj() #>> '{}')::int = 0$$, 'service_role');
SELECT pgtest.t('F13 account sweep limit validated', $$SELECT public.pi_enqueue_account_assessments(5000)$$, 'service_role', NULL, '22023');
INSERT INTO public.bmn_verification_requests (id, user_id, request_reason) VALUES
  (pgtest.u(9501), pgtest.u(5), 'I am a public creator and would like my account verified please.');
SELECT pgtest.qa('F14 the verification sweep queues pending, not-yet-evaluated requests', $$public.pi_enqueue_verification_evaluations(50)$$,
  $$(pgtest.lastj() #>> '{}')::int >= 1 AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'verify:' || pgtest.u(9501)::text)$$, 'service_role');
SELECT pgtest.qa('F14b ... once', $$public.pi_enqueue_verification_evaluations(50)$$, $$(pgtest.lastj() #>> '{}')::int = 0$$, 'service_role');
SELECT pgtest.t('F15 halting stops every sweeper', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', true, 'test halt')$$, 'service_role');
SELECT pgtest.q('F16 (halted) sweepers return 0', $$public.pi_enqueue_new_content(10) = 0 AND public.pi_enqueue_account_assessments(10) = 0 AND public.pi_enqueue_verification_evaluations(10) = 0$$, 'service_role');
SELECT pgtest.t('F17 resume', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', false, 'test resume')$$, 'service_role');

-- ===================================================================== G. content moderation commits (shadow mode, policy limits, idempotency)
SELECT pgtest.t('G01 signed-in users cannot commit analysis results', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g1', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'clear', 'no_action'))$$, 'authenticated', pgtest.u(5), '42501');
SELECT pgtest.t('G02 an idempotency key is required', $$SELECT public.pi_commit_moderation_result(pgtest.mp('', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'clear', 'no_action'))$$, 'service_role', NULL, '22023');
SELECT pgtest.qa('G03 a clear result is recorded with an analysis + decision, and NO case or action', $$public.pi_commit_moderation_result(pgtest.mp('g3', 'post', pgtest.u(9101), pgtest.u(5), NULL, 'clear', 'no_action'))$$,
  $$(pgtest.lastj() ->> 'duplicate')::boolean = false AND pgtest.lastj() ->> 'case_id' IS NULL AND pgtest.lastj() ->> 'action_id' IS NULL AND pgtest.lastj() ->> 'decision_id' IS NOT NULL
  AND (SELECT count(*) = 1 FROM public.pi_content_analyses WHERE idempotency_key = 'g3') AND (SELECT count(*) = 1 FROM public.pi_policy_decisions WHERE idempotency_key = 'decision:g3')
  AND NOT EXISTS (SELECT 1 FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9101))$$, 'service_role');
SELECT pgtest.qa('G04 the same key again is a duplicate and writes nothing', $$public.pi_commit_moderation_result(pgtest.mp('g3', 'post', pgtest.u(9101), pgtest.u(5), NULL, 'clear', 'no_action'))$$,
  $$(pgtest.lastj() ->> 'duplicate')::boolean AND (SELECT count(*) = 1 FROM public.pi_content_analyses WHERE idempotency_key = 'g3') AND (SELECT count(*) = 1 FROM public.pi_policy_decisions WHERE idempotency_key = 'decision:g3')$$, 'service_role');
SELECT pgtest.q('G05 the analysis row stores a hash, never the text', $$(SELECT content_hash ~ '^[0-9a-f]{64}$' AND content_length = 50 FROM public.pi_content_analyses WHERE idempotency_key = 'g3')$$);
SELECT pgtest.qa('G06 spam hold in SHADOW mode: case + action + decision recorded; the action expires in about 24 hours', $$public.pi_commit_moderation_result(pgtest.mp('g6', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'hide_pending_review'))$$,
  $$pgtest.lastj() ->> 'case_id' IS NOT NULL AND pgtest.lastj() ->> 'action_id' IS NOT NULL AND pgtest.lastj() ->> 'mode' = 'shadow'
  AND (SELECT mode = 'shadow' AND actor_type = 'system' AND action_type = 'hide_pending_review' AND expires_at BETWEEN now() + interval '23 hours' AND now() + interval '25 hours' AND policy_version = 2
        FROM public.pi_moderation_actions WHERE idempotency_key = 'act:g6')
  AND (SELECT mode = 'shadow' AND recommended_action = 'hide_pending_review' AND policy_version = 2 AND policy_category = 'spam_scams' FROM public.pi_policy_decisions WHERE idempotency_key = 'decision:g6')$$, 'service_role');
SELECT pgtest.q('G07 an automatic hold is audited under the system actor', $$(SELECT count(*) = 1 FROM public.pi_audit_log WHERE action = 'content_analysed' AND actor_type = 'system' AND target_id = pgtest.u(9101)::text AND after_state ->> 'mode' = 'shadow' AND after_state ->> 'recommended_action' = 'hide_pending_review')$$);
SELECT pgtest.q('G08 SHADOW MODE CHANGES NOTHING on the platform: the post is still published and no legacy moderation action exists', $$(SELECT status = 'published' FROM public.posts WHERE id = pgtest.u(9101))
  AND (SELECT count(*) = 0 FROM public.moderation_actions)$$);
SELECT pgtest.t('G09 enforced mode is refused (enforcement hooks are not installed)', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g9', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'hide_pending_review', '{"mode":"enforced"}'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('G10 an action stronger than the policy ceiling is refused (restrict > hide)', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g10', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'restrict_temporary'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('G11 an action on a DISABLED policy is refused (hate_speech is off)', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g11', 'post', pgtest.u(9101), pgtest.u(5), 'hate_speech', 'violation_likely', 'flag'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('G12 automation can never recommend a ban', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g12', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'ban'))$$, 'service_role', NULL, '22023');
SELECT pgtest.t('G13 ... nor suspend', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g13', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'suspend'))$$, 'service_role', NULL, '22023');
SELECT pgtest.t('G14 ... nor remove content', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g14', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'remove_content'))$$, 'service_role', NULL, '22023');
SELECT pgtest.t('G15 ... nor revoke verification', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g15', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'revoke_verification'))$$, 'service_role', NULL, '22023');
SELECT pgtest.q('G16 the refused commits left no trace', $$(SELECT count(*) = 0 FROM public.pi_content_analyses WHERE idempotency_key IN ('g9', 'g10', 'g11', 'g12', 'g13', 'g14', 'g15'))$$);
SELECT pgtest.t('G17 even a direct database write cannot give the system a ban (001 constraint)', $$INSERT INTO public.pi_moderation_actions (subject_type, subject_id, action_type, actor_type, mode, user_visible_reason) VALUES ('post', gen_random_uuid(), 'ban', 'system', 'shadow', 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('G18 ... nor a hold with no expiry', $$INSERT INTO public.pi_moderation_actions (subject_type, subject_id, action_type, actor_type, mode) VALUES ('post', gen_random_uuid(), 'hide_pending_review', 'system', 'shadow')$$, 'service_role', NULL, '23514');
SELECT pgtest.qa('G19 a serious category (threats): flag is allowed and ALWAYS goes to a human (status awaiting_review)', $$public.pi_commit_moderation_result(pgtest.mp('g19', 'comment', pgtest.u(9201), pgtest.u(5), 'threats_violence', 'violation_likely', 'flag'))$$,
  $$pgtest.lastj() ->> 'case_id' IS NOT NULL AND (SELECT status = 'awaiting_review' AND requires_human_review FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9201))$$, 'service_role');
SELECT pgtest.t('G20 a serious category cannot be held / warned by automation, only flagged', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g20', 'comment', pgtest.u(9201), pgtest.u(5), 'threats_violence', 'violation_likely', 'hide_pending_review'))$$, 'service_role', NULL, '55000');
SELECT pgtest.qa('G21 a user report always requires a human', $$public.pi_commit_moderation_result(pgtest.mp('g21', 'post', pgtest.u(9102), pgtest.u(5), NULL, 'clear', 'no_action', '{}', '{"source":"user_report"}'))$$,
  $$pgtest.lastj() ->> 'case_id' IS NOT NULL AND (SELECT status = 'awaiting_review' AND requires_human_review AND source = 'user_report' FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9102))$$, 'service_role');
SELECT pgtest.qa('G22 a second analysis of the same subject joins the existing open case (one case, higher risk kept)', $$public.pi_commit_moderation_result(pgtest.mp('g22', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'flag', '{}', '{"risk_score":0.95}'))$$,
  $$pgtest.lastj() ->> 'case_id' = (SELECT id::text FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9101) LIMIT 1)
  AND (SELECT count(*) = 1 FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9101)) AND (SELECT risk_score = 0.95 FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9101))$$, 'service_role');
SELECT pgtest.qa('G23a a hold of 1000 hours is clamped to 72 hours', $$public.pi_commit_moderation_result(pgtest.mp('g23a', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'hide_pending_review', '{"hold_hours":1000}'))$$,
  $$pgtest.lastj() ->> 'action_id' IS NOT NULL AND (SELECT expires_at BETWEEN now() + interval '71 hours' AND now() + interval '73 hours' FROM public.pi_moderation_actions WHERE idempotency_key = 'act:g23a')$$, 'service_role');
SELECT pgtest.qa('G23b a hold of 0 hours is clamped to 1 hour', $$public.pi_commit_moderation_result(pgtest.mp('g23b', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'hide_pending_review', '{"hold_hours":0}'))$$,
  $$pgtest.lastj() ->> 'action_id' IS NOT NULL AND (SELECT expires_at BETWEEN now() + interval '30 minutes' AND now() + interval '90 minutes' FROM public.pi_moderation_actions WHERE idempotency_key = 'act:g23b')$$, 'service_role');
SELECT pgtest.t('G24 private messages are refused while scanning is off', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g24', 'message', pgtest.u(9301), pgtest.u(5), NULL, 'clear', 'no_action'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('G25 an invalid mode is refused', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g25', 'post', pgtest.u(9101), pgtest.u(5), NULL, 'clear', 'no_action', '{"mode":"sneaky"}'))$$, 'service_role', NULL, '22023');
SELECT pgtest.t('G26 emergency halt', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', true, 'test halt')$$, 'service_role');
SELECT pgtest.t('G27 (halted) a commit is refused', $$SELECT public.pi_commit_moderation_result(pgtest.mp('g27', 'post', pgtest.u(9101), pgtest.u(5), NULL, 'clear', 'no_action'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('G28 resume', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', false, 'test resume')$$, 'service_role');
SELECT pgtest.q('G29 automation has taken NO enforced action anywhere so far (violation count 0 for every user)', $$(SELECT count(*) = 0 FROM public.pi_moderation_actions WHERE actor_type = 'system' AND mode = 'enforced')
  AND public.pi_violation_count(pgtest.u(5), interval '90 days') = 0$$);
SELECT pgtest.q('G30 every automated decision names the policy version and rule-set version it used', $$(SELECT bool_and(rule_set_version IS NOT NULL AND rule_set_key = 'moderation_rules') FROM public.pi_policy_decisions WHERE decision_kind = 'content_moderation')$$);
SELECT pgtest.t('G31 a recorded decision can not be edited', $$UPDATE public.pi_policy_decisions SET outcome = 'tampered' WHERE idempotency_key = 'decision:g3'$$, NULL, NULL, '42501');
SELECT pgtest.t('G32 ... nor deleted', $$DELETE FROM public.pi_policy_decisions WHERE idempotency_key = 'decision:g3'$$, NULL, NULL, '42501');
SELECT pgtest.t('G33 ... nor truncated', $$TRUNCATE public.pi_policy_decisions$$, NULL, NULL, '42501');
SELECT pgtest.t('G34 a decision can never record a ban as its recommendation (table constraint)', $$INSERT INTO public.pi_policy_decisions (decision_kind, subject_type, subject_id, outcome, recommended_action, mode) VALUES ('content_moderation', 'post', gen_random_uuid(), 'x', 'ban', 'shadow')$$, NULL, NULL, '23514');

-- ===================================================================== H. temporary holds expire and are escalated, never forgotten
SELECT pgtest.q('H01 setup: a standing automatic hold for case review', $$(SELECT r ->> 'action_id' IS NOT NULL FROM (SELECT public.pi_commit_moderation_result(pgtest.mp('h1', 'post', pgtest.u(9101), pgtest.u(5), 'spam_scams', 'violation_likely', 'hide_pending_review')) r) s)$$, 'service_role');
-- make the holds already past their expiry (the immutability trigger is paused ONLY for this test setup, then restored)
ALTER TABLE public.pi_moderation_actions DISABLE TRIGGER pi_actions_immutable;
UPDATE public.pi_moderation_actions SET expires_at = now() - interval '1 minute' WHERE idempotency_key IN ('act:g6', 'act:h1');
ALTER TABLE public.pi_moderation_actions ENABLE TRIGGER pi_actions_immutable;
INSERT INTO public.pi_protective_restrictions (user_id, restriction_type, reason_code, actor_type, mode, starts_at, expires_at)
  VALUES (pgtest.u(17), 'limit_posting', 'test', 'system', 'shadow', now() - interval '3 hours', now() - interval '1 minute'),
         (pgtest.u(17), 'limit_follows', 'test', 'system', 'shadow', now() - interval '1 hour', now() + interval '5 hours');
SELECT pgtest.q('H02 expiry ends the lapsed holds and restrictions, and only those', $$(SELECT (r ->> 'holds_ended')::int >= 2 AND (r ->> 'restrictions_lifted')::int = 1 FROM (SELECT public.pi_expire_automated() r) s)$$, 'service_role');
SELECT pgtest.q('H03 ended holds are marked reversed with a reason; each queues a reversal job', $$(SELECT bool_and(reversed_at IS NOT NULL AND reversal_reason LIKE 'expired automatically%') FROM public.pi_moderation_actions WHERE idempotency_key IN ('act:g6', 'act:h1'))
  AND (SELECT count(*) = 2 FROM public.pi_jobs WHERE job_type = 'reverse_action' AND payload ->> 'expired' = 'true')$$);
SELECT pgtest.q('H04 the still-valid restriction was left alone, the lapsed one lifted', $$(SELECT lifted_at IS NULL FROM public.pi_protective_restrictions WHERE restriction_type = 'limit_follows' AND user_id = pgtest.u(17))
  AND (SELECT lifted_at IS NOT NULL AND lift_reason = 'expired automatically' FROM public.pi_protective_restrictions WHERE restriction_type = 'limit_posting' AND user_id = pgtest.u(17))$$);
SELECT pgtest.q('H05 a case whose hold lapsed is escalated to the top of the review queue and an alert is raised', $$(SELECT priority = 1 AND status = 'awaiting_review' AND requires_human_review FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9101))
  AND EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE kind = 'hold_expired_unreviewed' AND resolved_at IS NULL)$$);
SELECT pgtest.q('H06 expiry is audited', $$(SELECT count(*) >= 1 FROM public.pi_audit_log WHERE action = 'automated_holds_expired' AND actor_type = 'system')$$);
SELECT pgtest.q('H07 running expiry again changes nothing (idempotent)', $$(SELECT (r ->> 'holds_ended')::int = 0 AND (r ->> 'restrictions_lifted')::int = 0 FROM (SELECT public.pi_expire_automated() r) s)$$, 'service_role');
SELECT pgtest.t('H08 a reversed hold cannot be un-reversed', $$UPDATE public.pi_moderation_actions SET reversed_at = NULL WHERE idempotency_key = 'act:g6'$$, NULL, NULL, '42501');
SELECT pgtest.t('H09 signed-in users cannot trigger expiry', $$SELECT public.pi_expire_automated()$$, 'authenticated', pgtest.u(2), '42501');

-- ===================================================================== I. account assessments, investigations, protective restrictions
SELECT pgtest.t('I01 signed-in users cannot commit assessments', $$SELECT public.pi_commit_account_assessment(pgtest.ap('i1', pgtest.u(6), 'low'))$$, 'authenticated', pgtest.u(6), '42501');
SELECT pgtest.qa('I02 a low assessment is stored, no investigation, no restriction, no alert', $$public.pi_commit_account_assessment(pgtest.ap('i2', pgtest.u(6), 'low'))$$,
  $$pgtest.lastj() ->> 'assessment_id' IS NOT NULL AND pgtest.lastj() ->> 'investigation_id' IS NULL AND (pgtest.lastj() ->> 'restrictions_created')::int = 0
  AND (SELECT count(*) = 1 FROM public.pi_account_risk_assessments WHERE user_id = pgtest.u(6)) AND NOT EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE dedupe_key = 'account_risk:' || pgtest.u(6)::text)$$, 'service_role');
SELECT pgtest.qa('I03 medium: investigation opened, 2 events, 1 SHADOW restriction that expires in 24h; nothing enforced', $$public.pi_commit_account_assessment(pgtest.ap('i3', pgtest.u(6), 'medium', '{"recommended_action":"restrict_temporary"}',
    '{"open_investigation":true,"events":[{"event_type":"mass_follow","severity":"medium","dedupe_key":"i3:e1"},{"event_type":"spam_burst","severity":"low","dedupe_key":"i3:e2"}],"restrictions":[{"restriction_type":"limit_follows","reason_code":"mass_follow","hours":24}]}'))$$,
  $$pgtest.lastj() ->> 'investigation_id' IS NOT NULL AND (pgtest.lastj() ->> 'restrictions_created')::int = 1 AND (pgtest.lastj() ->> 'events_created')::int = 2 AND pgtest.lastj() ->> 'mode' = 'shadow'
  AND (SELECT mode = 'shadow' AND actor_type = 'system' AND expires_at BETWEEN now() + interval '23 hours' AND now() + interval '25 hours' FROM public.pi_protective_restrictions WHERE user_id = pgtest.u(6) AND restriction_type = 'limit_follows')$$, 'service_role');
SELECT pgtest.q('I04 the new assessment is the only current one and is explainable', $$(SELECT count(*) FILTER (WHERE is_current) = 1 AND bool_and(cardinality(reason_codes) > 0 OR risk_level = 'low') FROM public.pi_account_risk_assessments WHERE user_id = pgtest.u(6))
  AND (SELECT risk_level = 'medium' FROM public.pi_account_risk_assessments WHERE user_id = pgtest.u(6) AND is_current)$$);
SELECT pgtest.qa('I05 the same key again is a duplicate and writes nothing', $$public.pi_commit_account_assessment(pgtest.ap('i3', pgtest.u(6), 'medium'))$$,
  $$(pgtest.lastj() ->> 'duplicate')::boolean AND (SELECT count(*) = 2 FROM public.pi_account_risk_assessments WHERE user_id = pgtest.u(6)) AND (SELECT count(*) = 1 FROM public.pi_investigations WHERE user_id = pgtest.u(6))$$, 'service_role');
SELECT pgtest.qa('I06 a second medium assessment reuses the open investigation and does not duplicate the restriction', $$public.pi_commit_account_assessment(pgtest.ap('i6', pgtest.u(6), 'medium', '{}', '{"open_investigation":true,"restrictions":[{"restriction_type":"limit_follows","reason_code":"mass_follow","hours":24}]}'))$$,
  $$(pgtest.lastj() ->> 'investigation_id')::uuid = (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)) AND (pgtest.lastj() ->> 'restrictions_created')::int = 0
  AND (SELECT count(*) = 1 FROM public.pi_investigations WHERE user_id = pgtest.u(6)) AND (SELECT count(*) = 1 FROM public.pi_protective_restrictions WHERE user_id = pgtest.u(6) AND restriction_type = 'limit_follows')$$, 'service_role');
SELECT pgtest.qa('I07 high risk raises an alert, raises investigation severity and adds a note', $$public.pi_commit_account_assessment(pgtest.ap('i7', pgtest.u(6), 'high', '{}', '{"open_investigation":true}'))$$,
  $$pgtest.lastj() ->> 'assessment_id' IS NOT NULL AND (SELECT severity = 'high' FROM public.pi_investigations WHERE user_id = pgtest.u(6))
  AND EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE dedupe_key = 'account_risk:' || pgtest.u(6)::text AND resolved_at IS NULL AND severity = 'high')
  AND (SELECT count(*) >= 2 FROM public.pi_investigation_notes n JOIN public.pi_investigations i ON i.id = n.investigation_id WHERE i.user_id = pgtest.u(6))$$, 'service_role');
SELECT pgtest.qa('I08 a later LOW assessment clears the alert (risk can fall)', $$public.pi_commit_account_assessment(pgtest.ap('i8', pgtest.u(6), 'low'))$$,
  $$pgtest.lastj() ->> 'assessment_id' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE dedupe_key = 'account_risk:' || pgtest.u(6)::text AND resolved_at IS NULL)
  AND (SELECT count(*) FILTER (WHERE is_current) = 1 FROM public.pi_account_risk_assessments WHERE user_id = pgtest.u(6))$$, 'service_role');
SELECT pgtest.t('I09 a medium assessment with no reason is refused (no unexplained risk)', $$SELECT public.pi_commit_account_assessment(pgtest.ap('i9', pgtest.u(6), 'medium', '{}', '{"reason_codes":[]}'))$$, 'service_role', NULL, '23514');
SELECT pgtest.t('I10 enforced restrictions are refused (hooks not installed)', $$SELECT public.pi_commit_account_assessment(pgtest.ap('i10', pgtest.u(6), 'medium', '{"mode":"enforced"}'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('I11 automation cannot recommend a suspension of an account', $$SELECT public.pi_commit_account_assessment(pgtest.ap('i11', pgtest.u(6), 'critical', '{"recommended_action":"suspend"}'))$$, 'service_role', NULL, '22023');
SELECT pgtest.t('I12 automation cannot recommend a ban either', $$SELECT public.pi_commit_account_assessment(pgtest.ap('i12', pgtest.u(6), 'critical', '{"recommended_action":"ban"}'))$$, 'service_role', NULL, '22023');
SELECT pgtest.q('I13 an unknown account is skipped', $$(SELECT (r ->> 'skipped')::boolean FROM (SELECT public.pi_commit_account_assessment(pgtest.ap('i13', pgtest.u(98), 'low')) r) s)$$, 'service_role');
SELECT pgtest.qa('I14 restriction hours are clamped to at most 72', $$public.pi_commit_account_assessment(pgtest.ap('i14', pgtest.u(7), 'medium', '{}', '{"restrictions":[{"restriction_type":"limit_posting","reason_code":"x","hours":9999}]}'))$$,
  $$(pgtest.lastj() ->> 'restrictions_created')::int = 1 AND (SELECT expires_at BETWEEN now() + interval '71 hours' AND now() + interval '73 hours' FROM public.pi_protective_restrictions WHERE user_id = pgtest.u(7))$$, 'service_role');
SELECT pgtest.q('I15 no restriction anywhere is open-ended or enforced', $$(SELECT bool_and(expires_at IS NOT NULL AND mode = 'shadow') FROM public.pi_protective_restrictions)$$);
SELECT pgtest.q('I16 account assessments never touch the account itself (no moderation status, no verification change)', $$(SELECT count(*) = 0 FROM public.bmn_user_moderation) AND (SELECT count(*) = 0 FROM public.bmn_verified_users)$$);
SELECT pgtest.t('I17 non-owner cannot update an investigation', $$SELECT public.pi_owner_update_investigation(pgtest.u(2), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)), 'in_review', 'x', NULL)$$, 'service_role', NULL, '42501');
SELECT pgtest.t('I18 a note is required', $$SELECT public.pi_owner_update_investigation(pgtest.u(1), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)), 'in_review', '', NULL)$$, 'service_role', NULL, '22023');
SELECT pgtest.t('I19 owner moves it to in_review', $$SELECT public.pi_owner_update_investigation(pgtest.u(1), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)), 'in_review', 'looking at it', NULL)$$, 'service_role');
SELECT pgtest.t('I20 closing needs a resolution', $$SELECT public.pi_owner_update_investigation(pgtest.u(1), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)), 'closed', 'done', NULL)$$, 'service_role', NULL, '22023');
SELECT pgtest.t('I21 owner closes it as a false positive', $$SELECT public.pi_owner_update_investigation(pgtest.u(1), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)), 'closed', 'checked, normal use', 'false_positive')$$, 'service_role');
SELECT pgtest.t('I22 a closed investigation cannot be changed again', $$SELECT public.pi_owner_update_investigation(pgtest.u(1), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6)), 'open', 'reopen', NULL)$$, 'service_role', NULL, 'P0001');
SELECT pgtest.qa('I23 once closed, a new risk finding can open a NEW investigation', $$public.pi_commit_account_assessment(pgtest.ap('i23', pgtest.u(6), 'medium', '{}', '{"open_investigation":true}'))$$,
  $$pgtest.lastj() ->> 'investigation_id' IS NOT NULL AND (SELECT count(*) = 2 FROM public.pi_investigations WHERE user_id = pgtest.u(6)) AND (SELECT count(*) = 1 FROM public.pi_investigations WHERE user_id = pgtest.u(6) AND status <> 'closed')$$, 'service_role');
SELECT pgtest.t('I24 non-owner cannot lift a restriction', $$SELECT public.pi_owner_lift_restriction(pgtest.u(2), (SELECT id FROM public.pi_protective_restrictions WHERE user_id = pgtest.u(7)), 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('I25 owner lifts a restriction', $$SELECT public.pi_owner_lift_restriction(pgtest.u(1), (SELECT id FROM public.pi_protective_restrictions WHERE user_id = pgtest.u(7)), 'verified normal')$$, 'service_role');
SELECT pgtest.t('I26 lifting twice is refused', $$SELECT public.pi_owner_lift_restriction(pgtest.u(1), (SELECT id FROM public.pi_protective_restrictions WHERE user_id = pgtest.u(7)), 'again')$$, 'service_role', NULL, 'P0001');
SELECT pgtest.q('I27 owner acknowledges a security event once', $$public.pi_owner_ack_event(pgtest.u(1), (SELECT id FROM public.pi_security_events WHERE dedupe_key = 'i3:e1')) AND NOT public.pi_owner_ack_event(pgtest.u(1), (SELECT id FROM public.pi_security_events WHERE dedupe_key = 'i3:e1'))$$, 'service_role');
SELECT pgtest.t('I28 non-owner cannot acknowledge an event', $$SELECT public.pi_owner_ack_event(pgtest.u(2), 1)$$, 'service_role', NULL, '42501');

-- ===================================================================== J. verification: auto-approve ONLY when every gate passes; never auto-reject / revoke
INSERT INTO public.bmn_verification_requests (id, user_id, request_reason) VALUES
  (pgtest.u(9601), pgtest.u(8),  'Request from user 8 who is clean and eligible for verification.'),
  (pgtest.u(9602), pgtest.u(9),  'Request from user 9 who has a recent enforced moderation action.'),
  (pgtest.u(9603), pgtest.u(10), 'Request from user 10 who has an open moderation case right now.'),
  (pgtest.u(9604), pgtest.u(11), 'Request from user 11 who has a fraud record on file already.'),
  (pgtest.u(9605), pgtest.u(12), 'Request from user 12 who has high account risk right now yes.');
SELECT pgtest.qa('J01 evaluation on, auto_verification OFF: an all-pass evaluation is only a REFERRAL (nothing approved)', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9601), 'eligible_for_auto_approval'))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND NOT (pgtest.lastj() ->> 'auto_approved')::boolean
  AND (SELECT status = 'pending' FROM public.bmn_verification_requests WHERE id = pgtest.u(9601)) AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(8))
  AND (SELECT count(*) = 1 FROM public.pi_verification_evaluations WHERE verification_request_id = pgtest.u(9601))$$, 'service_role');
SELECT pgtest.q('J02 that referral records why (switched off) and a SHADOW approve recommendation', $$(SELECT reason LIKE '%switched off%' FROM public.pi_verification_decisions WHERE verification_request_id = pgtest.u(9601))
  AND (SELECT mode = 'shadow' AND recommended_action = 'approve_verification' AND requires_human_review FROM public.pi_policy_decisions WHERE decision_kind = 'verification' AND subject_id = pgtest.u(9601))$$);
SELECT pgtest.qa('J03 the same request + criteria version again is a duplicate', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9601), 'eligible_for_auto_approval'))$$,
  $$(pgtest.lastj() ->> 'duplicate')::boolean AND (SELECT count(*) = 1 FROM public.pi_verification_evaluations WHERE verification_request_id = pgtest.u(9601))$$, 'service_role');
SELECT pgtest.t('J04 an "eligible" outcome with a failing check is impossible (table constraint)', $$SELECT public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9602), 'eligible_for_auto_approval', true))$$, 'service_role', NULL, '23514');
SELECT pgtest.q('J05 ... and it stored nothing', $$(SELECT count(*) = 0 FROM public.pi_verification_evaluations WHERE verification_request_id = pgtest.u(9602))$$);
SELECT pgtest.qa('J06 a failing check -> needs_human_review -> referred, request stays pending', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9602), 'needs_human_review', true))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND (SELECT status = 'pending' FROM public.bmn_verification_requests WHERE id = pgtest.u(9602))
  AND (SELECT reason LIKE '%impersonation_screen%' FROM public.pi_verification_decisions WHERE verification_request_id = pgtest.u(9602))$$, 'service_role');
SELECT pgtest.qa('J07 insufficient evidence -> referred (never rejected)', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9603), 'insufficient_evidence', true))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND (SELECT status = 'pending' FROM public.bmn_verification_requests WHERE id = pgtest.u(9603))$$, 'service_role');
SELECT pgtest.t('J08 the owner switches automatic approval ON (delegating authority)', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'auto_verification', true, 'test: delegate approvals')$$, 'service_role');
-- gate preparation
SELECT pgtest.q('J09 prep: u9 has a recent ENFORCED owner action; u10 an open case; u11 a fraud record; u12 high risk', $$(SELECT count(*) = 1 FROM (SELECT public.pi_commit_account_assessment(pgtest.ap('j9', pgtest.u(12), 'high')) ) x)$$, 'service_role');
INSERT INTO public.pi_moderation_actions (target_user_id, subject_type, subject_id, action_type, actor_type, actor_id, mode, user_visible_reason)
  VALUES (pgtest.u(9), 'post', gen_random_uuid(), 'warn', 'owner', pgtest.u(1), 'enforced', 'test warning');
INSERT INTO public.pi_moderation_cases (subject_type, subject_id, subject_user_id, source, status) VALUES ('post', gen_random_uuid(), pgtest.u(10), 'automated', 'open');
INSERT INTO public.pi_verification_decisions (user_id, decision, decided_by_type, decided_by, reason, fraud_related) VALUES (pgtest.u(11), 'revoked', 'owner', pgtest.u(1), 'test fraud record', true);
SELECT pgtest.qa('J10 ALL gates pass: automatic approval happens, under the delegating owner', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9601), 'eligible_for_auto_approval', false, '{"force":true}'))$$,
  $$pgtest.lastj() ->> 'decision' = 'approved' AND (pgtest.lastj() ->> 'auto_approved')::boolean
  AND (SELECT status = 'approved' AND reviewed_by = pgtest.u(1) AND review_note LIKE 'Automatically approved%' FROM public.bmn_verification_requests WHERE id = pgtest.u(9601))
  AND EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(8) AND verified_by = pgtest.u(1))$$, 'service_role');
SELECT pgtest.q('J11 the approval is recorded as a system decision with its evaluation, in the decision history and the audit log', $$EXISTS (SELECT 1 FROM public.pi_verification_decisions WHERE verification_request_id = pgtest.u(9601) AND decision = 'approved' AND decided_by_type = 'system' AND evaluation_id IS NOT NULL)
  AND EXISTS (SELECT 1 FROM public.pi_policy_decisions WHERE decision_kind = 'verification' AND subject_id = pgtest.u(9601) AND mode = 'enforced' AND recommended_action = 'approve_verification' AND NOT requires_human_review)
  AND EXISTS (SELECT 1 FROM public.pi_audit_log WHERE action = 'verification_auto_approved' AND target_id = pgtest.u(9601)::text AND actor_type = 'system')$$);
SELECT pgtest.qa('J12 gate: a recent enforced moderation action blocks auto-approval (referred instead)', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9602), 'eligible_for_auto_approval', false, '{"force":true}'))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND pgtest.lastj() ->> 'reason' LIKE '%recent enforced moderation action%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(9))$$, 'service_role');
SELECT pgtest.qa('J13 gate: an open moderation case blocks auto-approval', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9603), 'eligible_for_auto_approval', false, '{"force":true}'))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND pgtest.lastj() ->> 'reason' LIKE '%open moderation case%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(10))$$, 'service_role');
SELECT pgtest.qa('J14 gate: a previous revocation / fraud record blocks auto-approval', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9604), 'eligible_for_auto_approval', false, '{"force":true}'))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND pgtest.lastj() ->> 'reason' LIKE '%revocation or fraud%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(11))$$, 'service_role');
SELECT pgtest.qa('J15 gate: high account risk blocks auto-approval', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9605), 'eligible_for_auto_approval', false, '{"force":true}'))$$,
  $$pgtest.lastj() ->> 'decision' = 'referred_to_human' AND pgtest.lastj() ->> 'reason' LIKE '%high account risk%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(12))$$, 'service_role');
-- more gates on fresh requests
INSERT INTO auth.users (id, email) VALUES (pgtest.u(13), 'u13@test.invalid'), (pgtest.u(14), 'u14@test.invalid'), (pgtest.u(15), 'u15@test.invalid'), (pgtest.u(16), 'u16@test.invalid');
INSERT INTO public.profiles (id, username, display_name) VALUES (pgtest.u(13), 'user13_t', 'U13'), (pgtest.u(14), 'user14_t', 'U14'), (pgtest.u(15), 'user15_t', 'U15'), (pgtest.u(16), 'user16_t', 'U16');
INSERT INTO public.bmn_verification_requests (id, user_id, request_reason) VALUES
  (pgtest.u(9613), pgtest.u(13), 'Request from user 13 who already holds a verified badge today.'),
  (pgtest.u(9614), pgtest.u(14), 'Request from user 14 who currently carries an active restriction.'),
  (pgtest.u(9615), pgtest.u(15), 'Request from user 15 whose account is currently suspended here.'),
  (pgtest.u(9616), pgtest.u(16), 'Request from user 16 where no valid owner delegated approvals.');
INSERT INTO public.bmn_verified_users (user_id, verified_by) VALUES (pgtest.u(13), pgtest.u(1));
INSERT INTO public.pi_protective_restrictions (user_id, restriction_type, reason_code, actor_type, mode, expires_at) VALUES (pgtest.u(14), 'limit_posting', 'test', 'system', 'shadow', now() + interval '5 hours');
INSERT INTO public.bmn_user_moderation (user_id, status, reason, updated_by) VALUES (pgtest.u(15), 'suspended', 'test', pgtest.u(1));
SELECT pgtest.qa('J16 gate: already verified', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9613), 'eligible_for_auto_approval'))$$, $$pgtest.lastj() ->> 'reason' LIKE '%already verified%' AND (SELECT status = 'pending' FROM public.bmn_verification_requests WHERE id = pgtest.u(9613))$$, 'service_role');
SELECT pgtest.qa('J17 gate: active protective restriction', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9614), 'eligible_for_auto_approval'))$$, $$pgtest.lastj() ->> 'reason' LIKE '%active protective restriction%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(14))$$, 'service_role');
SELECT pgtest.qa('J18 gate: suspended / banned account', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9615), 'eligible_for_auto_approval'))$$, $$pgtest.lastj() ->> 'reason' LIKE '%suspended or banned%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(15))$$, 'service_role');
UPDATE public.pi_feature_flags SET updated_by = NULL WHERE key = 'auto_verification';
SELECT pgtest.qa('J19 gate: if no valid owner delegated automatic approval, nothing is approved', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9616), 'eligible_for_auto_approval'))$$, $$pgtest.lastj() ->> 'reason' LIKE '%no valid owner%' AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(16))$$, 'service_role');
UPDATE public.pi_feature_flags SET updated_by = pgtest.u(1) WHERE key = 'auto_verification';
SELECT pgtest.q('J20 no automatic decision is ever a rejection or a revocation', $$(SELECT count(*) = 0 FROM public.pi_verification_decisions WHERE decided_by_type = 'system' AND decision NOT IN ('approved', 'referred_to_human'))
  AND (SELECT count(*) = 0 FROM public.bmn_verification_requests WHERE status IN ('rejected', 'revoked'))$$);
SELECT pgtest.t('J21 the database itself refuses an automatic rejection', $$INSERT INTO public.pi_verification_decisions (user_id, decision, decided_by_type, reason) VALUES (pgtest.u(5), 'rejected', 'system', 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('J22 ... and an automatic revocation', $$INSERT INTO public.pi_verification_decisions (user_id, decision, decided_by_type, reason) VALUES (pgtest.u(5), 'revoked', 'system', 'x')$$, 'service_role', NULL, '23514');
SELECT pgtest.q('J23 only the one fully clean request was verified automatically', $$(SELECT count(*) = 1 FROM public.pi_verification_decisions WHERE decided_by_type = 'system' AND decision = 'approved')$$);
SELECT pgtest.qa('J24 an already-decided request is skipped, not re-evaluated', $$public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9601), 'eligible_for_auto_approval', false, '{"force":true}'))$$, $$(pgtest.lastj() ->> 'skipped')::boolean$$, 'service_role');
SELECT pgtest.t('J25 an unknown request is refused', $$SELECT public.pi_commit_verification_evaluation(pgtest.vp(gen_random_uuid(), 'needs_human_review', true))$$, 'service_role', NULL, 'P0002');
SELECT pgtest.t('J26 signed-in users cannot commit evaluations', $$SELECT public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9602), 'needs_human_review', true))$$, 'authenticated', pgtest.u(9), '42501');
SELECT pgtest.t('J27 halt', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', true, 'test halt')$$, 'service_role');
SELECT pgtest.t('J28 (halted) no evaluation can be committed', $$SELECT public.pi_commit_verification_evaluation(pgtest.vp(pgtest.u(9602), 'needs_human_review', true, '{"force":true}'))$$, 'service_role', NULL, '55000');
SELECT pgtest.t('J29 resume', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'emergency_halt_automation', false, 'test resume')$$, 'service_role');
SELECT pgtest.q('J30 the verification facts for the engine are complete', $$(SELECT (f ->> 'found')::boolean AND f -> 'profile' ->> 'exists' = 'true' AND f ? 'violations_180d' AND f ? 'fraud_history' AND f ? 'verified_names' AND f ? 'published_posts' AND f ? 'followers'
  FROM (SELECT public.pi_verification_facts(pgtest.u(9602)) f) s) AND (SELECT (public.pi_verification_facts(gen_random_uuid()) ->> 'found')::boolean = false)$$);
-- human decisions
SELECT pgtest.t('J31 a non-owner cannot decide a verification', $$SELECT public.pi_owner_decide_verification(pgtest.u(2), pgtest.u(9604), 'approved', 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('J32 a note is required', $$SELECT public.pi_owner_decide_verification(pgtest.u(1), pgtest.u(9604), 'rejected', '')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('J33 only approved / rejected are valid', $$SELECT public.pi_owner_decide_verification(pgtest.u(1), pgtest.u(9604), 'revoked', 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('J34 the owner rejects a request (a HUMAN rejection)', $$SELECT public.pi_owner_decide_verification(pgtest.u(1), pgtest.u(9604), 'rejected', 'fraud record: not verifying')$$, 'service_role');
SELECT pgtest.q('J35 recorded as an owner decision linked to the evaluation, with an audit entry; no badge', $$EXISTS (SELECT 1 FROM public.pi_verification_decisions WHERE verification_request_id = pgtest.u(9604) AND decision = 'rejected' AND decided_by_type = 'owner' AND decided_by = pgtest.u(1) AND evaluation_id IS NOT NULL)
  AND EXISTS (SELECT 1 FROM public.pi_audit_log WHERE action = 'verification_rejected' AND actor_id = pgtest.u(1)) AND NOT EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(11))$$);
SELECT pgtest.t('J36 deciding an already-decided request is refused', $$SELECT public.pi_owner_decide_verification(pgtest.u(1), pgtest.u(9604), 'approved', 'again')$$, 'service_role', NULL, 'P0002');
SELECT pgtest.t('J37 the owner approves a referred request', $$SELECT public.pi_owner_decide_verification(pgtest.u(1), pgtest.u(9603), 'approved', 'reviewed the evidence manually')$$, 'service_role');
SELECT pgtest.q('J38 ... which creates the verified badge', $$EXISTS (SELECT 1 FROM public.bmn_verified_users WHERE user_id = pgtest.u(10) AND verified_by = pgtest.u(1)) AND (SELECT status = 'approved' FROM public.bmn_verification_requests WHERE id = pgtest.u(9603))$$);
SELECT pgtest.t('J39 owner can queue a re-evaluation of a pending request', $$SELECT public.pi_owner_enqueue(pgtest.u(1), 'evaluate_verification', jsonb_build_object('request_id', pgtest.u(9602)))$$, 'service_role');
SELECT pgtest.t('J40 ... but not of a decided one', $$SELECT public.pi_owner_enqueue(pgtest.u(1), 'evaluate_verification', jsonb_build_object('request_id', pgtest.u(9603)))$$, 'service_role', NULL, 'P0002');
SELECT pgtest.t('J41 the console cannot queue arbitrary job types', $$SELECT public.pi_owner_enqueue(pgtest.u(1), 'apply_action', '{}'::jsonb)$$, 'service_role', NULL, '22023');
SELECT pgtest.t('J42 a non-owner cannot queue jobs', $$SELECT public.pi_owner_enqueue(pgtest.u(2), 'provider_healthcheck', '{}'::jsonb)$$, 'service_role', NULL, '42501');

-- ===================================================================== K. AI provider health / circuit breaker
SELECT pgtest.q('K01 the AI provider is unavailable while ai_providers is OFF', $$NOT public.pi_provider_available('openai_moderation')$$);
SELECT pgtest.t('K02 owner enables ai_providers', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'ai_providers', true, 'test providers')$$, 'service_role');
SELECT pgtest.q('K03 an unknown provider with no failures is available', $$public.pi_provider_available('openai_moderation')$$);
SELECT pgtest.qa('K04 failures 1-4 degrade, the 5th opens the circuit for 5 minutes and raises an alert', $$(SELECT array_agg(public.pi_report_provider('openai_moderation', false, 'timeout ' || n) ORDER BY n) FROM generate_series(1, 5) n)$$,
  $$pgtest.lastj() = '["degraded","degraded","degraded","degraded","down"]'::jsonb AND NOT public.pi_provider_available('openai_moderation') AND EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE kind = 'provider_down' AND resolved_at IS NULL)
  AND (SELECT circuit_open_until BETWEEN now() + interval '4 minutes' AND now() + interval '6 minutes' FROM public.pi_provider_health WHERE provider = 'openai_moderation')$$, 'service_role');
SELECT pgtest.qa('K05 a success closes the circuit and clears the alert', $$public.pi_report_provider('openai_moderation', true)$$,
  $$pgtest.lastj() #>> '{}' = 'healthy' AND public.pi_provider_available('openai_moderation') AND NOT EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE kind = 'provider_down' AND resolved_at IS NULL)$$, 'service_role');
SELECT pgtest.t('K06 owner disables ai_providers again (rules-only operation)', $$SELECT public.pi_owner_set_flag(pgtest.u(1), 'ai_providers', false, 'test providers off')$$, 'service_role');
SELECT pgtest.t('K07 signed-in users cannot report provider health', $$SELECT public.pi_report_provider('x', true)$$, 'authenticated', pgtest.u(2), '42501');

-- ===================================================================== L. human case decisions, content removal parity, reversal
INSERT INTO public.posts (id, user_id, title, caption, status) VALUES (pgtest.u(9701), pgtest.u(5), 'Case post', 'case caption', 'published');
SELECT pgtest.q('L01 setup: an open case with a standing automatic hold on a post', $$(SELECT r ->> 'case_id' IS NOT NULL FROM (SELECT public.pi_commit_moderation_result(pgtest.mp('l1', 'post', pgtest.u(9701), pgtest.u(5), 'spam_scams', 'violation_likely', 'hide_pending_review', '{"requires_human_review":true}')) r) s)$$, 'service_role');
SELECT pgtest.t('L02 a non-owner cannot resolve a case', $$SELECT public.pi_owner_resolve_case(pgtest.u(2), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'no_violation', 'no_action', NULL, 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('L03 a decision note is required', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'no_violation', 'no_action', NULL, '')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('L04 removal needs a reason the user can see', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'violation_confirmed', 'remove_content', '', 'confirmed spam')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('L05 no action may be taken when no violation was found', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'no_violation', 'remove_content', 'x', 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('L06 a ban cannot be issued through the case screen', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'violation_confirmed', 'ban', 'x', 'x')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('L07 content removal is supported for posts only (comment case refused)', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9201)), 'violation_confirmed', 'remove_content', 'spam', 'confirmed')$$, 'service_role', NULL, '22023');
SELECT pgtest.q('L08 the refused attempts changed nothing', $$(SELECT status = 'published' FROM public.posts WHERE id = pgtest.u(9701)) AND (SELECT status <> 'resolved' AND status <> 'dismissed' FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701))$$);
SELECT pgtest.t('L09 owner confirms the violation and removes the post', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'violation_confirmed', 'remove_content', 'This post broke the spam rules.', 'confirmed after review')$$, 'service_role');
SELECT pgtest.q('L10 the post is removed exactly like the existing owner tool does it (status + legacy moderation_actions row)', $$(SELECT status = 'removed' FROM public.posts WHERE id = pgtest.u(9701))
  AND (SELECT count(*) = 1 FROM public.moderation_actions WHERE post_id = pgtest.u(9701) AND action = 'post_removed' AND admin_id = pgtest.u(1) AND target_user_id = pgtest.u(5) AND reason = 'This post broke the spam rules.')$$);
SELECT pgtest.q('L11 the PI records agree: owner / enforced / remove_content, case resolved as content_removed, audited', $$EXISTS (SELECT 1 FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content' AND actor_type = 'owner' AND actor_id = pgtest.u(1) AND mode = 'enforced' AND appealable)
  AND (SELECT status = 'resolved' AND resolution = 'content_removed' AND resolved_at IS NOT NULL FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701))
  AND EXISTS (SELECT 1 FROM public.pi_audit_log WHERE action = 'case_resolved' AND actor_id = pgtest.u(1) AND after_state ->> 'resolution' = 'content_removed')$$);
SELECT pgtest.q('L12 the removal counts as an enforced violation for that user', $$public.pi_violation_count(pgtest.u(5), interval '90 days') >= 1$$);
SELECT pgtest.t('L13 resolving an already-resolved case is refused', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9701)), 'no_violation', 'no_action', NULL, 'again')$$, 'service_role', NULL, 'P0001');
SELECT pgtest.t('L14 a non-owner cannot reverse an action', $$SELECT public.pi_owner_reverse_action(pgtest.u(2), (SELECT id FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content'), 'x')$$, 'service_role', NULL, '42501');
SELECT pgtest.t('L15 a reason is required to reverse', $$SELECT public.pi_owner_reverse_action(pgtest.u(1), (SELECT id FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content'), '')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('L16 owner reverses the removal (appeal granted)', $$SELECT public.pi_owner_reverse_action(pgtest.u(1), (SELECT id FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content'), 'appeal upheld')$$, 'service_role');
SELECT pgtest.q('L17 the reversal is recorded and a restore job is queued (the post is restored by the worker, not silently)', $$(SELECT reversed_at IS NOT NULL AND reversed_by = pgtest.u(1) AND reversal_reason = 'appeal upheld' FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content')
  AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE job_type = 'reverse_action' AND payload ->> 'action_id' = (SELECT id::text FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content'))
  AND (SELECT status = 'removed' FROM public.posts WHERE id = pgtest.u(9701))$$);
SELECT pgtest.t('L18 reversing twice is refused', $$SELECT public.pi_owner_reverse_action(pgtest.u(1), (SELECT id FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content'), 'again')$$, 'service_role', NULL, 'P0001');
SELECT pgtest.qa('L19 the worker applies the reversal: post restored + legacy post_restored row', $$public.pi_apply_reversal((SELECT id FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content'))$$,
  $$(pgtest.lastj() ->> 'applied')::boolean AND (SELECT status = 'published' FROM public.posts WHERE id = pgtest.u(9701)) AND (SELECT count(*) = 1 FROM public.moderation_actions WHERE post_id = pgtest.u(9701) AND action = 'post_restored')$$, 'service_role');
SELECT pgtest.q('L20 applying it again is harmless (idempotent)', $$(SELECT NOT (r ->> 'applied')::boolean FROM (SELECT public.pi_apply_reversal((SELECT id FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9701) AND action_type = 'remove_content')) r) s)
  AND (SELECT count(*) = 1 FROM public.moderation_actions WHERE post_id = pgtest.u(9701) AND action = 'post_restored')$$, 'service_role');
SELECT pgtest.q('L21 the reversed removal no longer counts as a violation', $$public.pi_violation_count(pgtest.u(5), interval '90 days') = 0$$);
SELECT pgtest.q('L22 reversing an action that has no platform effect (an automatic hold) is a no-op', $$(SELECT NOT (r ->> 'applied')::boolean FROM (SELECT public.pi_apply_reversal((SELECT id FROM public.pi_moderation_actions WHERE idempotency_key = 'act:g6')) r) s)$$, 'service_role');
-- no-violation path
INSERT INTO public.posts (id, user_id, title, caption, status) VALUES (pgtest.u(9702), pgtest.u(6), 'Fine post', 'all good', 'published');
SELECT pgtest.q('L23 setup: a case with a standing automatic hold on a fine post', $$(SELECT r ->> 'case_id' IS NOT NULL AND r ->> 'action_id' IS NOT NULL FROM (SELECT public.pi_commit_moderation_result(pgtest.mp('l23', 'post', pgtest.u(9702), pgtest.u(6), 'spam_scams', 'violation_likely', 'hide_pending_review', '{"requires_human_review":true}')) r) s)$$, 'service_role');
SELECT pgtest.t('L24 owner finds no violation', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9702)), 'no_violation', 'no_action', NULL, 'false positive')$$, 'service_role');
SELECT pgtest.q('L25 the case is dismissed, the automatic hold is reversed and its lifting is queued', $$(SELECT status = 'dismissed' AND resolution = 'no_violation' FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9702))
  AND (SELECT reversed_at IS NOT NULL AND reversed_by = pgtest.u(1) FROM public.pi_moderation_actions WHERE idempotency_key = 'act:l23')
  AND EXISTS (SELECT 1 FROM public.pi_jobs WHERE idempotency_key = 'reverse_action:' || (SELECT id::text FROM public.pi_moderation_actions WHERE idempotency_key = 'act:l23'))
  AND (SELECT status = 'published' FROM public.posts WHERE id = pgtest.u(9702)) AND (SELECT count(*) = 0 FROM public.moderation_actions WHERE post_id = pgtest.u(9702))$$);
-- warn path
INSERT INTO public.comments (id, user_id, post_id, body, content) VALUES (pgtest.u(9703), pgtest.u(6), pgtest.u(9702), 'rude comment', 'rude comment');
SELECT pgtest.q('L26 setup: a harassment case on a comment', $$(SELECT r ->> 'case_id' IS NOT NULL FROM (SELECT public.pi_commit_moderation_result(pgtest.mp('l26', 'comment', pgtest.u(9703), pgtest.u(6), 'harassment_bullying', 'uncertain', 'flag', '{"requires_human_review":true}')) r) s)$$, 'service_role');
SELECT pgtest.t('L27 owner confirms and warns the user (no content removal)', $$SELECT public.pi_owner_resolve_case(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9703)), 'violation_confirmed', 'warn', 'Please keep comments respectful.', 'first offence')$$, 'service_role');
SELECT pgtest.q('L28 the warning is recorded as an owner action; nothing on the platform changed', $$EXISTS (SELECT 1 FROM public.pi_moderation_actions WHERE subject_id = pgtest.u(9703) AND action_type = 'warn' AND actor_type = 'owner' AND mode = 'enforced' AND user_visible_reason = 'Please keep comments respectful.')
  AND (SELECT status = 'resolved' AND resolution = 'user_actioned' FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9703)) AND (SELECT count(*) = 0 FROM public.moderation_actions WHERE target_user_id = pgtest.u(6))$$);
SELECT pgtest.q('L29 the user sees the warning in their own notices (and nobody else sees it)', $$(SELECT count(*) >= 1 FROM public.pi_my_moderation_notices() WHERE action_type = 'warn' AND user_visible_reason = 'Please keep comments respectful.')$$, 'authenticated', pgtest.u(6));
SELECT pgtest.q('L30 another user sees none of it', $$(SELECT count(*) = 0 FROM public.pi_my_moderation_notices())$$, 'authenticated', pgtest.u(7));

-- ===================================================================== M. owner read models (the control centre)
SELECT pgtest.q('M01 overview has every section', $$(SELECT o ? 'flags' AND o ? 'cases' AND o ? 'accounts' AND o ? 'verification' AND o ? 'appeals' AND o ? 'alerts_open' AND o ? 'jobs' AND o ? 'workers' AND o ? 'providers' AND o ? 'decisions' AND o ? 'halted' FROM (SELECT public.pi_owner_overview(pgtest.u(1)) o) s)$$, 'service_role');
SELECT pgtest.q('M02 the case queue lists cases with a preview of the content', $$(SELECT jsonb_typeof(l) = 'array' AND jsonb_array_length(l) >= 1 FROM (SELECT public.pi_owner_list_cases(pgtest.u(1), 'awaiting_review', 50, 0) l) s)$$, 'service_role');
SELECT pgtest.q('M03 the case detail returns analyses, actions and decisions', $$(SELECT d ? 'case' AND d ? 'analyses' AND d ? 'actions' AND d ? 'decisions' FROM (SELECT public.pi_owner_case_detail(pgtest.u(1), (SELECT id FROM public.pi_moderation_cases WHERE subject_id = pgtest.u(9101) LIMIT 1)) d) s)$$, 'service_role');
SELECT pgtest.q('M04 the account list, investigations, events, alerts, restrictions, verification, appeals and policy screens all return data for the owner', $$jsonb_typeof(public.pi_owner_list_accounts(pgtest.u(1), 'medium', 50)) = 'array'
  AND jsonb_typeof(public.pi_owner_list_investigations(pgtest.u(1), 'open', 50)) = 'array' AND jsonb_typeof(public.pi_owner_list_events(pgtest.u(1), false, 50)) = 'array'
  AND jsonb_typeof(public.pi_owner_list_alerts(pgtest.u(1), true, 50)) = 'array' AND jsonb_typeof(public.pi_owner_list_restrictions(pgtest.u(1), false, 50)) = 'array'
  AND jsonb_typeof(public.pi_owner_list_verification(pgtest.u(1), 50)) = 'object' AND jsonb_typeof(public.pi_owner_list_appeals(pgtest.u(1), 'pending', 50)) = 'array'
  AND jsonb_typeof(public.pi_owner_list_audit(pgtest.u(1), 100, NULL, NULL)) = 'array' AND jsonb_typeof(public.pi_owner_policy_overview(pgtest.u(1))) = 'object'$$, 'service_role');
SELECT pgtest.q('M05 investigation detail returns the notes timeline', $$(SELECT d ? 'investigation' AND d ? 'notes' FROM (SELECT public.pi_owner_investigation_detail(pgtest.u(1), (SELECT id FROM public.pi_investigations WHERE user_id = pgtest.u(6) ORDER BY opened_at LIMIT 1)) d) s)$$, 'service_role');
SELECT pgtest.q('M06 the audit list can be filtered by action prefix', $$(SELECT jsonb_array_length(l) >= 1 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(l) e WHERE e ->> 'action' NOT LIKE 'feature_flag%') FROM (SELECT public.pi_owner_list_audit(pgtest.u(1), 100, NULL, 'feature_flag') l) s)$$, 'service_role');
SELECT pgtest.t('M07 non-owner: overview refused', $$SELECT public.pi_owner_overview(pgtest.u(3))$$, 'service_role', NULL, '42501');
SELECT pgtest.t('M08 non-owner: case list refused', $$SELECT public.pi_owner_list_cases(pgtest.u(3), 'open', 10, 0)$$, 'service_role', NULL, '42501');
SELECT pgtest.t('M09 non-owner: account list refused', $$SELECT public.pi_owner_list_accounts(pgtest.u(3), 'low', 10)$$, 'service_role', NULL, '42501');
SELECT pgtest.t('M10 non-owner: audit list refused', $$SELECT public.pi_owner_list_audit(pgtest.u(3), 10, NULL, NULL)$$, 'service_role', NULL, '42501');
SELECT pgtest.t('M11 non-owner: policy screen refused', $$SELECT public.pi_owner_policy_overview(pgtest.u(3))$$, 'service_role', NULL, '42501');
SELECT pgtest.t('M12 a NULL actor is refused', $$SELECT public.pi_owner_overview(NULL)$$, 'service_role', NULL, '42501');
SELECT pgtest.q('M12b the verified-names list (for the impersonation screen) holds public names only', $$jsonb_typeof(public.pi_verified_names(100)) = 'array' AND jsonb_array_length(public.pi_verified_names(100)) >= 2 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.pi_verified_names(100)) e WHERE e ? 'email' OR e ? 'bio')$$);
SELECT pgtest.q('M13 private messages are never previewed to the owner', $$public.pi_subject_preview('message', pgtest.u(9301)) IS NULL AND public.pi_subject_preview('post', pgtest.u(9101)) IS NOT NULL$$);
SELECT pgtest.t('M14 limits on list sizes are enforced (no unbounded dump)', $$SELECT jsonb_array_length(public.pi_owner_list_cases(pgtest.u(1), 'open', 100000, 0)) <= 200$$, 'service_role');

-- ===================================================================== N. operations: heartbeats, health alerts, retention
SELECT pgtest.qa('N01 with automation on and no worker reporting, a worker_offline alert is raised', $$public.pi_system_health()$$,
  $$(pgtest.lastj() ->> 'workers_active')::int = 0 AND (pgtest.lastj() ->> 'automation_enabled')::boolean AND EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE kind = 'worker_offline' AND resolved_at IS NULL)$$, 'service_role');
SELECT pgtest.t('N02 a worker reports in', $$SELECT public.pi_worker_heartbeat('test-worker-1', '2.0.0', 5, 1, NULL, '{"host":"t"}'::jsonb)$$, 'service_role');
SELECT pgtest.qa('N03 health sees the worker and clears the offline alert', $$public.pi_system_health()$$,
  $$(pgtest.lastj() ->> 'workers_active')::int = 1 AND NOT EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE kind = 'worker_offline' AND resolved_at IS NULL)$$, 'service_role');
SELECT pgtest.t('N04a a repeated heartbeat is accepted', $$SELECT public.pi_worker_heartbeat('test-worker-1', '2.0.0', 9, 1, 'boom', '{}'::jsonb)$$, 'service_role');
SELECT pgtest.q('N04b ... and updates the same row', $$(SELECT count(*) = 1 AND max(jobs_succeeded) = 9 AND max(last_error) = 'boom' FROM public.pi_worker_heartbeats WHERE worker_id = 'test-worker-1')$$);
SELECT pgtest.t('N05 a blank worker id is refused', $$SELECT public.pi_worker_heartbeat(' ', '1', 0, 0, NULL, '{}'::jsonb)$$, 'service_role', NULL, '23514');
INSERT INTO public.pi_jobs (job_type, idempotency_key, status, finished_at, last_error, attempts, max_attempts) VALUES ('purge_retention', 'n:dead', 'dead', now(), 'boom', 3, 3);
SELECT pgtest.qa('N06 a permanently failed job raises a jobs_dead alert', $$public.pi_system_health()$$,
  $$(pgtest.lastj() ->> 'dead_jobs_24h')::int >= 1 AND EXISTS (SELECT 1 FROM public.pi_system_alerts WHERE kind = 'jobs_dead' AND resolved_at IS NULL)$$, 'service_role');
SELECT pgtest.t('N07a raise an alert twice with the same key', $$SELECT public.pi_raise_alert('t_kind', 'low', 'm', '{}'::jsonb, 'dd1'); SELECT public.pi_raise_alert('t_kind', 'low', 'm2', '{}'::jsonb, 'dd1')$$, 'service_role');
SELECT pgtest.q('N07b alerts de-duplicate: one open alert whose count grows', $$(SELECT count(*) = 1 AND max(occurrences) = 2 AND max(message) = 'm2' FROM public.pi_system_alerts WHERE dedupe_key = 'dd1' AND resolved_at IS NULL)$$);
SELECT pgtest.q('N08 the owner can acknowledge an alert (once)', $$public.pi_owner_ack_alert(pgtest.u(1), (SELECT id FROM public.pi_system_alerts WHERE dedupe_key = 'dd1')) AND NOT public.pi_owner_ack_alert(pgtest.u(1), (SELECT id FROM public.pi_system_alerts WHERE dedupe_key = 'dd1'))$$, 'service_role');
SELECT pgtest.t('N09 non-owner cannot acknowledge an alert', $$SELECT public.pi_owner_ack_alert(pgtest.u(2), 1)$$, 'service_role', NULL, '42501');
INSERT INTO public.pi_session_observations (user_id, ip_hash, device_hash, first_seen_at, last_seen_at) VALUES (pgtest.u(7), repeat('1', 64), repeat('2', 64), now() - interval '200 days', now() - interval '200 days');
SELECT pgtest.t('N10 retention windows that are too short are refused', $$SELECT public.pi_purge_retention(interval '1 day', interval '30 days')$$, 'service_role', NULL, '22023');
SELECT pgtest.qa('N11 retention removes only old session observations / finished jobs / heartbeats / resolved alerts', $$public.pi_purge_retention()$$,
  $$(pgtest.lastj() ->> 'session_observations')::int >= 1 AND NOT EXISTS (SELECT 1 FROM public.pi_session_observations WHERE last_seen_at < now() - interval '90 days')$$, 'service_role');
SELECT pgtest.q('N12 retention left audit log, decisions, cases, actions and evaluations intact', $$(SELECT count(*) > 0 FROM public.pi_audit_log) AND (SELECT count(*) > 0 FROM public.pi_policy_decisions) AND (SELECT count(*) > 0 FROM public.pi_moderation_cases)
  AND (SELECT count(*) > 0 FROM public.pi_moderation_actions) AND (SELECT count(*) > 0 FROM public.pi_verification_evaluations)$$);
SELECT pgtest.t('N13 signed-in users cannot run retention', $$SELECT public.pi_purge_retention()$$, 'authenticated', pgtest.u(2), '42501');

-- ===================================================================== O. integrity: audit trail completeness, account deletion, BMN untouched
SELECT pgtest.q('O01 every important decision type is in the audit log', $$(SELECT count(DISTINCT action) FROM public.pi_audit_log WHERE action IN ('feature_flag_changed', 'policy_changed', 'rule_set_published', 'content_analysed', 'account_assessed',
  'verification_auto_approved', 'verification_referred', 'verification_rejected', 'verification_approved', 'case_resolved', 'action_reversed', 'automated_holds_expired', 'restriction_lifted', 'investigation_in_review', 'investigation_closed',
  'security_event_acknowledged', 'system_alert_acknowledged', 'reversal_applied', 'job_requested')) = 19$$);
SELECT pgtest.q('O02 every owner action carries the owner as actor, every automatic one the system', $$(SELECT bool_and((actor_type = 'owner') = (actor_id IS NOT NULL) OR actor_type = 'system') FROM public.pi_audit_log)$$);
INSERT INTO auth.users (id, email) VALUES (pgtest.u(20), 'u20@test.invalid');
INSERT INTO public.profiles (id, username, display_name) VALUES (pgtest.u(20), 'user20_t', 'U20');
SELECT pgtest.q('O03 setup: a user with sessions, an assessment, an investigation, a decision and a case', $$public.pi_record_session(pgtest.u(20), repeat('7', 64), repeat('8', 64)) IS NOT NULL
  AND (SELECT (r ->> 'investigation_id') IS NOT NULL FROM (SELECT public.pi_commit_account_assessment(pgtest.ap('o3', pgtest.u(20), 'medium', '{}', '{"open_investigation":true}')) r) s)
  AND (SELECT r ->> 'case_id' IS NOT NULL FROM (SELECT public.pi_commit_moderation_result(pgtest.mp('o3m', 'profile', pgtest.u(20), pgtest.u(20), 'spam_scams', 'uncertain', 'flag', '{"requires_human_review":true}')) r) s)$$, 'service_role');
SELECT pgtest.t('O04 deleting the account succeeds (right to erasure) ...', $$DELETE FROM auth.users WHERE id = pgtest.u(20)$$);
SELECT pgtest.q('O05 ... personal operational rows are gone, the history survives without the person', $$(SELECT count(*) = 0 FROM public.pi_session_observations WHERE user_id = pgtest.u(20)) AND (SELECT count(*) = 0 FROM public.pi_investigations WHERE user_id = pgtest.u(20))
  AND (SELECT count(*) = 0 FROM public.pi_account_risk_assessments WHERE user_id = pgtest.u(20))
  AND (SELECT count(*) >= 1 FROM public.pi_policy_decisions WHERE idempotency_key IN ('decision:o3', 'decision:o3m') AND subject_user_id IS NULL)
  AND (SELECT count(*) >= 1 FROM public.pi_audit_log WHERE target_id = pgtest.u(20)::text)$$);
SELECT pgtest.q('O06 no 002 function changed a BMN table definition (BMN schema fingerprint equals the baseline)', $$(SELECT a.schema_fp = b.schema_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label = 'baseline' AND b.label = 'after_up')$$);
SELECT pgtest.q('O07 the engine never modified an existing verified user, admin or profile row', $$(SELECT count(*) = 1 FROM public.bmn_admins WHERE role = 'owner') AND (SELECT count(*) = 2 FROM public.bmn_verified_users WHERE user_id IN (pgtest.u(8), pgtest.u(10)))$$);
SELECT pgtest.q('O08 ALL feature flags that this suite left on were switched on by the owner through the audited function (none by default)', $$(SELECT bool_and(updated_by = pgtest.u(1)) FROM public.pi_feature_flags WHERE enabled)$$);
