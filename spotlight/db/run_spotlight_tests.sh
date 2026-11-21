#!/usr/bin/env bash
# BMN Spotlight migration 003 test runner. LOCAL disposable PostgreSQL ONLY: it DROPs and re-creates the databases below.
# It refuses non-local hosts and has no way to reach Supabase production.
# Usage: ./run_spotlight_tests.sh    (run from anywhere; expects the repo layout this file ships in)
# Needs: psql, createdb, dropdb and a running local PostgreSQL 15+ where you may create databases.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASELINE="${1:-$REPO/supabase/migrations/20261102090000_bmn_baseline.sql}"
PIT="$REPO/platform-intelligence/db/tests"
UP="$HERE/003_bmn_spotlight.up.sql"; DOWN="$HERE/003_bmn_spotlight.down.sql"
DB="${SP_TEST_DB:-spotlight_test}"; CL="${DB}_clone"
case "${PGHOST:-}" in ""|localhost|127.0.0.1|/*) ;; *) echo "REFUSING: PGHOST='$PGHOST' is not local." >&2; exit 2;; esac
ERR="$(mktemp)"; trap 'dropdb --if-exists "$CL" >/dev/null 2>&1||true; dropdb --if-exists "$DB" >/dev/null 2>&1||true; rm -f "$ERR"' EXIT
P(){ psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
Q(){ psql -X -At -v ON_ERROR_STOP=1 -d "$DB" -c "$1"; }
QC(){ psql -X -At -v ON_ERROR_STOP=1 -d "$CL" -c "$1"; }
rec(){ P -c "SELECT pgtest.rec($(printf %s "$1" | sed "s/'/''/g; s/^/'/; s/\$/'/"), $2, $(printf %s "${3:-}" | sed "s/'/''/g; s/^/'/; s/\$/'/"))" >/dev/null; }
echo "== PostgreSQL: $(psql -X -At -d postgres -c 'select version()' | cut -c1-60)"
dropdb --if-exists "$DB"; createdb "$DB"
P -f "$PIT/00_supabase_shim.sql" >/dev/null
grep -v -E '^(SET transaction_timeout = 0;|CREATE SCHEMA public;)$' "$BASELINE" | P -f - >/dev/null
P -f "$PIT/15_test_harness.sql" >/dev/null
P -f "$PIT/10_seed_baseline_data.sql" >/dev/null
P -c "CREATE OR REPLACE FUNCTION pgtest.data_fp_nosp() RETURNS text LANGUAGE plpgsql AS \$f\$ DECLARE r record; v text; o text := ''; BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE 'pi\\_%' AND tablename NOT LIKE 'bmn\\_spotlight%' ORDER BY tablename LOOP EXECUTE format('SELECT md5(coalesce(string_agg(t::text, E''\\n'' ORDER BY t::text), '''')) || '':'' || count(*) FROM public.%I t', r.tablename) INTO v; o := o || r.tablename || '=' || v || ';'; END LOOP; RETURN md5(o); END \$f\$" >/dev/null
Q "SELECT pgtest.snap('baseline')"
BASE_DATA="$(Q 'SELECT pgtest.data_fp_nosp()')"
echo "== 1. UP on a clone of the baseline: applies, is repeatable"
dropdb --if-exists "$CL"; createdb -T "$DB" "$CL"
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$UP" >/dev/null 2>"$ERR"; then rec 'U1 003 UP applies cleanly on the real baseline' true ok; else rec 'U1 003 UP applies cleanly on the real baseline' false "$(head -c 300 "$ERR")"; fi
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$UP" >/dev/null 2>"$ERR"; then rec 'U2 003 UP is re-runnable' true ok; else rec 'U2 003 UP is re-runnable' false "$(head -c 300 "$ERR")"; fi
echo "== 2. DOWN on an empty install restores the baseline exactly"
if psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$DOWN" >/dev/null 2>"$ERR"; then rec 'U3 003 DOWN (no data) needs no confirmation' true ok; else rec 'U3 003 DOWN (no data) needs no confirmation' false "$(head -c 300 "$ERR")"; fi
rec 'U4 after UP+DOWN the BMN schema is byte-identical to the baseline' "$([ "$(QC 'SELECT pgtest.schema_fp()')" = "$(Q 'SELECT pgtest.schema_fp()')" ] && echo true || echo false)" "$(QC "select to_regclass('public.bmn_spotlights') is null")"
rec 'U5 after DOWN no spotlight function or table remains' "$([ "$(QC "select count(*) from pg_proc where proname like 'bmn_spotlight%'")" = 0 ] && echo true || echo false)" ok
echo "== 3. UP on the main DB, then the test suite"
if P -f "$UP" >/dev/null 2>"$ERR"; then rec 'N1 003 UP applies on the main test DB' true ok; else rec 'N1 003 UP applies on the main test DB' false "$(head -c 300 "$ERR")"; fi
rec 'N2 existing BMN row data (every non-Spotlight table) is unchanged by UP' "$([ "$(Q 'SELECT pgtest.data_fp_nosp()')" = "$BASE_DATA" ] && echo true || echo false)" "$BASE_DATA"
P -f "$HERE/spotlight_tests.sql" >/dev/null
echo "== 4. DOWN with data is refused; confirmed DOWN removes everything; UP again"
if P -f "$DOWN" >/dev/null 2>"$ERR"; then rec 'R1 DOWN refuses while Spotlight data exists' false ran
elif grep -q 'contain data' "$ERR"; then rec 'R1 DOWN refuses while Spotlight data exists' true refused; else rec 'R1 DOWN refuses while Spotlight data exists' false "$(head -c 200 "$ERR")"; fi
rec 'R2 the refused DOWN kept the data' "$([ "$(Q 'select count(*) from public.bmn_spotlights')" -gt 0 ] && echo true || echo false)" ok
if { echo "SET bmn.confirm_rollback = 'yes';"; cat "$DOWN"; } | P -f - >/dev/null 2>"$ERR"; then rec 'R3 confirmed DOWN runs' true ok; else rec 'R3 confirmed DOWN runs' false "$(head -c 300 "$ERR")"; fi
P -c "SELECT pgtest.snap('after_down')" >/dev/null
P -c "SELECT pgtest.q('R4 after the confirmed DOWN, BMN schema and data equal the baseline', \$\$(SELECT a.schema_fp = b.schema_fp AND a.data_fp = b.data_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='baseline' AND b.label='after_down')\$\$)" >/dev/null
if P -f "$UP" >/dev/null 2>"$ERR"; then rec 'R5 UP applies again after a rollback' true ok; else rec 'R5 UP applies again after a rollback' false "$(head -c 300 "$ERR")"; fi
echo; echo "================ RESULTS ================"
psql -X -At -d "$DB" -F ' | ' -c "SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END, name, CASE WHEN ok THEN '' ELSE detail END FROM pgtest.results ORDER BY n" | sed 's/ | $//'
T="$(Q 'select count(*) from pgtest.results')"; F="$(Q 'select count(*) from pgtest.results where not ok')"
echo "-----------------------------------------"; echo "TOTAL=$T  PASSED=$((T-F))  FAILED=$F"
[ "$F" = 0 ]
