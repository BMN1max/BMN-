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

BASE="${DB}_base"; CL="${DB}_clone"
cleanup() { dropdb --if-exists "$CL" >/dev/null 2>&1 || true; dropdb --if-exists "$BASE" >/dev/null 2>&1 || true; rm -f "$DB.err" "$DB.err2"; }
trap cleanup EXIT

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
dropdb --if-exists "$BASE"; createdb -T "$DB" "$BASE"      # pristine baseline copy, reused by the fresh-database tests below
echo "== 1b. Embedded install manifest must match what the migration really builds"
if python3 "$HERE/tools/refresh_manifest.py" --check >"$DB.err2" 2>&1; then rec 'V1 embedded install manifest is current (matches a real install)' true "$(tail -1 "$DB.err2")"
else rec 'V1 embedded install manifest is current (matches a real install)' false "$(head -c 300 "$DB.err2")"; fi
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
echo "== 4b. Hardening tests (job queue, audit/history, privileges, BMN compatibility)"
P -f "$T/30_pi_hardening_tests.sql" >/dev/null

echo "== 5. Re-apply UP on a database that now HOLDS pi_ data: data must be kept"
BEFORE_ROWS="$(Q "select (select count(*) from public.pi_moderation_actions)||'/'||(select count(*) from public.pi_audit_log)||'/'||(select count(*) from public.pi_policies where version=2)")"
P -f "$UP" >/dev/null
AFTER_ROWS="$(Q "select (select count(*) from public.pi_moderation_actions)||'/'||(select count(*) from public.pi_audit_log)||'/'||(select count(*) from public.pi_policies where version=2)")"
[ "$BEFORE_ROWS" = "$AFTER_ROWS" ] && rec 'N6 re-applying UP keeps existing pi_ data and edited policy' true "$BEFORE_ROWS" || rec 'N6 re-applying UP keeps existing pi_ data and edited policy' false "$BEFORE_ROWS -> $AFTER_ROWS"

echo "== 5b. Partial / damaged installation matrix (each case: a clone of the fully installed DB is sabotaged)"
# usage: sabotage ID 'what is wrong' 'sabotage SQL' [residual pi_ objects expected after cleanup] [message UP must raise]
sabotage() {
  local id="$1" what="$2" sql="$3" resid="${4:-0}" msg="${5:-Inconsistent or partial}" b a n
  dropdb --if-exists "$CL"; createdb -T "$DB" "$CL"
  if ! psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -c "$sql" >/dev/null 2>"$DB.err"; then rec "$id sabotage applied: $what" false "$(head -c 200 "$DB.err")"; return; fi
  b="$(psql -X -At -d "$CL" -c 'SELECT pgtest.pi_fp()')"
  if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$UP" >/dev/null 2>"$DB.err"; then rec "$id UP refuses: $what" false 'UP ran over a damaged installation'
  elif grep -q "$msg" "$DB.err"; then rec "$id UP refuses: $what" true "$(grep -m1 "$msg" "$DB.err" | cut -c1-90)"
  else rec "$id UP refuses: $what" false "wrong error: $(head -c 200 "$DB.err")"; fi
  a="$(psql -X -At -d "$CL" -c 'SELECT pgtest.pi_fp()')"
  [ "$b" = "$a" ] && rec "$id refused UP changed nothing: $what" true 'installation fingerprint identical' || rec "$id refused UP changed nothing: $what" false 'fingerprint changed'
  if { echo "SET pi.confirm_rollback = 'yes'; SET pi.confirm_partial_cleanup = 'yes';"; cat "$DOWN"; } | psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f - >/dev/null 2>"$DB.err"; then
    n="$(psql -X -At -d "$CL" -c 'SELECT pgtest.pi_object_count()')"
    [ "$n" = "$resid" ] && rec "$id confirmed DOWN cleans it up: $what" true "$n pi_ object(s) left (expected $resid)" || rec "$id confirmed DOWN cleans it up: $what" false "$n left, expected $resid"
  else rec "$id confirmed DOWN cleans it up: $what" false "$(head -c 200 "$DB.err")"; fi
  if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -c "DROP TABLE IF EXISTS public.pi_extra_table" -f "$UP" >/dev/null 2>"$DB.err"; then rec "$id fresh UP works after cleanup: $what" true 'exit 0'
  else rec "$id fresh UP works after cleanup: $what" false "$(head -c 200 "$DB.err")"; fi
}
sabotage S01 'a table is missing'            'DROP TABLE public.pi_provider_health'
sabotage S02 'a trigger is missing'          'DROP TRIGGER pi_audit_no_change ON public.pi_audit_log'
sabotage S03 'the truncate guard is missing' 'DROP TRIGGER pi_actions_no_truncate ON public.pi_moderation_actions'
sabotage S04 'an index is missing'           'DROP INDEX public.pi_jobs_claim_idx'
sabotage S05 'a function is missing'         'DROP FUNCTION public.pi_fail_job(uuid, text, text, interval)'
sabotage S06 'a column is missing'           'ALTER TABLE public.pi_jobs DROP COLUMN last_error'
sabotage S07 'RLS is switched off'           'ALTER TABLE public.pi_audit_log DISABLE ROW LEVEL SECURITY'
sabotage S08 'a privilege was revoked'       'REVOKE INSERT ON public.pi_audit_log FROM service_role'
sabotage S09 'a function body was altered'   $'CREATE OR REPLACE FUNCTION public.pi_audit_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = \'\' AS $x$ BEGIN RETURN NULL; END $x$'
sabotage S10 'the version row is missing'    'DELETE FROM public.pi_schema_version' 0 'Inconsistent Platform Intelligence installation'
sabotage S11 'an unexpected extra table'     'CREATE TABLE public.pi_extra_table (x int)' 1
sabotage S12 'an unexpected extra column'    'ALTER TABLE public.pi_jobs ADD COLUMN surprise int'
sabotage S13 'a newer schema version is recorded' "INSERT INTO public.pi_schema_version (version, name) VALUES (2, '002_future')" 0 'already installed'
sabotage S14 'a column has the wrong type'   'ALTER TABLE public.pi_jobs ALTER COLUMN priority TYPE integer'
sabotage S15 'a policy is missing'           'DROP POLICY pi_owner_select ON public.pi_jobs'
sabotage S16 'a safety constraint is missing' 'ALTER TABLE public.pi_jobs DROP CONSTRAINT pi_jobs_lock_consistent'
sabotage S17 'a trigger is disabled'         'ALTER TABLE public.pi_jobs DISABLE TRIGGER pi_jobs_state_guard'
sabotage S18 'anon was given access'         'GRANT SELECT ON public.pi_jobs TO anon'
sabotage S19 'a function was made public'    'GRANT EXECUTE ON FUNCTION public.pi_claim_jobs(text, integer, interval, text[]) TO authenticated'
sabotage S20 'the job-type domain is missing (dropped with its column)' 'ALTER TABLE public.pi_jobs DROP COLUMN job_type CASCADE'
dropdb --if-exists "$CL"

