# BMN Platform Intelligence — Batch 1: database schema

**Status: reviewed-ready, NOT deployed, NOT applied to any Supabase project.** Everything below was run only against a disposable local PostgreSQL 16. Safe to commit to GitHub (nothing here runs on Vercel or Render by itself).

## 1. Files inspected
`supabase/migrations/20261102090000_bmn_baseline.sql` (all tables, functions, RLS, FKs, triggers), the 7 loose `*.sql` files (`migration-REVIEW-FIRST.sql`, `creator-payout-accounts.sql`, `bmn-supabase-social-features.sql`, views/realtime/comments fixes), every `.from()` / `.rpc()` / `storage.from()` call in `index.html`, `server.js`, `routes/*.js`, `supabase.js`, `api/chat.js`, `package.json`, `.vercelignore`, `vercel.json`, `docs/VIDEO_PIPELINE.md`, `README-R2-SETUP.md`, and the full git history (266 commits).

## 2. Files created (all NEW)
| Path | Purpose |
|---|---|
| `platform-intelligence/db/migrations/001_pi_schema.up.sql` | Forward migration (16 tables, 1 domain, 13 functions, indexes, RLS, grants, OFF-by-default flags) |
| `platform-intelligence/db/migrations/001_pi_schema.down.sql` | Rollback; refuses to delete data unless `SET pi.confirm_rollback = 'yes'` |
| `platform-intelligence/db/run_db_tests.sh` | One-command runner (local DB only; refuses remote hosts) |
| `platform-intelligence/db/tests/00_supabase_shim.sql` | Test-only Supabase emulation (roles, `auth.uid()`, `auth.role()`) |
| `platform-intelligence/db/tests/10_seed_baseline_data.sql` | Test-only rows in existing BMN tables (never run on production) |
| `platform-intelligence/db/tests/15_test_harness.sql` | Test-only assertion helpers + schema/data fingerprints |
| `platform-intelligence/db/tests/20_pi_tests.sql` | 160+ assertions |
| `platform-intelligence/db/TEST_RESULTS.txt` | Real output of the final run |
| `platform-intelligence/docs/PROVIDER_COMPARISON.md` | AI provider research (no provider chosen) |
| `platform-intelligence/README.md` | This report |

## 3. Files modified
`.vercelignore` — **MODIFIED**, +1 pattern (`platform-intelligence/`). Vercel serves the repo root as static files, so without this the new folder (docs, test scripts) would be publicly downloadable. (`*.sql` and `docs/` were already ignored, but not the README or the script.)
No existing application file, table, function, policy or trigger is changed. `index.html`, `sw.js`, `manifest.webmanifest` untouched.

## 4. Database changes (additive, reversible)
Nothing is created outside the `pi_` namespace and nothing existing is altered. New tables:
`pi_feature_flags`, `pi_policies`, `pi_moderation_cases`, `pi_content_analyses`, `pi_moderation_actions`, `pi_appeals`,
`pi_account_risk_assessments`, `pi_security_events`, `pi_protective_restrictions`, `pi_verification_evaluations`,
`pi_verification_decisions`, `pi_ai_provider_usage`, `pi_provider_health`, `pi_jobs`, `pi_audit_log`, `pi_schema_version`.

Design decisions:
- Production is the source of truth; the migration has no foreign keys to existing social-content tables.
- Account deletion keeps working through `CASCADE` or `SET NULL` foreign keys.
- Automated systems cannot perform irreversible actions such as banning or suspending accounts.
- Automatic verification approval requires every recorded check to pass.
- Provider errors and unknown costs are recorded honestly, not guessed.
- Privacy protections use content hashes and keyed IP/device hashes.
- Every table has RLS; writes go through the API using the service key.
- All feature flags are OFF by default, and policy categories are disabled.
- Background jobs use leases, priorities, idempotency keys and retry handling.

## 5. Tests performed — exact results
`platform-intelligence/db/TEST_RESULTS.txt` has every line. Final run: **182 total, 182 passed, 0 failed** on PostgreSQL 16.15.

Highlights:
- Existing schema and rows remained identical before and after migration and rollback.
- The migration was tested for repeat execution.
- Rollback refused to run without confirmation.
- Account deletion was tested against a user with rows in nine `pi_` tables.
- Four deliberately weakened migration copies were caught by the test suite.

## 6. Known failures and limitations
- Tested on PostgreSQL 16 with an emulated Supabase, not Supabase's PostgreSQL 17 or real JWT authentication.
- Concurrent job claiming has not yet been load-tested.
- No performance or scale testing has been performed.
- Production may contain objects not visible during the inspection.

## 7. Security considerations
The service-role key stays on Render only. `pi_` tables are invisible to ordinary users. Owner-only reads rely on `bmn_admins.role='owner'`. The unrelated `api/chat.js` OpenAI proxy is unauthenticated and should stay excluded from Vercel.

## 8. Deployment instructions — DO NOT run yet
1. Upload these files to GitHub. Nothing deploys from this folder by itself.
2. Wait for approval. Then create a Supabase branch or restored copy and test `001_pi_schema.up.sql` there.
3. Production only after the copy test passes and Batches 2–3 exist.

## 9. Safe to deploy?
**Yes to commit the files. No to applying to production yet.** Do not run the migration on production until the copy test passes and you approve.

## Render start-command finding (not changed)
`package.json` says `"start": "node src/server.js"`, but `src/server.js` has never existed in the 266 commits inspected. The entry file is `server.js` at the repository root. There is no `render.yaml`, `Procfile` or `Dockerfile` in the repo, so Render may be using a custom Start Command. This is unconfirmed until checked in the Render dashboard.

Please check Render → your API service → Settings → Build & Deploy: Root Directory and Start Command, and provide a screenshot or the text. `package.json` has not been edited.
