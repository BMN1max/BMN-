#!/bin/bash
# Runs the Batch 3 migrations + Board B1 migration + tests (Batch 3 regression AND Board) on a THROWAWAY local PostgreSQL 16. Never touches production.
# usage: bash tests/board/sql/run.sh        (from the repo root; needs postgresql-16 server binaries)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"; B3="$ROOT/tests/batch3/sql"
PGB=${PGB:-/usr/lib/postgresql/16/bin}; D=${PGDIR:-/tmp/pgt}; PORT=${PGPORT_BMN:-5499}
BASE="${BMN_BASELINE:-$ROOT/supabase/migrations/20261102090000_bmn_baseline.sql}"
PROP="$ROOT/supabase/proposed"
pg() { su postgres -c "$*"; }
chmod a+x /home /home/claude 2>/dev/null; chmod -R a+rX "$ROOT" "$HERE" 2>/dev/null
if ! pg "$PGB/pg_isready -h $D -p $PORT" >/dev/null 2>&1; then
  [ -d $D/d ] || { mkdir -p $D; chown postgres $D; pg "$PGB/initdb -D $D/d >/dev/null"; }
  rm -f $D/d/postmaster.pid
  pg "$PGB/pg_ctl -D $D/d -o '-p $PORT -k $D' -l $D/log start >/dev/null"; sleep 2
