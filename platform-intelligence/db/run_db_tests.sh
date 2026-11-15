#!/usr/bin/env bash
# Platform Intelligence: migration + rollback test runner.
#
# SAFETY: this script ONLY talks to a LOCAL, disposable PostgreSQL (unix socket / localhost) and it
# DROPs and re-creates the database named below. It refuses to run against any remote host.
# It has no way to reach Supabase production and must never be given production credentials.
#
# Usage:   ./run_db_tests.sh [path-to-baseline.sql]
# Needs:   psql, createdb/dropdb, a running PostgreSQL 15+ you can create databases in.
#          PGHOST/PGPORT/PGUSER may be set; defaults to the local socket.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASELINE="${1:-$REPO/supabase/migrations/20261102090000_bmn_baseline.sql}"
DB="${PI_TEST_DB:-pi_migration_test}"
UP="${PI_UP:-$HERE/migrations/001_pi_schema.up.sql}"        # PI_UP lets the tests be pointed at a modified copy (used to prove they can fail)
DOWN="$HERE/migrations/001_pi_schema.down.sql"
T="$HERE/tests"

case "${PGHOST:-}" in ""|localhost|127.0.0.1|/*) ;; *) echo "REFUSING: PGHOST='$PGHOST' is not local." >&2; exit 2;; esac
[ "$DB" != "postgres" ] && [ "$DB" != "template1" ] || { echo "REFUSING to use system database '$DB'" >&2; exit 2; }

P()  { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
Q()  { psql -X -At -v ON_ERROR_STOP=1 -d "$DB" -c "$1"; }
rec(){ P -c "SELECT pgtest.rec($(printf %s "$1" | sed "s/'/''/g; s/^/'/; s/\$/'/"), $2, $(printf %s "$3" | sed "s/'/''/g; s/^/'/; s/\$/'/"))" >/dev/null; }

echo "== PostgreSQL: $(psql -X -At -d postgres -c 'select version()' | cut -c1-60)"
dropdb --if-exists "$DB"; createdb "$DB"

echo "== 1. Supabase shim + REAL baseline (PG17 dump; two PG17-only/idempotency lines filtered)"
P -f "$T/00_supabase_shim.sql" >/dev/null
grep -v -E '^(SET transaction_timeout = 0;|CREATE SCHEMA public;)$' "$BASELINE" | P -f - >/dev/null
P -f "$T/15_test_harness.sql" >/dev/null
P -f "$T/10_seed_baseline_data.sql" >/dev/null
Q "SELECT pgtest.snap('baseline')"
echo "   baseline tables: $(Q "select count(*) from pg_tables where schemaname='public'")  functions: $(Q "select count(*) from pg_proc where pronamespace='public'::regnamespace")  pi_ objects: $(Q 'select pgtest.pi_object_count()')"

echo "== 2. Apply migration 001 UP"
P -f "$UP" >/dev/null
Q "SELECT pgtest.snap('after_up')"
rec 'N1 migration applies cleanly with ON_ERROR_STOP' true 'exit 0'
P -c "SELECT pgtest.q('N2 BMN schema (non-pi) is byte-for-byte unchanged after UP', \$\$(SELECT a.schema_fp = b.schema_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='baseline' AND b.label='after_up')\$\$)" >/dev/null
P -c "SELECT pgtest.q('N3 BMN data (every existing row) is unchanged after UP', \$\$(SELECT a.data_fp = b.data_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='baseline' AND b.label='after_up')\$\$)" >/dev/null
P -c "SELECT pgtest.q('N4 UP created pi_ objects', \$\$pgtest.pi_object_count() > 20\$\$)" >/dev/null

echo "== 3. Apply UP a second time (idempotency)"
if P -f "$UP" >/dev/null 2>"$DB.err"; then rec 'N5 UP is re-runnable (idempotent) without error' true 'exit 0'
else rec 'N5 UP is re-runnable (idempotent) without error' false "$(head -c 300 "$DB.err")"; fi
rm -f "$DB.err"

echo "== 4. Functional tests (constraints, privileges, RLS, queue, appeals, account deletion)"
P -f "$T/20_pi_tests.sql" >/dev/null

echo "== 5. Re-apply UP on a database that now HOLDS pi_ data: data must be kept"
BEFORE_ROWS="$(Q "select (select count(*) from public.pi_moderation_actions)||'/'||(select count(*) from public.pi_audit_log)||'/'||(select count(*) from public.pi_policies where version=2)")"
P -f "$UP" >/dev/null
AFTER_ROWS="$(Q "select (select count(*) from public.pi_moderation_actions)||'/'||(select count(*) from public.pi_audit_log)||'/'||(select count(*) from public.pi_policies where version=2)")"
[ "$BEFORE_ROWS" = "$AFTER_ROWS" ] && rec 'N6 re-applying UP keeps existing pi_ data and edited policy' true "$BEFORE_ROWS" || rec 'N6 re-applying UP keeps existing pi_ data and edited policy' false "$BEFORE_ROWS -> $AFTER_ROWS"

echo "== 6. ROLLBACK safety: refuses to destroy data without explicit confirmation"
Q "SELECT pgtest.snap('before_rollback')"
if P -f "$DOWN" >/dev/null 2>"$DB.err"; then rec 'R1 rollback refuses when pi_ data exists and is not confirmed' false 'it ran without confirmation'
else if grep -q 'Rollback refused' "$DB.err"; then rec 'R1 rollback refuses when pi_ data exists and is not confirmed' true "$(grep -m1 'Rollback refused' "$DB.err" | cut -c1-110)"; else rec 'R1 rollback refuses when pi_ data exists and is not confirmed' false "$(head -c 200 "$DB.err")"; fi; fi
P -c "SELECT pgtest.q('R2 nothing was removed by the refused rollback (transaction rolled back)', \$\$pgtest.pi_object_count() > 20 AND (SELECT count(*) FROM public.pi_moderation_actions) > 0\$\$)" >/dev/null

echo "== 7. ROLLBACK with explicit confirmation"
if { echo "SET pi.confirm_rollback = 'yes';"; cat "$DOWN"; } | P -f - >/dev/null 2>"$DB.err"; then rec 'R3 confirmed rollback runs cleanly' true 'exit 0'
else rec 'R3 confirmed rollback runs cleanly' false "$(head -c 300 "$DB.err")"; fi
Q "SELECT pgtest.snap('after_down')"
P -c "SELECT pgtest.q('R4 rollback removed EVERY pi_ table, function and domain', \$\$pgtest.pi_object_count() = 0\$\$)" >/dev/null
P -c "SELECT pgtest.q('R5 BMN schema identical to the ORIGINAL baseline after rollback', \$\$(SELECT a.schema_fp = b.schema_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='baseline' AND b.label='after_down')\$\$)" >/dev/null
P -c "SELECT pgtest.q('R6 BMN data unchanged by rollback (vs just before it)', \$\$(SELECT a.data_fp = b.data_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='before_rollback' AND b.label='after_down')\$\$)" >/dev/null
P -c "SELECT pgtest.q('R7 existing owner check still works after rollback', \$\$(SELECT count(*)=1 FROM public.bmn_admins WHERE role='owner')\$\$)" >/dev/null
P -c "SELECT pgtest.t('R8 rolled-back database still accepts normal BMN writes (as a normal user)', \$\$INSERT INTO public.posts (user_id, title) VALUES ('00000000-0000-0000-0000-000000000002', 'post after rollback')\$\$, 'authenticated', pgtest.u(2))" >/dev/null

echo "== 8. Clean cycle: UP -> DOWN (no data, no confirmation needed) -> UP"
P -f "$UP" >/dev/null
if P -f "$DOWN" >/dev/null 2>"$DB.err"; then rec 'R9 rollback of an empty install needs no confirmation' true 'exit 0'
else rec 'R9 rollback of an empty install needs no confirmation' false "$(head -c 300 "$DB.err")"; fi
P -c "SELECT pgtest.q('R10 empty-install rollback leaves zero pi_ objects', \$\$pgtest.pi_object_count() = 0\$\$)" >/dev/null
P -f "$UP" >/dev/null
P -c "SELECT pgtest.q('R11 UP applies again after a rollback, flags still all OFF', \$\$(SELECT count(*)=8 AND bool_and(NOT enabled) FROM public.pi_feature_flags)\$\$)" >/dev/null
rm -f "$DB.err"

echo "== 9. Name-collision guard: a foreign pi_* object must stop the migration"
P -f "$DOWN" >/dev/null
P -c "CREATE TABLE public.pi_policies (x int)" >/dev/null
if P -f "$UP" >/dev/null 2>"$DB.err"; then rec 'C1x UP refuses to run when an unrelated pi_policies table already exists' false 'it ran anyway'
else if grep -q 'Precondition failed: objects named pi_' "$DB.err"; then rec 'C1x UP refuses to run when an unrelated pi_policies table already exists' true 'precondition raised'; else rec 'C1x UP refuses to run when an unrelated pi_policies table already exists' false "$(head -c 200 "$DB.err")"; fi; fi
P -c "SELECT pgtest.q('C2x the refused UP left the foreign table untouched and created nothing else', \$\$pgtest.pi_object_count() = 1\$\$)" >/dev/null
P -c "DROP TABLE public.pi_policies" >/dev/null
P -f "$UP" >/dev/null && rec 'C3x after the foreign object is removed, UP applies normally' true 'exit 0' || rec 'C3x after the foreign object is removed, UP applies normally' false 'failed'
rm -f "$DB.err"

echo
echo "================ RESULTS ================"
psql -X -At -d "$DB" -F ' | ' -c "SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END, name, CASE WHEN ok THEN '' ELSE detail END FROM pgtest.results ORDER BY n" | sed 's/ | $//'
echo "-----------------------------------------"
TOTAL="$(Q 'select count(*) from pgtest.results')"; FAILED="$(Q 'select count(*) from pgtest.results where not ok')"
echo "TOTAL=$TOTAL  PASSED=$((TOTAL-FAILED))  FAILED=$FAILED"
echo "fingerprints: $(Q "select string_agg(label||'='||left(md5(schema_fp||data_fp),8), '  ' order by label) from pgtest.fps")"
[ "$FAILED" = "0" ]
