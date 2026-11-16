-- Platform Intelligence HARDENING tests (job queue safety, audit/history consistency, privileges, BMN compatibility).
-- Run AFTER 001_pi_schema.up.sql and 20_pi_tests.sql on the disposable test database. Never run on production.
-- Identities: u(1)=owner, u(2)=user1, u(3)=user2. Job type 'apply_action' / 'expire_restrictions' are used only here.

-- ===================================================================== Q. job queue safety
-- Q1 worker lease durations
SELECT pgtest.t('Q01 zero lease rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '0',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q02 negative lease rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '-5 minutes',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q03 NULL lease rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,NULL,ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q04 sub-second lease rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '500 milliseconds',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q05 lease over one hour rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '2 hours',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q06 NULL limit rejected', $$SELECT * FROM public.pi_claim_jobs('hw',NULL,interval '1 minute',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q07 limit above 100 rejected', $$SELECT * FROM public.pi_claim_jobs('hw',101,interval '1 minute',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q08 NULL worker rejected', $$SELECT * FROM public.pi_claim_jobs(NULL,1,interval '1 minute',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q09 worker id over 200 characters rejected', $$SELECT * FROM public.pi_claim_jobs(repeat('w',201),1,interval '1 minute',ARRAY['apply_action'])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q10 empty job-type filter rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '1 minute',ARRAY[]::text[])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q11 job-type filter containing NULL rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '1 minute',ARRAY['apply_action',NULL])$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q12 unknown job type in filter rejected', $$SELECT * FROM public.pi_claim_jobs('hw',1,interval '1 minute',ARRAY['mine_bitcoin'])$$, 'service_role', NULL, '22023');
SELECT pgtest.q('Q13 none of the rejected claims changed any job', $$(SELECT count(*) FROM public.pi_jobs WHERE locked_by = 'hw') = 0$$);

-- Q2 retry intervals and attempt limits (function arguments)
SELECT pgtest.t('Q20 setup: job h:a (2 attempts)', $$INSERT INTO public.pi_jobs (job_type, idempotency_key, max_attempts) VALUES ('apply_action','h:a',2)$$, 'service_role');
SELECT pgtest.q('Q21 claim with the minimum 1-second lease works and records exactly that lease', $$(SELECT count(*) = 1 FROM public.pi_claim_jobs('hA',1,interval '1 second',ARRAY['apply_action']))$$, 'service_role');
SELECT pgtest.q('Q22 the stored lease is exactly 1 second after the lock time', $$(SELECT lease_expires_at - locked_at = interval '1 second' AND attempts = 1 AND status = 'running' FROM public.pi_jobs WHERE idempotency_key = 'h:a')$$);
SELECT pgtest.t('Q23 zero retry delay rejected', $$SELECT public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:a'),'hA','e',interval '0')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q24 negative retry delay rejected', $$SELECT public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:a'),'hA','e',interval '-1 minute')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q25 retry delay over 7 days rejected', $$SELECT public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:a'),'hA','e',interval '8 days')$$, 'service_role', NULL, '22023');
SELECT pgtest.t('Q26 blank worker rejected by fail_job', $$SELECT public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:a'),' ','e')$$, 'service_role', NULL, '22023');
SELECT pgtest.q('Q27 rejected failures left the job running and unchanged', $$(SELECT status='running' AND locked_by='hA' AND attempts=1 AND last_error IS NULL FROM public.pi_jobs WHERE idempotency_key='h:a')$$);
SELECT pgtest.q('Q28 failing a job you do not hold returns NULL and changes nothing', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:a'),'someone-else','e') IS NULL AND (SELECT status='running' AND locked_by='hA' FROM public.pi_jobs WHERE idempotency_key='h:a')$$, 'service_role');

-- Q3 lease expiry + retry limits (real time: the 1-second lease really expires)
SELECT pg_sleep(1.5);
SELECT pgtest.q('Q30 an expired lease is taken over by another worker as attempt 2', $$(SELECT attempts = 2 AND locked_by = 'hB' FROM public.pi_claim_jobs('hB',1,interval '1 second',ARRAY['apply_action']) WHERE idempotency_key = 'h:a')$$, 'service_role');
SELECT pgtest.q('Q31 the takeover is recorded in last_error', $$(SELECT last_error LIKE '%lease expired; reclaimed%' FROM public.pi_jobs WHERE idempotency_key='h:a')$$);
SELECT pgtest.q('Q32 the previous holder can no longer complete the job', $$public.pi_complete_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:a'),'hA') = false$$, 'service_role');
SELECT pg_sleep(1.5);
SELECT pgtest.q('Q33 expired lease on the final attempt: nobody can claim it again', $$(SELECT count(*) = 0 FROM public.pi_claim_jobs('hC',5,interval '1 minute',ARRAY['apply_action']) WHERE idempotency_key = 'h:a')$$, 'service_role');
SELECT pgtest.q('Q34 it was dead-lettered, finished, unlocked, attempts did not exceed the maximum', $$(SELECT status='dead' AND finished_at IS NOT NULL AND locked_by IS NULL AND lease_expires_at IS NULL AND attempts = 2 AND last_error LIKE '%final attempt%' FROM public.pi_jobs WHERE idempotency_key='h:a')$$);
-- A second job (2 attempts): fail it once (retry), then on its last attempt (dead letter).
SELECT pgtest.t('Q34b setup: job h:b (2 attempts)', $$INSERT INTO public.pi_jobs (job_type, idempotency_key, max_attempts) VALUES ('apply_action','h:b',2)$$, 'service_role');
SELECT pgtest.q('Q35 h:b is claimed as attempt 1', $$(SELECT count(*)=1 AND bool_and(attempts=1) FROM public.pi_claim_jobs('hC',5,interval '1 minute',ARRAY['apply_action']))$$, 'service_role');
SELECT pgtest.q('Q35b failing with attempts left returns "queued"', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:b'),'hC','first failure',interval '30 seconds') = 'queued'$$, 'service_role');
SELECT pgtest.q('Q36 it is re-queued with the explicit 30s delay, unlocked, not finished', $$(SELECT status='queued' AND run_after BETWEEN now()+interval '25 seconds' AND now()+interval '35 seconds' AND locked_by IS NULL AND lease_expires_at IS NULL AND finished_at IS NULL FROM public.pi_jobs WHERE idempotency_key='h:b')$$);
SELECT pgtest.q('Q37 a retry that is not due yet is not claimable', $$(SELECT count(*)=0 FROM public.pi_claim_jobs('hD',5,interval '1 minute',ARRAY['apply_action']))$$, 'service_role');
SELECT pgtest.t('Q38 (make the retry due)', $$UPDATE public.pi_jobs SET run_after = now() - interval '1 second' WHERE idempotency_key='h:b'$$, 'service_role');
SELECT pgtest.q('Q39 claimed again as attempt 2', $$(SELECT attempts = 2 FROM public.pi_claim_jobs('hD',5,interval '1 minute',ARRAY['apply_action']) WHERE idempotency_key='h:b')$$, 'service_role');
SELECT pgtest.q('Q40 failing the last allowed attempt dead-letters', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:b'),'hD','second failure') = 'dead'$$, 'service_role');
SELECT pgtest.t('Q41 (even if made due, a dead job is never claimed)', $$UPDATE public.pi_jobs SET run_after = now() - interval '1 hour' WHERE idempotency_key='h:b'$$, 'service_role');
SELECT pgtest.q('Q42 a dead job cannot be claimed: attempts stay at the maximum', $$(SELECT count(*)=0 FROM public.pi_claim_jobs('hE',5,interval '1 minute',ARRAY['apply_action'])) AND (SELECT attempts=2 AND status='dead' FROM public.pi_jobs WHERE idempotency_key='h:b')$$, 'service_role');

-- Q4 back-off arithmetic
SELECT pgtest.t('Q50 setup: back-off jobs', $$INSERT INTO public.pi_jobs (job_type, idempotency_key, max_attempts) VALUES ('expire_restrictions','h:bo1',20),('expire_restrictions','h:bo3',20),('expire_restrictions','h:bo12',20),('expire_restrictions','h:blank',20)$$, 'service_role');
SELECT pgtest.q('Q51 claim all four', $$(SELECT count(*)=4 FROM public.pi_claim_jobs('hF',10,interval '10 minutes',ARRAY['expire_restrictions']))$$, 'service_role');
SELECT pgtest.t('Q52 (raise attempts directly; allowed because attempts may only go up)', $$UPDATE public.pi_jobs SET attempts = 3 WHERE idempotency_key='h:bo3'; UPDATE public.pi_jobs SET attempts = 12 WHERE idempotency_key='h:bo12'$$, 'service_role');
SELECT pgtest.q('Q53 failing after attempt 1 re-queues', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:bo1'),'hF','x') = 'queued'$$, 'service_role');
SELECT pgtest.q('Q53b automatic back-off after attempt 1 is about 10 seconds', $$(SELECT run_after BETWEEN now()+interval '8 seconds' AND now()+interval '12 seconds' FROM public.pi_jobs WHERE idempotency_key='h:bo1')$$);
SELECT pgtest.q('Q54 failing after attempt 3 re-queues', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:bo3'),'hF','x') = 'queued'$$, 'service_role');
SELECT pgtest.q('Q54b automatic back-off after attempt 3 is about 40 seconds', $$(SELECT run_after BETWEEN now()+interval '38 seconds' AND now()+interval '42 seconds' FROM public.pi_jobs WHERE idempotency_key='h:bo3')$$);
SELECT pgtest.q('Q55 failing after attempt 12 re-queues', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:bo12'),'hF','x') = 'queued'$$, 'service_role');
SELECT pgtest.q('Q55b automatic back-off is capped at 1 hour (attempt 12 would be 5.7 hours)', $$(SELECT run_after BETWEEN now()+interval '59 minutes' AND now()+interval '61 minutes' FROM public.pi_jobs WHERE idempotency_key='h:bo12')$$);
SELECT pgtest.q('Q56 a blank error text is accepted', $$public.pi_fail_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:blank'),'hF','   ') = 'queued'$$, 'service_role');
SELECT pgtest.q('Q56b and is stored as "unspecified error"', $$(SELECT last_error='unspecified error' FROM public.pi_jobs WHERE idempotency_key='h:blank')$$);

-- Q5 invalid job states are impossible (CHECK constraints)
SELECT pgtest.t('Q60 max_attempts 0 rejected', $$INSERT INTO public.pi_jobs (job_type, max_attempts) VALUES ('apply_action',0)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q61 max_attempts 21 rejected', $$INSERT INTO public.pi_jobs (job_type, max_attempts) VALUES ('apply_action',21)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q62 negative attempts rejected', $$INSERT INTO public.pi_jobs (job_type, attempts) VALUES ('apply_action',-1)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q63 attempts above max_attempts rejected', $$INSERT INTO public.pi_jobs (job_type, attempts, max_attempts) VALUES ('apply_action',6,5)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q64 unknown status rejected', $$INSERT INTO public.pi_jobs (job_type, status) VALUES ('apply_action','paused')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q65 running job with no lock fields rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts) VALUES ('apply_action','running',1)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q66 running job with a worker but no lease rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at) VALUES ('apply_action','running',1,'w',now())$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q67 queued job that still holds a lock rejected', $$INSERT INTO public.pi_jobs (job_type, status, locked_by, locked_at, lease_expires_at) VALUES ('apply_action','queued','w',now(),now()+interval '1 minute')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q68 lease that ends before it starts rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at, lease_expires_at) VALUES ('apply_action','running',1,'w',now(),now()-interval '1 minute')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q69 zero-length lease rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at, lease_expires_at) VALUES ('apply_action','running',1,'w','2030-01-01','2030-01-01')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q70 running job with zero attempts rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at, lease_expires_at) VALUES ('apply_action','running',0,'w',now(),now()+interval '1 minute')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q71 blank worker id rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at, lease_expires_at) VALUES ('apply_action','running',1,'  ',now(),now()+interval '1 minute')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q72 worker id over 200 characters rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at, lease_expires_at) VALUES ('apply_action','running',1,repeat('w',201),now(),now()+interval '1 minute')$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q73 succeeded job without a finish time rejected', $$INSERT INTO public.pi_jobs (job_type, status, attempts) VALUES ('apply_action','succeeded',1)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q74 queued job with a finish time rejected', $$INSERT INTO public.pi_jobs (job_type, status, finished_at) VALUES ('apply_action','queued',now())$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q75 non-object payload rejected', $$INSERT INTO public.pi_jobs (job_type, payload) VALUES ('apply_action','[1,2]'::jsonb)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q76 priority 0 rejected', $$INSERT INTO public.pi_jobs (job_type, priority) VALUES ('apply_action',0)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q77 priority 10 rejected', $$INSERT INTO public.pi_jobs (job_type, priority) VALUES ('apply_action',10)$$, 'service_role', NULL, '23514');
SELECT pgtest.t('Q78 a fully valid running job IS accepted', $$INSERT INTO public.pi_jobs (job_type, status, attempts, locked_by, locked_at, lease_expires_at, started_at, idempotency_key) VALUES ('provider_healthcheck','running',1,'wv',now(),now()+interval '1 minute',now(),'h:valid-running')$$, 'service_role');

-- Q6 state-machine guard (illegal transitions and immutable fields)
SELECT pgtest.t('Q80 setup: a job that succeeded, one cancelled, one dead', $$
  INSERT INTO public.pi_jobs (job_type, status, attempts, finished_at, idempotency_key) VALUES
    ('provider_healthcheck','succeeded',1,now(),'h:done'), ('provider_healthcheck','cancelled',0,now(),'h:cancelled'),
    ('provider_healthcheck','dead',5,now(),'h:dead')$$, 'service_role');
SELECT pgtest.t('Q81 succeeded -> queued refused', $$UPDATE public.pi_jobs SET status='queued', finished_at=NULL WHERE idempotency_key='h:done'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q82 dead -> queued refused (no resurrecting dead letters)', $$UPDATE public.pi_jobs SET status='queued', finished_at=NULL WHERE idempotency_key='h:dead'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q83 cancelled -> running refused', $$UPDATE public.pi_jobs SET status='running', attempts=1, locked_by='w', locked_at=now(), lease_expires_at=now()+interval '1 minute', finished_at=NULL WHERE idempotency_key='h:cancelled'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q84 queued -> succeeded (skipping running) refused', $$UPDATE public.pi_jobs SET status='succeeded', finished_at=now() WHERE idempotency_key='h:bo1'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q85 queued -> dead refused', $$UPDATE public.pi_jobs SET status='dead', finished_at=now() WHERE idempotency_key='h:bo1'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q86 a job''s type cannot be changed', $$UPDATE public.pi_jobs SET job_type='purge_retention' WHERE idempotency_key='h:bo1'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q87 a job''s payload cannot be changed', $$UPDATE public.pi_jobs SET payload='{"x":1}' WHERE idempotency_key='h:bo1'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q88 a job''s idempotency key cannot be changed', $$UPDATE public.pi_jobs SET idempotency_key='h:other' WHERE idempotency_key='h:bo1'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q89 a job''s attempt limit cannot be raised (no endless retries)', $$UPDATE public.pi_jobs SET max_attempts=20 WHERE idempotency_key='h:a'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q90 attempts cannot go backwards', $$UPDATE public.pi_jobs SET attempts=0 WHERE idempotency_key='h:bo3'$$, 'service_role', NULL, '55000');
SELECT pgtest.t('Q91 a queued job can be cancelled', $$UPDATE public.pi_jobs SET status='cancelled', finished_at=now() WHERE idempotency_key='h:bo1'$$, 'service_role');
SELECT pgtest.t('Q92 a running job can be cancelled (unlocked at the same time)', $$UPDATE public.pi_jobs SET status='cancelled', finished_at=now(), locked_by=NULL, locked_at=NULL, lease_expires_at=NULL WHERE idempotency_key='h:valid-running'$$, 'service_role');
SELECT pgtest.t('Q93 ordinary edits inside a state (priority of a queued job) are allowed', $$UPDATE public.pi_jobs SET priority=2 WHERE idempotency_key='h:bo3'$$, 'service_role');
SELECT pgtest.q('Q94 completing an already-finished job is refused', $$public.pi_complete_job((SELECT id FROM public.pi_jobs WHERE idempotency_key='h:done'),'anyone') = false$$, 'service_role');
SELECT pgtest.q('Q95 a cancelled job is never claimed', $$(SELECT count(*)=0 FROM public.pi_claim_jobs('hG',50,interval '1 minute',ARRAY['expire_restrictions']) WHERE idempotency_key='h:bo1')$$, 'service_role');

-- ===================================================================== R. audit-history consistency and case deletion
SELECT pgtest.t('R01 setup: a resolved case with an action, an appeal and an analysis', format($$
  INSERT INTO public.pi_moderation_cases (id, subject_type, subject_id, subject_user_id, source, status, resolution, resolved_at, primary_category)
    VALUES (%1$L,'post',%2$L,%3$L,'owner','resolved','violation_confirmed',now(),'spam_scams');
  INSERT INTO public.pi_content_analyses (id, case_id, subject_type, subject_id, subject_user_id, analysis_kind, content_hash, provider, outcome, risk_score)
    VALUES (%4$L,%1$L,'post',%2$L,%3$L,'text',repeat('f',64),'bmn_rules','violation_likely',0.9);
  INSERT INTO public.pi_moderation_actions (id, case_id, target_user_id, subject_type, subject_id, action_type, actor_type, actor_id, mode, user_visible_reason, analysis_id)
    VALUES (%5$L,%1$L,%3$L,'post',%2$L,'warn','owner',%6$L,'enforced','Test warning for hardening',%4$L);
  INSERT INTO public.pi_appeals (action_id, user_id, statement) VALUES (%5$L,%3$L,'I disagree with this warning, please review it.');
$$, pgtest.u(710), pgtest.u(711), pgtest.u(3), pgtest.u(712), pgtest.u(713), pgtest.u(1)), 'service_role');
SELECT pgtest.t('R02 setup: an OPEN case and an AWAITING_REVIEW case', format($$
  INSERT INTO public.pi_moderation_cases (id, subject_type, subject_id, source, status) VALUES (%1$L,'post',%3$L,'automated','open'), (%2$L,'post',%3$L,'automated','awaiting_review')
$$, pgtest.u(720), pgtest.u(721), pgtest.u(722)), 'service_role');
SELECT pgtest.t('R03 an OPEN case cannot be deleted (decision still pending)', format($$DELETE FROM public.pi_moderation_cases WHERE id=%L$$, pgtest.u(720)), 'service_role', NULL, 'P0001');
SELECT pgtest.t('R04 an AWAITING_REVIEW case cannot be deleted', format($$DELETE FROM public.pi_moderation_cases WHERE id=%L$$, pgtest.u(721)), 'service_role', NULL, 'P0001');
SELECT pgtest.q('R05 both pending cases still exist and nothing was audited for them', format($$(SELECT count(*)=2 FROM public.pi_moderation_cases WHERE id IN (%L,%L)) AND (SELECT count(*)=0 FROM public.pi_audit_log WHERE action='case_deleted' AND target_id IN (%L,%L))$$, pgtest.u(720), pgtest.u(721), pgtest.u(720)::text, pgtest.u(721)::text));
SELECT pgtest.q('R06 before deletion: the action and appeal point at the case', format($$(SELECT case_id=%L FROM public.pi_moderation_actions WHERE id=%L)$$, pgtest.u(710), pgtest.u(713)));
SELECT pgtest.t('R07 a RESOLVED case can be deleted (no failure from protected history)', format($$DELETE FROM public.pi_moderation_cases WHERE id=%L$$, pgtest.u(710)), 'service_role');
SELECT pgtest.q('R08 the moderation action SURVIVED with its case reference cleared and every other field intact', format($$(SELECT case_id IS NULL AND action_type='warn' AND target_user_id=%L AND subject_id=%L AND user_visible_reason='Test warning for hardening' AND analysis_id=%L FROM public.pi_moderation_actions WHERE id=%L)$$, pgtest.u(3), pgtest.u(711), pgtest.u(712), pgtest.u(713)));
SELECT pgtest.q('R09 the appeal on that action survived', format($$(SELECT count(*)=1 FROM public.pi_appeals WHERE action_id=%L)$$, pgtest.u(713)));
SELECT pgtest.q('R10 the content analysis survived with its case reference cleared', format($$(SELECT case_id IS NULL AND content_hash=repeat('f',64) FROM public.pi_content_analyses WHERE id=%L)$$, pgtest.u(712)));
SELECT pgtest.q('R11 the deletion was written to the audit log with what was deleted and how much history was kept', format($$(SELECT count(*)=1 AND bool_and(actor_type='service') AND bool_and(before_state->>'actions_retained'='1') AND bool_and(before_state->>'status'='resolved') AND bool_and(before_state->>'subject_id'=%L) FROM public.pi_audit_log WHERE action='case_deleted' AND target_id=%L)$$, pgtest.u(711)::text, pgtest.u(710)::text));
SELECT pgtest.t('R12 retained history is still immutable: action type cannot be rewritten', format($$UPDATE public.pi_moderation_actions SET action_type='no_action' WHERE id=%L$$, pgtest.u(713)), 'service_role', NULL, '42501');
SELECT pgtest.t('R13 retained history cannot be re-attached to a different case', format($$UPDATE public.pi_moderation_actions SET case_id=%L WHERE id=%L$$, pgtest.u(720), pgtest.u(713)), 'service_role', NULL, '42501');
SELECT pgtest.t('R14 retained history cannot be deleted', format($$DELETE FROM public.pi_moderation_actions WHERE id=%L$$, pgtest.u(713)), 'service_role', NULL, '42501');
SELECT pgtest.t('R15 an action can still be reversed exactly once after its case was deleted', format($$UPDATE public.pi_moderation_actions SET reversed_at=now(), reversed_by=%L, reversal_reason='mistake' WHERE id=%L$$, pgtest.u(1), pgtest.u(713)), 'service_role');
SELECT pgtest.t('R16 deleting a content analysis keeps the action that used it (reference cleared)', format($$DELETE FROM public.pi_content_analyses WHERE id=%L$$, pgtest.u(712)), 'service_role');
SELECT pgtest.q('R17 the action is still there with analysis_id cleared', format($$(SELECT analysis_id IS NULL AND action_type='warn' FROM public.pi_moderation_actions WHERE id=%L)$$, pgtest.u(713)));
-- audit-log protection (as the API role, and as a superuser who bypasses privileges)
SELECT pgtest.t('R20 service_role cannot UPDATE the audit log', $$UPDATE public.pi_audit_log SET reason='tampered'$$, 'service_role', NULL, '42501');
SELECT pgtest.t('R21 service_role cannot DELETE from the audit log', $$DELETE FROM public.pi_audit_log$$, 'service_role', NULL, '42501');
SELECT pgtest.t('R22 service_role cannot TRUNCATE the audit log', $$TRUNCATE public.pi_audit_log$$, 'service_role', NULL, '42501');
SELECT pgtest.t('R23 even a superuser cannot UPDATE the audit log (trigger)', $$UPDATE public.pi_audit_log SET reason='tampered'$$, NULL, NULL, '42501');
SELECT pgtest.t('R24 even a superuser cannot DELETE from the audit log (trigger)', $$DELETE FROM public.pi_audit_log$$, NULL, NULL, '42501');
SELECT pgtest.t('R25 even a superuser cannot TRUNCATE the audit log', $$TRUNCATE public.pi_audit_log$$, NULL, NULL, '42501');
SELECT pgtest.t('R26 a superuser cannot TRUNCATE moderation actions', $$TRUNCATE public.pi_moderation_actions CASCADE$$, NULL, NULL, '42501');
SELECT pgtest.t('R27 a superuser cannot TRUNCATE appeals', $$TRUNCATE public.pi_appeals$$, NULL, NULL, '42501');
SELECT pgtest.t('R28 a superuser cannot TRUNCATE verification decisions', $$TRUNCATE public.pi_verification_decisions CASCADE$$, NULL, NULL, '42501');
SELECT pgtest.t('R29 TRUNCATE ... CASCADE from the cases table cannot sweep away action history', $$TRUNCATE public.pi_moderation_cases CASCADE$$, NULL, NULL, '42501');
SELECT pgtest.q('R30 all history is still present after the blocked truncates', $$(SELECT count(*) FROM public.pi_moderation_actions) > 0 AND (SELECT count(*) FROM public.pi_appeals) > 0 AND (SELECT count(*) FROM public.pi_audit_log) > 0 AND (SELECT count(*) FROM public.pi_moderation_cases) > 0$$);
-- verification history
SELECT pgtest.t('R40 an evaluation that a decision relies on cannot be deleted on its own', format($$DELETE FROM public.pi_verification_evaluations WHERE id=%L$$, pgtest.u(401)), 'service_role', NULL, '23503');
SELECT pgtest.t('R41 setup: an evaluation with no decision', format($$INSERT INTO public.pi_verification_evaluations (id, verification_request_id, user_id, criteria_version, checks, outcome) VALUES (%L,%L,%L,1,'[{"check":"a","result":"fail"}]','insufficient_evidence')$$, pgtest.u(730), pgtest.u(731), pgtest.u(3)), 'service_role');
SELECT pgtest.t('R42 an evaluation nobody relied on can be deleted', format($$DELETE FROM public.pi_verification_evaluations WHERE id=%L$$, pgtest.u(730)), 'service_role');
SELECT pgtest.t('R43 verification decisions cannot be deleted through the API', $$DELETE FROM public.pi_verification_decisions$$, 'service_role', NULL, '42501');
SELECT pgtest.t('R44 verification decisions cannot be edited through the API', $$UPDATE public.pi_verification_decisions SET reason='x'$$, 'service_role', NULL, '42501');

-- ===================================================================== P. privileges and role permissions
SELECT pgtest.q('P01 service_role has none of TRUNCATE / REFERENCES / TRIGGER on any pi_ table', $$NOT EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['TRUNCATE','REFERENCES','TRIGGER']) p WHERE c.relnamespace='public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind='r' AND has_table_privilege('service_role', c.oid, p))$$);
SELECT pgtest.q('P02 audit log: service_role has exactly SELECT + INSERT', $$has_table_privilege('service_role','public.pi_audit_log','SELECT') AND has_table_privilege('service_role','public.pi_audit_log','INSERT') AND NOT has_table_privilege('service_role','public.pi_audit_log','UPDATE') AND NOT has_table_privilege('service_role','public.pi_audit_log','DELETE')$$);
SELECT pgtest.q('P03 moderation actions: no DELETE for service_role', $$has_table_privilege('service_role','public.pi_moderation_actions','UPDATE') AND NOT has_table_privilege('service_role','public.pi_moderation_actions','DELETE')$$);
SELECT pgtest.q('P04 appeals: no DELETE for service_role', $$NOT has_table_privilege('service_role','public.pi_appeals','DELETE')$$);
SELECT pgtest.q('P05 verification decisions and schema version: insert-only for service_role', $$NOT has_table_privilege('service_role','public.pi_verification_decisions','UPDATE') AND NOT has_table_privilege('service_role','public.pi_verification_decisions','DELETE') AND NOT has_table_privilege('service_role','public.pi_schema_version','UPDATE') AND NOT has_table_privilege('service_role','public.pi_schema_version','DELETE')$$);
SELECT pgtest.q('P06 anon has no privilege of any kind on any pi_ table', $$NOT EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p WHERE c.relnamespace='public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind='r' AND has_table_privilege('anon', c.oid, p))$$);
SELECT pgtest.q('P07 authenticated has SELECT only (RLS filters it to the owner)', $$NOT EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p WHERE c.relnamespace='public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind='r' AND has_table_privilege('authenticated', c.oid, p))$$);
SELECT pgtest.q('P08 trigger / helper functions are not executable by anon, authenticated or service_role', $$NOT EXISTS (SELECT 1 FROM unnest(ARRAY['pi_audit_guard()','pi_block_truncate()','pi_cases_guard_delete()','pi_jobs_guard()','pi_actions_guard()','pi_touch_updated_at()','pi_policy_bump_version()']) f, unnest(ARRAY['anon','authenticated','service_role']) r WHERE has_function_privilege(r, ('public.'||f)::regprocedure, 'EXECUTE'))$$);
SELECT pgtest.q('P09 only the two user-facing functions are executable by authenticated', $$(SELECT count(*) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE 'pi\_%' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 2$$);
SELECT pgtest.q('P10 anon can execute no pi_ function at all', $$(SELECT count(*) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE 'pi\_%' AND has_function_privilege('anon', p.oid, 'EXECUTE')) = 0$$);
SELECT pgtest.q('P11 SECURITY DEFINER functions pin search_path', $$NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'pi\_%' AND prosecdef AND (proconfig IS NULL OR proconfig::text NOT LIKE '%search_path%'))$$);
SELECT pgtest.q('P12 RLS on every pi_ table (re-check after hardening)', $$(SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname LIKE 'pi\_%' AND relkind='r' AND relrowsecurity) = 16$$);
SELECT pgtest.q('P13 ordinary users see no jobs and no audit rows; the owner sees both', $$(SELECT count(*) FROM public.pi_jobs) + (SELECT count(*) FROM public.pi_audit_log) = 0$$, 'authenticated', pgtest.u(2));
SELECT pgtest.q('P14 owner can read the jobs and the case_deleted audit entry', $$(SELECT count(*) > 0 FROM public.pi_jobs) AND (SELECT count(*) > 0 FROM public.pi_audit_log WHERE action='case_deleted')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.t('P15 a non-owner cannot call pi_decide_appeal as themselves', format($$SELECT public.pi_decide_appeal(%L, (SELECT id FROM public.pi_appeals LIMIT 1), 'upheld', 'note')$$, pgtest.u(2)), 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('P16 authenticated cannot claim jobs', $$SELECT * FROM public.pi_claim_jobs('x',1)$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('P17 authenticated cannot delete a case', $$DELETE FROM public.pi_moderation_cases$$, 'authenticated', pgtest.u(1), '42501');

SELECT pgtest.q('P18 every history table (audit, actions, appeals, decisions) has an enabled BEFORE TRUNCATE guard', $$(SELECT count(DISTINCT c.relname) = 4 FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid WHERE c.relname IN ('pi_audit_log','pi_moderation_actions','pi_appeals','pi_verification_decisions') AND (g.tgtype & 32) = 32 AND (g.tgtype & 2) = 2 AND g.tgenabled = 'O' AND NOT g.tgisinternal)$$);

-- ===================================================================== E. existing BMN app still works with Platform Intelligence installed
SELECT pgtest.t('E01 a normal user can still create a post', format($$INSERT INTO public.posts (user_id, title, caption, status) VALUES (%L,'compat post','c','published')$$, pgtest.u(2)), 'authenticated', pgtest.u(2));
SELECT pgtest.t('E02 the API role can still comment', format($$INSERT INTO public.comments (user_id, post_id, body, content) VALUES (%L,'00000000-0000-0000-0000-0000000a0002','compat','compat')$$, pgtest.u(2)), 'service_role');
SELECT pgtest.t('E03 the API role can still like', format($$INSERT INTO public.likes (user_id, post_id) VALUES (%L,'00000000-0000-0000-0000-0000000a0002')$$, pgtest.u(2)), 'service_role');
SELECT pgtest.t('E04 the API role can still follow', format($$INSERT INTO public.follows (follower_id, following_id) VALUES (%L,%L)$$, pgtest.u(2), pgtest.u(1)), 'service_role');
SELECT pgtest.t('E05 the API role can still send a message', format($$INSERT INTO public.messages (sender_id, recipient_id, content) VALUES (%L,%L,'compat hi')$$, pgtest.u(2), pgtest.u(1)), 'service_role');
SELECT pgtest.t('E06 a normal user can still report a post', format($$INSERT INTO public.content_reports (reporter_id, post_id, reported_user_id, reason, details) VALUES (%L,'00000000-0000-0000-0000-0000000a0002',%L,'spam','compat report')$$, pgtest.u(2), pgtest.u(3)), 'authenticated', pgtest.u(2));
SELECT pgtest.q('E07 is_bmn_owner() still true for the owner and false for a normal user', $$public.is_bmn_owner()$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('E08 is_bmn_owner() is false for a normal user', $$NOT public.is_bmn_owner()$$, 'authenticated', pgtest.u(2));
SELECT pgtest.q('E09 no pi_ object sits in any non-public schema or collides with a baseline object name', $$NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relname LIKE 'pi\_%' AND c.relnamespace <> 'public'::regnamespace)$$);