fi
PSQL="psql -h $D -p $PORT -X -q"
pg "$PSQL -d postgres -At -c 'DROP DATABASE IF EXISTS bmn_t' -c 'CREATE DATABASE bmn_t'" 2>&1 | grep -v NOTICE
run() { local out rc; out=$(pg "$PSQL -d bmn_t -v ON_ERROR_STOP=1 -f $1" 2>&1); rc=$?; echo "$out" | grep -v "NOTICE\|^$"; return $rc; }
runi() { pg "$PSQL -d bmn_t -f $1" 2>&1 | grep -v "NOTICE\|^$" ; }   # ignore errors (baseline has a PG17-only SET)
run "$B3/00_supabase_stubs.sql" | grep -v "wal_level\|HINT"
pg "$PSQL -d bmn_t -c 'DROP SCHEMA IF EXISTS public CASCADE'" 
runi "$BASE" | grep -vi "transaction_timeout"
pg "$PSQL -d bmn_t -c 'GRANT USAGE ON SCHEMA public, auth TO anon,authenticated,service_role' -c 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon,authenticated,service_role' -c 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon,authenticated,service_role' -c 'GRANT ALL ON ALL TABLES IN SCHEMA public TO anon,authenticated,service_role' -c 'GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon,authenticated,service_role'"
snap() { pg "$PSQL -d bmn_t -At -c \"select 'T:'||tablename from pg_tables where schemaname='public' union all select 'P:'||tablename||':'||policyname from pg_policies where schemaname='public' union all select 'F:'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' union all select 'C:'||table_name||'.'||column_name from information_schema.columns where table_schema='public' union all select 'G:'||tgname from pg_trigger where not tgisinternal order by 1\""; }
run "$B3/06_prod_overlay.sql"
snap > /tmp/snap_base.txt
echo "baseline objects: $(grep -c '^T:' /tmp/snap_base.txt) tables, $(grep -c '^P:' /tmp/snap_base.txt) policies, $(grep -c '^F:' /tmp/snap_base.txt) functions"
FILES="M0_notifications_message_column M1_privacy_blocks_requests M2_groups M3_message_core"
echo "--- apply migrations (pass 1)"; for f in $FILES; do run "$PROP/$f.sql" || echo "FAILED $f"; done
echo "--- apply migrations again (idempotency)"; for f in $FILES; do run "$PROP/$f.sql" || echo "FAILED (2nd run) $f"; done
snap > /tmp/snap_m3.txt
echo "--- apply Board B1 (pass 1)"; run "$PROP/B1_board_core.sql" || echo "FAILED B1"
echo "--- apply Board B1 again (idempotency)"; run "$PROP/B1_board_core.sql" || echo "FAILED (2nd run) B1"
echo "--- tests"
for f in $B3/05_pg16_shim.sql $B3/00_helpers.sql $B3/10_fixtures.sql $B3/20_privacy_blocks.sql $B3/30_groups.sql $B3/40_message_core.sql; do runi "$f"; done
# the Batch 3 fixture runs a blanket GRANT ALL, which would undo B1's REVOKEs in this test database only; re-apply B1 (3rd idempotent run) so the Board tests see B1's real privileges
run "$PROP/B1_board_core.sql" || echo "FAILED B1 (3rd run)"
runi "$HERE/50_board.sql"
pg "$PSQL -d bmn_t -At -F '|' -c \"select case when ok then 'PASS' else 'FAIL' end, name, coalesce(detail,'') from t.results order by n\"" > /tmp/sql_results.txt
echo "PASS: $(grep -c '^PASS' /tmp/sql_results.txt)  FAIL: $(grep -c '^FAIL' /tmp/sql_results.txt)"
grep '^FAIL' /tmp/sql_results.txt
echo "--- rollback B1 only, then compare with the post-M3 snapshot"
pg "$PSQL -d bmn_t -c 'DROP SCHEMA t CASCADE'" >/dev/null 2>&1
sed -n '/^-- ROLLBACK-BEGIN/,/^-- ROLLBACK-END/p' "$PROP/B1_board_core.sql" | grep -v "ROLLBACK-\|^-- NOTE\|^-- (" | sed 's/^-- //' > /tmp/rb_B1.sql; chmod a+r /tmp/rb_B1.sql
run /tmp/rb_B1.sql || echo "ROLLBACK ERROR in B1"
snap > /tmp/snap_b1_after.txt
if diff <(grep -v '^C:content_reports.board_post_id$' /tmp/snap_m3.txt) <(grep -v '^C:content_reports.board_post_id$' /tmp/snap_b1_after.txt) >/tmp/snap_b1_diff.txt; then echo "B1 ROLLBACK RESTORES THE POST-M3 OBJECT SET: yes"; else echo "B1 ROLLBACK DIFFERS:"; cat /tmp/snap_b1_diff.txt; fi
echo "--- reapply B1 after its rollback"; run "$PROP/B1_board_core.sql" || echo "FAILED reapply B1"
echo "--- rollback B1 again, then M3..M1 in reverse order, compare with the baseline snapshot"
run /tmp/rb_B1.sql || echo "ROLLBACK ERROR in B1 (2)"
pg "$PSQL -d bmn_t -c 'DROP SCHEMA t CASCADE'" >/dev/null 2>&1
for f in M3_message_core M2_groups M1_privacy_blocks_requests; do
  sed -n '/^-- ROLLBACK-BEGIN/,/^-- ROLLBACK-END/p' "$PROP/$f.sql" | grep -v "ROLLBACK-\|^-- NOTE\|^-- (" | sed 's/^-- //' > /tmp/rb_$f.sql; chmod a+r /tmp/rb_$f.sql
  run /tmp/rb_$f.sql || echo "ROLLBACK ERROR in $f"
done
snap > /tmp/snap_after.txt
if diff <(grep -v '^C:notifications.message$' /tmp/snap_base.txt) <(grep -v '^C:notifications.message$' /tmp/snap_after.txt) >/tmp/snap_diff.txt; then echo "ROLLBACK RESTORES THE BASELINE OBJECT SET: yes"; else echo "ROLLBACK LEFT DIFFERENCES:"; cat /tmp/snap_diff.txt; fi
echo "--- reapply after rollback"; for f in M1_privacy_blocks_requests M2_groups M3_message_core; do run "$PROP/$f.sql" || echo "FAILED reapply $f"; done; echo done
