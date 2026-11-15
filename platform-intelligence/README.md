# BMN Platform Intelligence — Batch 1: database schema

**Status: reviewed-ready, NOT deployed, NOT applied to any Supabase project.** Everything below was run only against a
disposable local PostgreSQL 16. Safe to commit to GitHub (nothing here runs on Vercel or Render by itself).

## 1. Files inspected
`supabase/migrations/20261102090000_bmn_baseline.sql` (all tables, functions, RLS, FKs, triggers), the 7 loose `*.sql` files
(`migration-REVIEW-FIRST.sql`, `creator-payout-accounts.sql`, `bmn-supabase-social-features.sql`, views/realtime/comments fixes),
every `.from()` / `.rpc()` / `storage.from()` call in `index.html`, `server.js`, `routes/*.js`, `supabase.js`, `api/chat.js`,
`package.json`, `.vercelignore`, `vercel.json`, `docs/VIDEO_PIPELINE.md`, `README-R2-SETUP.md`, and the full git history (266 commits).

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
`.vercelignore` — **MODIFIED**, +1 pattern (`platform-intelligence/`). Vercel serves the repo root as static files, so without this the new
folder (docs, test scripts) would be publicly downloadable. (`*.sql` and `docs/` were already ignored, but not the README or the script.)
No existing application file, table, function, policy or trigger is changed. `index.html`, `sw.js`, `manifest.webmanifest` untouched.

## 4. Database changes (additive, reversible)
Nothing is created outside the `pi_` namespace and nothing existing is altered. New tables:
`pi_feature_flags`, `pi_policies`, `pi_moderation_cases`, `pi_content_analyses`, `pi_moderation_actions`, `pi_appeals`,
`pi_account_risk_assessments`, `pi_security_events`, `pi_protective_restrictions`, `pi_verification_evaluations`,
`pi_verification_decisions`, `pi_ai_provider_usage`, `pi_provider_health`, `pi_jobs`, `pi_audit_log`, `pi_schema_version`.

Design decisions, driven by your requirements and by what the existing schema does:
- **Production is the source of truth.** The baseline is missing tables the app uses (`reposts`, `creator_tips`, `creator_payout_accounts`, `user_settings`, `user_blocks`, `media_assets`), so production has more than the baseline. The migration therefore has **no foreign keys to posts / comments / messages / reports / verification tables** (plain `subject_type` + `subject_id`), depends only on `auth.users`, `bmn_admins`, `is_bmn_owner()` and the 3 Supabase roles, and **aborts if those are absent or if any unrelated `pi_*` object already exists**.
- **Account deletion keeps working.** `bmn_delete_my_account()` ends with `DELETE FROM auth.users`; every pi_ foreign key is `CASCADE` or `SET NULL`. Proven by running the real function in the tests: personal pi_ rows are erased, moderation history is anonymised, audit log survives.
- **Automation cannot do irreversible harm — enforced by the database, not just code.** System actor cannot `ban`, `suspend`, `remove_content` or `revoke_verification`; automated holds/restrictions must expire; policies cannot even be *configured* to allow those; severe human actions require a user-visible reason; action history is immutable (only a one-time reversal may be written); audit log is append-only (no update, delete or truncate).
- **Verification honesty.** `eligible_for_auto_approval` is only storable if every recorded check is `pass` (empty list rejected); system may approve (with a passing evaluation) or refer to a human, never reject or revoke; fraud flag only on revocations.
- **No invented results.** A "clear" analysis must carry a score; a provider error must record the error; cost may be NULL (basis `unknown`) but never a guess.
- **Privacy.** Only SHA-256 hashes of content (no raw text); only keyed hashes of IPs/devices (raw IPs are rejected by constraint).
- **Access.** RLS on every table; owner may `SELECT` (server-side `is_bmn_owner()`), nobody writes through client roles; writes go through the API with the service key. Users get exactly two functions: `pi_my_moderation_notices()` (safe columns only, enforced actions only) and `pi_submit_appeal()`. `pi_decide_appeal()` re-checks owner status inside the database.
- **Ships OFF.** All 8 feature flags false; all 10 policy categories disabled with automatic action `none`; no seeded activity.
- **Queue:** `pi_claim_jobs` (`FOR UPDATE SKIP LOCKED`, leases, priority), `pi_complete_job`, `pi_fail_job` (exponential back-off, dead-letter), idempotency keys everywhere.

