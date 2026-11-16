# Production compatibility report (after hardening)

Nothing has been run on production. This lists what is still unknown or risky. Verdict: **safe to commit the files; not yet safe to apply to production.**
Next gate: run the migration on a Supabase branch or restored copy, with your approval.

## Compatibility with the existing BMN database (tested on the real baseline, PostgreSQL 16)
- No existing table, column, constraint, index, policy, trigger or function is changed; BMN schema fingerprint identical before UP and after DOWN; every existing row identical.
- Normal BMN writes (posts, reports) and the owner check still work with Platform Intelligence installed; the real `bmn_delete_my_account()` still works with rows in 9 pi_ tables.
- Rollback returns the schema to the baseline fingerprint.

## Remaining risks
| # | Risk | Severity | What to do |
|---|---|---|---|
| 1 | Tested on PostgreSQL 16 with an emulated Supabase, not Supabase's PostgreSQL 17. The install verifier compares catalog text (types, privileges, function body hashes). If PG17 reports something differently, the migration will **refuse or roll back** (safe failure, nothing left behind), not install wrongly | Medium | Run on a Supabase branch first; send me any "Post-install verification FAILED" text |
| 2 | Production may differ from the baseline (tables the app uses are missing from it: reposts, creator_tips, creator_payout_accounts, user_settings, user_blocks, media_assets). The migration depends only on auth.users, bmn_admins, is_bmn_owner() and the three Supabase roles and has no foreign keys to app tables, but I cannot see production | Medium | Send the production table list; run on a copy |
| 3 | **Possible existing bug (not caused by this work):** in the baseline, `bmn_enforce_interaction_account_status()` fails with `record "new" has no field "follower_id"` when an ordinary logged-in user inserts a comment, like, follow or message. It fails identically on the pristine baseline before any pi_ object exists (test E10). The production function may be different from the baseline | Needs checking | On a Supabase branch, insert a comment as a normal user. If it fails, that is a separate fix; I have not touched it |
| 4 | Privileges for other roles (postgres, supabase_admin, dashboard roles) and ALTER DEFAULT PRIVILEGES are not part of the manifest; only anon, authenticated, service_role are verified | Low | Review on the branch |
| 5 | A table owner or superuser can still drop or disable a trigger. The database cannot prevent that; the verifier detects it on the next migration run, not continuously | Low | Keep owner access limited; consider a periodic verification query |
| 6 | Case deletion audit entries record the actor as `service`. The API (Batch 2) must also write its own audit entry naming the human who asked for the deletion | Low | Planned for Batch 2 |
| 7 | Audit log and case history keep pseudonymous user and content ids after an account is deleted; no retention or purge job exists yet (job type exists, logic comes later). Privacy policy wording and legal retention periods need your decision | Medium | Decide before enabling anything |
| 8 | Job leases are 1 second..1 hour with no renewal function; a job that legitimately runs longer than its lease can be taken over by another worker. Concurrent workers (`SKIP LOCKED`) were tested sequentially only | Medium | Parallel load test on the branch before any worker runs |
| 9 | A database holding the first (pre-hardening) draft is refused; it must be rolled back first. None was ever applied to production | Low | n/a |
| 10 | Rollback with `pi.confirm_partial_cleanup` drops objects that have the migration's exact names, even if a foreign object happens to use one | Low | Documented in the file header; only used deliberately |
| 11 | The temporary verifier functions need the TEMP privilege and a single session/transaction; the SQL editor satisfies both | Low | Paste the whole file at once |
| 12 | Render start command is still unconfirmed (`package.json` says `node src/server.js`, which has never existed in the repo); `package.json` unchanged | Open | Send a screenshot of Render > Settings > Build & Deploy |

## Safe-to-deploy verdict
Files: safe to upload to GitHub (nothing runs from that folder; Vercel ignores it). Production database: **do not apply** until the branch check (risks 1-3) passes and you approve.
