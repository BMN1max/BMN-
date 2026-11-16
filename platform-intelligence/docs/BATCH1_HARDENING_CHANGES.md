# Batch 1 hardening: change report

Scope: review and harden the Batch 1 migration and tests. Nothing was applied to production Supabase, nothing was deployed, no AI automation
was activated, all feature flags and policies still ship OFF. Batch 2 has **not** been started.

## Test results (actually executed)
`db/run_db_tests.sh` on a disposable local **PostgreSQL 16.15** with an emulated Supabase and the real baseline schema:
**418 checks, 418 passed, 0 failed** (previous Batch 1 run: 182). Full output: `db/TEST_RESULTS.txt`.
The checks cover: fresh migration, safe re-run, partial-installation detection (20 damage cases x 4 checks each), invalid worker leases,
invalid retry settings, job claiming and lease expiry (real 1-second leases that really expire), retry limits, audit-log protection,
case deletion, rollback safety, RLS and role permissions, and compatibility with the existing BMN database.

**Mutation check (also executed):** 10 deliberately broken copies of the new migration were run through the same suite; every one was caught
(failures per copy: lease validation removed 5, retry validation removed 3, open cases deletable 2, case deletion cascading 5, audit log
over-granted 2, job state machine off 5, lock constraint weakened 3, truncate guard removed 1, max_attempts unbounded 1, evaluation cascade 1).
After that run one extra test (P18) was added for the truncate guards; it was included in the final 418.

**Not tested here (needs another environment):** Supabase's own PostgreSQL 17, PostgREST/GoTrue/real JWTs, concurrent workers under load,
production data. No iPhone/Safari/Android testing is relevant to this database-only batch.

## Fix 1: migration collision and partial-install protection
Problem: v1 only checked whether `pi_schema_version` existed, and `CREATE ... IF NOT EXISTS` would silently accept a half-built or altered install.

| Change | File |
|---|---|
| A manifest of every expected pi_ object (tables, RLS flag, columns with type/nullability/identity, constraint names and kinds, indexes, triggers incl. enabled state, policies, domains, function signature + SECURITY DEFINER flag + volatility + search_path + MD5 of the body, EXECUTE rights for anon/authenticated/service_role, table privileges) is embedded in the migration | `001_pi_schema.up.sql` |
| Before changing anything the database is classified: nothing named pi_ = fresh install; exactly the expected install = safe re-run; **anything else (missing, altered, extra, newer version, v1 draft, foreign table) = stop with a list of the first 15 differences, nothing changed** | same |
| After installing, the same comparison runs again; any difference raises and the whole migration rolls back | same |
| The version row alone no longer proves anything; a complete structure with no version row is refused too | same |
| `tools/refresh_manifest.py --write/--check` generates the manifest from a real install on a scratch local database (never hand-edited); the test suite fails if it is stale | NEW `db/tools/refresh_manifest.py` |
| Rollback: if pi_ objects exist but `pi_schema_version` is missing it refuses unless `SET pi.confirm_partial_cleanup = 'yes'`; in that mode every named table is counted as data; new objects added to the drop list; it only ever drops objects with the exact names migration 001 creates | `001_pi_schema.down.sql` |

Deliberate limits: constraint *definitions* are not hashed (PostgreSQL 16 vs 17 print them differently); constraint names + kinds are. Function bodies are hashed, so
editing a body is detected. A database holding the first draft must be rolled back (no data was ever in it) and re-installed; the hardened UP refuses to run over it.