echo "== 5c. Fresh-database edge cases (clones of the pristine baseline)"
dropdb --if-exists "$CL"; createdb -T "$BASE" "$CL"
psql -X -q -d "$CL" -c "CREATE TABLE public.pi_policies (x int); INSERT INTO public.pi_policies VALUES (1)" >/dev/null
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$UP" >/dev/null 2>"$DB.err"; then rec 'F1 UP refuses an unrelated pi_policies table on an otherwise empty database' false 'ran'; else grep -q 'Inconsistent or partial' "$DB.err" && rec 'F1 UP refuses an unrelated pi_policies table on an otherwise empty database' true 'refused' || rec 'F1 UP refuses an unrelated pi_policies table on an otherwise empty database' false "$(head -c 200 "$DB.err")"; fi
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$DOWN" >/dev/null 2>"$DB.err"; then rec 'F2 DOWN refuses to touch unrecognised pi_ objects without partial-cleanup confirmation' false 'ran'; else grep -q 'Rollback refused' "$DB.err" && rec 'F2 DOWN refuses to touch unrecognised pi_ objects without partial-cleanup confirmation' true 'refused' || rec 'F2 DOWN refuses to touch unrecognised pi_ objects without partial-cleanup confirmation' false "$(head -c 200 "$DB.err")"; fi
P2="$(psql -X -At -d "$CL" -c 'SELECT count(*) FROM public.pi_policies')"
[ "$P2" = "1" ] && rec 'F3 the foreign table and its row are untouched by the refused UP and DOWN' true '1 row' || rec 'F3 the foreign table and its row are untouched by the refused UP and DOWN' false "rows=$P2"
if { echo "SET pi.confirm_partial_cleanup = 'yes';"; cat "$DOWN"; } | psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f - >/dev/null 2>"$DB.err"; then rec 'F4 DOWN with data present still refuses without data confirmation (foreign row counts as data)' false 'ran'; else grep -q 'Rollback refused' "$DB.err" && rec 'F4 DOWN with data present still refuses without data confirmation (foreign row counts as data)' true 'refused' || rec 'F4 DOWN with data present still refuses without data confirmation (foreign row counts as data)' false "$(head -c 200 "$DB.err")"; fi

