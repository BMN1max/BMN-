# BMN Platform Intelligence — Batch 2 (engine, workers, owner console)

**Status: built and tested locally. NOT applied to production. Everything is OFF until you switch it on.**
Nothing in this batch can ban or delete an account, permanently remove content, or revoke verification. Automation only *recommends*;
serious actions need your decision in the console, and every decision is written to the audit log.

## 1. What was added (destination path in the GitHub repo)

| Status | Path | What it does |
|---|---|---|
| NEW | `platform-intelligence/db/migrations/002_pi_engine.up.sql` | **SQL migration.** Adds the policy engine, rule-set versions, decision/audit trail, jobs support, investigations, alerts, worker heartbeats, owner functions, and the `verification_evaluation` flag (OFF). Additive: no existing BMN table or row is changed. Safe to run twice. |
| NEW | `platform-intelligence/db/migrations/002_pi_engine.down.sql` | Rollback. Refuses to run if the new tables hold data unless you explicitly confirm. |
| NEW | `platform-intelligence/db/tests/40_pi_engine_tests.sql`, `db/run_db_tests_002.sh` | Database test suite (developer use; runs on a throw-away local database only). |
| NEW | `platform-intelligence/db/TEST_RESULTS_BATCH2.txt` | Test output (see section 5). |
| NEW | `platform-intelligence/server/index.js` | Entry point `createPlatformIntelligence()` used by `server.js`. |
| NEW | `platform-intelligence/server/store.js` | Thin wrapper over the database functions (service role, server side only). |
| NEW | `platform-intelligence/server/handlers.js` | Job handlers: analyse content, assess account, evaluate verification, reverse expired holds. |
| NEW | `platform-intelligence/server/worker.js` | Background worker: sweepers, job leases, retries, dead-lettering, heartbeat, health checks. Never overlaps itself; stops on emergency halt. |
| NEW | `platform-intelligence/server/worker-main.js` | Optional standalone worker (Render Background Worker). |
| NEW | `platform-intelligence/server/owner-routes.js`, `router.js` | Owner API (27 endpoints, validated) and the `POST /api/pi/session` beacon. |
| NEW | `platform-intelligence/server/engines/moderation.js` | Text + metadata analysis: spam/scam/phishing, threats, insults, engagement manipulation, dangerous-goods phrases, impersonation of verified names, duplicate flooding. |
| NEW | `platform-intelligence/server/engines/account.js` | Account risk: follow/post/comment/message bursts, many networks/devices, shared devices, reports, repeat violations. Temporary restrictions only (max 72 h, with expiry). |
| NEW | `platform-intelligence/server/engines/verification.js` | Checks a request against the recorded criteria. Can only say "eligible", "needs human review" or "insufficient evidence" — never reject or revoke. |
| NEW | `platform-intelligence/server/providers/openai-moderation.js` | OPTIONAL external AI adapter. Off unless `OPENAI_API_KEY` is set **and** you switch on `ai_providers`. Never used for private messages. |
| NEW | `platform-intelligence/server/rules/defaults.js`, `lib/util.js`, `lib/text.js` | Built-in rule set v1, helpers. |
| NEW | `platform-intelligence/server/test/*` | Unit, integration, and browser tests + the local test-DB builder. |
| NEW | `bmn-intelligence.js` (repo root) | Frontend: session beacon + owner-only **Intelligence** console (Overview, Moderation, Accounts, Verification, Alerts, Appeals, Audit, Controls). No secrets inside. |
| MODIFIED | `server.js` | Mounts `/api/pi` (guarded: if it fails to start, the rest of the API keeps running), allows the `X-BMN-Device` header in CORS, optional in-process worker. 4 small additions, nothing removed. |
| MODIFIED | `index.html` | **One added line** before `</body>`: `<script src="/bmn-intelligence.js" defer></script>` (see 3c). |

Not changed: Batch 1 files (`001_*`), media/R2, tips, Supabase client, every other file.

## 2. Render environment variable NAMES (set values yourself; never paste secrets into GitHub)

| Name | Required? | Meaning |
|---|---|---|
| `PI_HASH_KEY` | for the session beacon | A long random secret (24+ characters). Used to hash IP/device ids before storage. Without it the beacon silently does nothing. |
| `PI_WORKER_ENABLED` | no (default off) | `true` runs the worker inside the web service. Alternative: run `worker-main.js` as a Render Background Worker instead (do not need both). |
| `OPENAI_API_KEY` | no | Only if you want the optional AI moderation adapter. **Cost/approval: not activated by this batch.** It also needs the `ai_providers` switch ON. I did not verify OpenAI's current pricing or rate limits — check them before enabling. |
| `PI_OPENAI_MODEL`, `PI_WORKER_ID` | no | Optional overrides. |