## Fix 2: job-queue safety
| Rule | Where |
|---|---|
| `pi_claim_jobs`: worker 1..200 chars; limit 1..100; lease NOT NULL and 1 second..1 hour (zero, negative, NULL, sub-second, over an hour all rejected, SQLSTATE 22023); type filter NULL or a non-empty list of known types with no NULLs | function |
| `pi_fail_job`: retry delay NULL (automatic back-off 10 s, 20 s, 40 s ... capped at 1 h) or 1 second..7 days; worker not blank; blank error stored as "unspecified error"; validation runs before the lookup | function |
| Job types come from one domain `pi_job_type` (no duplicated list) | NEW domain |
| `max_attempts` 1..20; `attempts` >= 0 and <= `max_attempts`; running means worker, lock time and lease are all set, otherwise all NULL; lease must end after it starts; running implies at least one attempt; worker id not blank and <= 200 chars; finished time set exactly for succeeded / dead / cancelled | named CHECK constraints |
| Transition guard trigger: succeeded, dead, cancelled are final; only queued->running, running->queued/succeeded/dead/cancelled, queued->cancelled allowed; type, payload, idempotency key, attempt limit and creation time cannot change; attempts never go down (SQLSTATE 55000) | NEW `pi_jobs_guard` |
| An expired lease on the final attempt is dead-lettered; a reclaimed lease is noted in `last_error` | function |

## Fix 3: audit-history consistency
Finding: deleting a case failed with a permission error, because `pi_moderation_actions.case_id` was `ON DELETE CASCADE` while the action-history trigger forbids deleting actions.
(The audit log itself has no foreign keys, so it was not the blocker.) Now:

| Change | Effect |
|---|---|
| `pi_moderation_actions.case_id` is nullable, `ON DELETE SET NULL`; the history guard allows a case reference to be *cleared* but never changed or re-attached | deleting a case keeps every action, appeal and analysis; they just lose the link |
| `pi_cases_guard_delete` (BEFORE DELETE on cases): refuses cases that are `open` or `awaiting_review`; otherwise writes an audit entry `case_deleted` (subject, status, resolution, category, number of actions kept) | deletion is never silent and never destroys a pending decision |
| BEFORE TRUNCATE guards on actions, appeals and verification decisions (audit log already had one) | `TRUNCATE ... CASCADE` cannot wipe history, even for a superuser |
| `pi_verification_decisions.evaluation_id` changed from CASCADE to NO ACTION | an evaluation a decision relies on cannot be deleted alone; account deletion (removes both together) still works, proven with the real `bmn_delete_my_account()` |
| Privileges are now explicit and exact for service_role (previously "ALL" through defaults, including TRUNCATE): audit log and verification decisions and schema version SELECT+INSERT; actions and appeals SELECT+INSERT+UPDATE; others SELECT+INSERT+UPDATE+DELETE; no TRUNCATE/REFERENCES/TRIGGER anywhere; functions revoked from everyone then granted individually | privilege state no longer depends on Supabase default privileges |

Retention and privacy rules: account deletion still erases personal pi_ rows (appeals, risk assessments, security events, restrictions, evaluations, verification
decisions); action and case history is kept anonymised (target set to NULL); the audit log is kept and holds only pseudonymous ids. No history is deleted silently.

## Other file changes
| File | Status | What changed |
|---|---|---|
| `db/migrations/001_pi_schema.up.sql` | MODIFIED | everything above |
| `db/migrations/001_pi_schema.down.sql` | MODIFIED | partial-cleanup gate, new objects |
| `db/run_db_tests.sh` | MODIFIED | manifest check, hardening tests, 20-case damage matrix, foreign-object and first-draft upgrade scenarios, post-install-verification test, baseline comparison, clone cleanup |
| `db/tests/15_test_harness.sql` | MODIFIED | `pgtest.pi_fp()` installation fingerprint |
| `db/tests/20_pi_tests.sql` | MODIFIED | crash simulation sets lock time too (new constraint); account-deletion test now includes a verification decision |
| `db/tests/30_pi_hardening_tests.sql` | NEW | job queue, history, privileges, BMN-compat tests |
| `db/tests/fixtures/001_pi_schema.v1_draft.up.sql` | NEW | the first draft, test fixture only |
| `db/tools/refresh_manifest.py` | NEW | manifest generator / checker |
| `db/TEST_RESULTS.txt`, `README.md` | MODIFIED | results and description |
| `docs/PRODUCTION_COMPATIBILITY.md` | NEW | remaining risks |