## 5. Tests performed — exact results
`platform-intelligence/db/TEST_RESULTS.txt` has every line. Final run: **182 total, 182 passed, 0 failed** on PostgreSQL 16.15
(real baseline loaded, seeded with rows in existing tables). Highlights:
- BMN schema fingerprint identical before UP and after DOWN; every existing row identical after UP and after DOWN.
- UP is idempotent (run twice; also re-run on a DB holding data: data and edited policy kept).
- Rollback refused without confirmation and removed nothing; confirmed rollback removed all 16 tables, functions and the domain; UP→DOWN→UP cycle clean.
- Real `bmn_delete_my_account()` run against a user with rows in 9 pi_ tables.
- **Mutation check:** four deliberately sabotaged copies of the migration (weakened automation limit, broken RLS, removed audit trigger, over-broad grants) were each caught by the suite (4, 8, 2 and 3 failures). The suite found one real migration bug during development (fixed).

**Needing a real device — none apply to Batch 1** (database only). No iPhone/Safari/Android testing was done or needed here.

## 6. Known failures and limitations
- Tested on **PostgreSQL 16 with an emulated Supabase**, not on Supabase's PostgreSQL 17 and not through PostgREST/GoTrue/real JWTs. Run on a Supabase branch or restored copy before production.
- Workers were tested **sequentially**; true parallel claiming (`SKIP LOCKED` under concurrent sessions) is not yet load-tested.
- No performance/scale testing; indexes are designed, not benchmarked.
- No retention/purge job logic yet (job type exists; Batch 3). No triggers on existing tables yet — enqueueing will come from the API (Batch 3); DB triggers on `posts`/`comments` would modify existing tables and would be a separate, optional migration 002.
- Production may already contain objects I cannot see. The migration's preconditions guard against name collisions, not against every possible difference.

## 7. Security considerations
Service-role key stays on Render only. `pi_` tables are invisible to anon and to ordinary users. Owner-only reads rely on `bmn_admins.role='owner'` — protect who can write that table. `pi_my_moderation_notices` never exposes scores, notes, policy or actor. The `api/chat.js` OpenAI proxy in the repo is unauthenticated and currently excluded from Vercel by `.vercelignore`; it is unrelated to this batch but should stay excluded.

## 8. Deployment instructions — DO NOT run yet
1. Upload the files above to the repo (nothing deploys; Vercel ignores the folder, Render does not read it).
2. Wait for your approval. Then: create a **Supabase branch or a restored copy**, run `001_pi_schema.up.sql` there in the SQL editor, confirm it ends with `COMMIT` and no errors, and check `select * from pi_feature_flags` (all `false`).
3. Production only after that and after Batches 2–3 exist to use it. Rollback = run `001_pi_schema.down.sql` (export first if data exists).

## 9. Safe to deploy?
**Yes to commit the files. No to applying to production yet** — not until the branch/restored-copy check in step 2 passes and you approve.

## Render start-command finding (not changed)
`package.json` says `"start": "node src/server.js"`, but `src/server.js` has **never existed in any of the 266 commits**; the entry file is `server.js` at the repo root (its `require('./supabase')`, `./routes/media`, `./routes/tips` paths only work from there). Running `node src/server.js` here fails with `Cannot find module`. There is no `render.yaml`, `Procfile` or `Dockerfile` in the repo, so Render must be using a custom Start Command (probably `node server.js`) set in its dashboard, but **I cannot see the dashboard, so this is unconfirmed**. `README-R2-SETUP.md` also tells you to "confirm the deployed API's actual entry point", and `docs/VIDEO_PIPELINE.md` mentions a Render worker, `video-keys.js` and `Dockerfile.worker` that are not in the repo. **Please check Render → your API service → Settings → Build & Deploy: Root Directory and Start Command, and send me a screenshot or the text.** I have not edited `package.json`.
