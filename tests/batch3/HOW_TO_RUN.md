# Running the Batch 3 tests (local, throwaway database — never production)

Needs: PostgreSQL 16 server binaries, Node 20+, Playwright with Chromium.

SQL (migrations, RLS, idempotency, rollback):
    BMN_BASELINE=<path to supabase/migrations/20261102090000_bmn_baseline.sql> bash tests/batch3/sql/run.sh
    -> prints "PASS: 230 FAIL: 0" and "ROLLBACK RESTORES THE BASELINE OBJECT SET: yes"
    (leaves a database `bmn_t` with M0-M3 applied)

Browser (real client against real RLS):
    1. serve the repo root:   python3 -m http.server 8124
    2. start the stand-in:    PGDATABASE=bmn_t node tests/batch3/browser/pgserver.js     (port 8130)
    3. run:                   node tests/batch3/browser/t10_batch3.js
    pgserver.js is a TEST FIXTURE, never deployed. It runs each request as role `authenticated` with the caller's id.
The original Batch 2 suites in tests/t1-t5.js are untouched.