echo "== 5d. Upgrade from the first (pre-hardening) draft"
dropdb --if-exists "$CL"; createdb -T "$BASE" "$CL"
psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$T/fixtures/001_pi_schema.v1_draft.up.sql" >/dev/null 2>"$DB.err" && rec 'G1 first-draft migration installs (fixture)' true 'exit 0' || rec 'G1 first-draft migration installs (fixture)' false "$(head -c 200 "$DB.err")"
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$UP" >/dev/null 2>"$DB.err"; then rec 'G2 hardened UP refuses to run over the first draft (it would silently keep the weaker constraints)' false 'ran'; else grep -q 'Inconsistent or partial' "$DB.err" && rec 'G2 hardened UP refuses to run over the first draft (it would silently keep the weaker constraints)' true 'refused' || rec 'G2 hardened UP refuses to run over the first draft (it would silently keep the weaker constraints)' false "$(head -c 200 "$DB.err")"; fi
psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$DOWN" >/dev/null 2>"$DB.err" && rec 'G3 hardened DOWN removes the first draft (no data, so no confirmation needed)' true 'exit 0' || rec 'G3 hardened DOWN removes the first draft (no data, so no confirmation needed)' false "$(head -c 200 "$DB.err")"
G3b="$(psql -X -At -d "$CL" -c 'SELECT pgtest.pi_object_count()')"; [ "$G3b" = "0" ] && rec 'G3b nothing named pi_ is left after removing the first draft' true '0 objects' || rec 'G3b nothing named pi_ is left after removing the first draft' false "$G3b left"
psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$UP" >/dev/null 2>"$DB.err" && rec 'G4 hardened UP installs after the first draft was removed' true 'exit 0' || rec 'G4 hardened UP installs after the first draft was removed' false "$(head -c 200 "$DB.err")"

echo "== 5e. Post-install verification catches a migration that does not build what the manifest says"
dropdb --if-exists "$CL"; createdb -T "$BASE" "$CL"
sed 's/^GRANT EXECUTE ON FUNCTION public.pi_my_moderation_notices().*$/-- (sabotaged: grant removed)/' "$UP" > "$DB.mut.sql"
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$DB.mut.sql" >/dev/null 2>"$DB.err"; then rec 'H1 a migration that builds something different from its manifest fails' false 'ran'; else grep -q 'Post-install verification FAILED' "$DB.err" && rec 'H1 a migration that builds something different from its manifest fails' true 'verification raised' || rec 'H1 a migration that builds something different from its manifest fails' false "$(head -c 200 "$DB.err")"; fi
H2="$(psql -X -At -d "$CL" -c 'SELECT pgtest.pi_object_count()')"
[ "$H2" = "0" ] && rec 'H2 and it rolled back completely (no pi_ object left)' true '0 objects' || rec 'H2 and it rolled back completely (no pi_ object left)' false "$H2 objects left"
rm -f "$DB.mut.sql"
dropdb --if-exists "$CL"

echo "== 5f. Is the comment/like/follow/message failure for ordinary users caused by pi_? (compare with the pristine baseline)"
dropdb --if-exists "$CL"; createdb -T "$BASE" "$CL"
BASEMSG="$(psql -X -q -d "$CL" 2>&1 <<'SQL' | head -3 | tr '\n' ' '
BEGIN; SET LOCAL request.jwt.claim.sub='00000000-0000-0000-0000-000000000002'; SET LOCAL request.jwt.claim.role='authenticated'; SET LOCAL ROLE authenticated;
INSERT INTO public.comments (user_id, post_id, body, content) VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000a0002','x','x');
ROLLBACK;
SQL
)"
case "$BASEMSG" in *'no field "follower_id"'*) rec 'E10 NOTE: an ordinary user inserting a comment already fails on the PRISTINE baseline (bmn_enforce_interaction_account_status), so it is not caused by pi_' true "baseline defect confirmed: $(printf %s "$BASEMSG" | cut -c1-80)";; *) rec 'E10 NOTE: an ordinary user inserting a comment already fails on the PRISTINE baseline' false "unexpected: $BASEMSG";; esac
dropdb --if-exists "$CL"

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
else if grep -q 'Inconsistent or partial' "$DB.err"; then rec 'C1x UP refuses to run when an unrelated pi_policies table already exists' true 'precondition raised'; else rec 'C1x UP refuses to run when an unrelated pi_policies table already exists' false "$(head -c 200 "$DB.err")"; fi; fi
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