Existing variables (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ALLOWED_ORIGINS`, …) are unchanged.

## 3. Upload / apply steps (iPhone friendly), in this order

**a. Back up first.** Supabase → Database → Backups (or Settings → Database). Do not skip.
**b. Check Batch 1 is applied:** Supabase → SQL Editor, run `select max(version) from public.pi_schema_version;` — it must return `1` (or `2` if you already ran 002). If the table does not exist, Batch 1 (`001_pi_schema.up.sql`) has not been applied yet; stop and tell me.
**c. Apply migration 002 (needs your OK):** open `002_pi_engine.up.sql` in GitHub → "Raw" → select all → copy → Supabase SQL Editor → paste → Run. Expected: success with no error; running it a second time is harmless. To undo: run `002_pi_engine.down.sql` (it refuses if data exists unless `SET pi.confirm_rollback='yes';` is run first).
**d. GitHub → code files:** In each folder use *Add file → Upload files* (same names replace the old ones):
 - repo root: `server.js` (MODIFIED, replaces), `bmn-intelligence.js` (NEW)
 - `platform-intelligence/server/` : index.js, store.js, handlers.js, worker.js, worker-main.js, owner-routes.js, router.js
 - `platform-intelligence/server/engines/` : moderation.js, account.js, verification.js
 - `platform-intelligence/server/providers/` : openai-moderation.js
 - `platform-intelligence/server/rules/` : defaults.js · `platform-intelligence/server/lib/` : util.js, text.js
 - `platform-intelligence/server/test/` : the 5 test files (optional, not needed to run the site)
 - `platform-intelligence/db/` etc. as in the table (optional documentation/tests)
 - To create a folder on iPhone: *Add file → Create new file*, type `platform-intelligence/server/engines/x.txt` as the name, then upload into it. A ZIP of exactly these files (with paths) is also provided as an extra.
**e. `index.html`:** open it in GitHub, press the pencil (Edit), scroll to the very end, and just above `</body>` add this single line, then commit:
`<script src="/bmn-intelligence.js" defer></script>` (A full replacement `index.html` is also provided but only use it if your GitHub copy is identical to the ZIP you gave me.)
**f.** Render redeploys by itself. In Render → Environment add `PI_HASH_KEY` (and `PI_WORKER_ENABLED=true` when you are ready for the worker).
**g.** Open the app as owner → Profile → **Intelligence**.

## 4. Switching it on (one step at a time; every switch asks for a reason and is audited)

All switches start OFF. Suggested order in Intelligence → Controls: `moderation_analysis` → enable one category policy at a time → `account_risk_scoring` → `verification_evaluation` → (later, if you decide) `auto_verification`. Watch Overview and Audit between steps.
**Shadow mode:** in this version *every* automated decision is shadow-only (recorded with reasons, nothing is hidden or applied), because the enforcement hooks are not installed. Enforcement would require an optional migration 003, which I have **not** written and which would need your explicit approval.
Emergency stop: switch on `emergency_halt_automation` — workers stop at once.

## 5. Tests

**Actually run (local disposable PostgreSQL 16 + Node 22 + headless Chromium):**
- Database migration 002: **361 checks, 0 failed** (clean install/rollback restores the exact Batch 1 state, idempotent re-run, damaged-install matrix, rollback with data, safety rules, privilege checks) + **305 Batch 1 regression checks, 0 failed**. Two deliberate rule-breaking mutations were confirmed to be caught.
- Node unit tests: **38 pass** (engines never recommend a destructive action for any input; verification never rejects; AI provider never called for messages / when off / when circuit open; raw text never sent to be stored; owner API validation; beacon stores only hashes; worker halt/retry/no-overlap).
- Node ↔ real database functions integration: **15 pass** (worker, owner routes and DB together: scam post → human-review case in shadow mode and the post stays published; idempotent re-processing; failed job retry then dead-letter; account burst → assessment + investigation + shadow restriction, nobody suspended; verification goes to human review when incomplete and auto-approves only when all checks pass and the owner has enabled it; emergency halt; non-owner rejected).
- Console UI in headless Chromium at phone width (390×844) with a **mocked** API: **25 pass** (non-owner sees nothing, owner sees every tab, no XSS from API text, no horizontal overflow, actions send the right requests).
Details: `platform-intelligence/db/TEST_RESULTS_BATCH2.txt`.

**NOT tested (needs real devices / live services) — please do not assume these work yet:**
- Real iPhone Safari / Android Chrome behaviour of the console (touch scrolling, `prompt()` dialogs, keyboard).
- The live Supabase HTTP layer (PostgREST) and Express/JWT in front of the owner routes — I tested the same SQL functions through `psql` and the HTTP logic as plain functions, but never a real Express server (no network here to install it).
- The optional OpenAI adapter against the real API (tested with a mocked `fetch` only).
- Render deployment, CORS from your Vercel domain, and the worker running continuously on Render.
- Production data volumes/performance.

## 6. Known limits (stated honestly)
- Rule engine, not "AI": it catches patterns and metadata. It does **not** claim to detect hate speech or sexual content on its own; those come from your custom terms, user reports, or the optional AI provider. Confidence values are heuristics, not probabilities. "Clear" means "no rule matched", never "proven safe".
- Posts/comments are scanned from the moment moderation_analysis is first switched on (no back-fill of old history). Private-message scanning stays OFF unless you switch on its own flag.
- Users do not yet see moderation notices / an appeal screen in the app (database functions exist from Batch 1; the user-facing screen is a later batch).
- Rule-set versions (thresholds/limits) are published through the owner API (`POST /api/pi/owner/rule-sets/:key`); the console shows them read-only for now.
- Part 2 (interactive BMN AI) and Part 3 (roadmap fixes: R2 video publishing, PWA, feeds, etc.) are **not started in this batch**; they follow after you have tested this one.
