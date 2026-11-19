#!/usr/bin/env bash
# Platform Intelligence: migration 002 (engine) test runner.
#
# SAFETY: this script ONLY talks to a LOCAL, disposable PostgreSQL (unix socket / localhost) and it DROPs and
# re-creates the databases named below. It refuses to run against any remote host. It has no way to reach
# Supabase production and must never be given production credentials.
#
# Usage:   ./run_db_tests_002.sh [path-to-baseline.sql]
# Needs:   psql, createdb/dropdb, python3 not required, a running PostgreSQL 15+ you can create databases in.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASELINE="${1:-$REPO/supabase/migrations/20261102090000_bmn_baseline.sql}"
DB="${PI_TEST_DB:-pi002_test}"
UP1="$HERE/migrations/001_pi_schema.up.sql";  DOWN1="$HERE/migrations/001_pi_schema.down.sql"
UP="${PI_UP2:-$HERE/migrations/002_pi_engine.up.sql}";  DOWN="$HERE/migrations/002_pi_engine.down.sql"
T="$HERE/tests"

case "${PGHOST:-}" in ""|localhost|127.0.0.1|/*) ;; *) echo "REFUSING: PGHOST='$PGHOST' is not local." >&2; exit 2;; esac
[ "$DB" != "postgres" ] && [ "$DB" != "template1" ] || { echo "REFUSING to use system database '$DB'" >&2; exit 2; }

BASE="${DB}_base"; C001="${DB}_c001"; CL="${DB}_clone"; REG="${DB}_reg"
ERR="$(mktemp)"; ERR2="$(mktemp)"
cleanup() { for d in "$BASE" "$C001" "$CL" "$REG"; do dropdb --if-exists "$d" >/dev/null 2>&1 || true; done; rm -f "$ERR" "$ERR2" "$ERR.mut.sql"; }
trap cleanup EXIT

P()  { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
Q()  { psql -X -At -v ON_ERROR_STOP=1 -d "$DB" -c "$1"; }
QC() { psql -X -At -v ON_ERROR_STOP=1 -d "$CL" -c "$1"; }
rec(){ P -c "SELECT pgtest.rec($(printf %s "$1" | sed "s/'/''/g; s/^/'/; s/\$/'/"), $2, $(printf %s "${3:-none}" | sed "s/'/''/g; s/^/'/; s/\$/'/"))" >/dev/null; }
newclone() { dropdb --if-exists "$CL"; createdb -T "$1" "$CL"; }
# run a script against the clone, capture stderr; returns its exit status
runc() { psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f "$1" >/dev/null 2>"$ERR"; }
confirm_down() { { echo "SET pi.confirm_rollback = 'yes'; SET pi.confirm_partial_cleanup = 'yes';"; cat "$DOWN"; } | psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f - >/dev/null 2>"$ERR"; }

echo "== PostgreSQL: $(psql -X -At -d postgres -c 'select version()' | cut -c1-60)"
dropdb --if-exists "$DB"; createdb "$DB"

echo "== 1. Supabase shim + REAL baseline + harness + seed"
P -f "$T/00_supabase_shim.sql" >/dev/null
grep -v -E '^(SET transaction_timeout = 0;|CREATE SCHEMA public;)$' "$BASELINE" | P -f - >/dev/null
P -f "$T/15_test_harness.sql" >/dev/null
P -f "$T/10_seed_baseline_data.sql" >/dev/null
Q "SELECT pgtest.snap('baseline')"
dropdb --if-exists "$BASE"; createdb -T "$DB" "$BASE"

echo "== 2. Migration 001 UP (the Batch 1 schema), then keep a pristine copy of that state"
P -f "$UP1" >/dev/null
Q "SELECT pgtest.snap('after_up')"
PI_FP_001="$(Q 'SELECT pgtest.pi_fp()')"
OBJ_001="$(Q 'SELECT pgtest.pi_object_count()')"
dropdb --if-exists "$C001"; createdb -T "$DB" "$C001"
rec 'U0 migration 001 is installed before 002 is applied' true "pi_ objects: $OBJ_001"

echo "== 3. Clean cycle on a copy: 002 UP -> 002 DOWN (no data) must restore the EXACT 001 state"
newclone "$C001"
if runc "$UP"; then rec 'U1 002 UP applies cleanly on top of 001' true 'exit 0'; else rec 'U1 002 UP applies cleanly on top of 001' false "$(head -c 300 "$ERR")"; fi
rec 'U2 002 UP added objects' "$( [ "$(QC 'SELECT pgtest.pi_object_count()')" -gt "$OBJ_001" ] && echo true || echo false )" "$(QC 'SELECT pgtest.pi_object_count()') objects (001 alone: $OBJ_001)"
if runc "$DOWN"; then rec 'U3 002 DOWN of an install that holds no data needs no confirmation' true 'exit 0'; else rec 'U3 002 DOWN of an install that holds no data needs no confirmation' false "$(head -c 300 "$ERR")"; fi
AFTER_FP="$(QC 'SELECT pgtest.pi_fp()')"
[ "$AFTER_FP" = "$PI_FP_001" ] && rec 'U4 after 002 UP + DOWN the Platform Intelligence installation is IDENTICAL to 001 alone (structure, privileges, triggers, row counts)' true "$AFTER_FP" \
  || rec 'U4 after 002 UP + DOWN the Platform Intelligence installation is IDENTICAL to 001 alone (structure, privileges, triggers, row counts)' false "$PI_FP_001 vs $AFTER_FP"
if runc "$UP"; then rec 'U5 002 UP applies again after DOWN' true 'exit 0'; else rec 'U5 002 UP applies again after DOWN' false "$(head -c 300 "$ERR")"; fi

echo "== 4. Apply 002 UP to the main test database; then re-apply (idempotency)"
if P -f "$UP" >/dev/null 2>"$ERR"; then rec 'N1 002 UP applies cleanly with ON_ERROR_STOP' true 'exit 0'; else rec 'N1 002 UP applies cleanly with ON_ERROR_STOP' false "$(head -c 300 "$ERR")"; fi
Q "SELECT pgtest.snap('after_002')"
P -c "SELECT pgtest.q('N2 BMN schema (non-pi) is byte-for-byte unchanged by 001 + 002', \$\$(SELECT a.schema_fp = b.schema_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='baseline' AND b.label='after_002')\$\$)" >/dev/null
P -c "SELECT pgtest.q('N3 BMN data (every existing row) is unchanged by 002', \$\$(SELECT a.data_fp = b.data_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='after_up' AND b.label='after_002')\$\$)" >/dev/null
if P -f "$UP" >/dev/null 2>"$ERR"; then rec 'N4 002 UP is re-runnable (idempotent) without error' true 'exit 0'; else rec 'N4 002 UP is re-runnable (idempotent) without error' false "$(head -c 300 "$ERR")"; fi
P -c "SELECT pgtest.q('N5 re-running UP kept the flags OFF and the policy history intact', \$\$(SELECT count(*)=9 AND bool_and(NOT enabled) FROM public.pi_feature_flags) AND (SELECT count(*) FROM public.pi_policy_versions)=(SELECT count(*) FROM public.pi_policies)\$\$)" >/dev/null

echo "== 5. Engine tests (policy engine, commits, verification gates, expiry, owner screens, privileges)"
P -f "$T/40_pi_engine_tests.sql" >/dev/null

echo "== 6. Re-apply 002 UP on a database that now HOLDS engine data: nothing may be lost or reset"
BEFORE="$(Q "select (select count(*) from public.pi_policy_decisions)||'/'||(select count(*) from public.pi_rule_sets)||'/'||(select count(*) from public.pi_audit_log)||'/'||(select count(*) from public.pi_feature_flags where enabled)||'/'||(select count(*) from public.pi_policies where enabled)||'/'||(select count(*) from public.pi_policy_versions)")"
P -f "$UP" >/dev/null
AFTER="$(Q "select (select count(*) from public.pi_policy_decisions)||'/'||(select count(*) from public.pi_rule_sets)||'/'||(select count(*) from public.pi_audit_log)||'/'||(select count(*) from public.pi_feature_flags where enabled)||'/'||(select count(*) from public.pi_policies where enabled)||'/'||(select count(*) from public.pi_policy_versions)")"
[ "$BEFORE" = "$AFTER" ] && rec 'N6 re-applying UP keeps decisions, rule sets, audit, enabled flags, enabled policies and policy history' true "$BEFORE" || rec 'N6 re-applying UP keeps decisions, rule sets, audit, enabled flags, enabled policies and policy history' false "$BEFORE -> $AFTER"

echo "== 7. Damaged / partial 002 installations (each case on a clone)"
sabotage() {  # id, what, sabotage sql, expected UP message ('-' = UP must succeed and repair), check sql after UP (must be true)
  local id="$1" what="$2" sql="$3" msg="$4" chk="${5:-}" b a
  newclone "$DB"
  if ! psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -c "$sql" >/dev/null 2>"$ERR"; then rec "$id sabotage applied: $what" false "$(head -c 200 "$ERR")"; return; fi
  b="$(QC 'SELECT pgtest.pi_fp()')"
  if [ "$msg" = "-" ]; then
    if runc "$UP"; then
      if [ -n "$chk" ] && [ "$(QC "SELECT $chk")" != "t" ]; then rec "$id UP repairs: $what" false "UP ran but the check '$chk' is false"; else rec "$id UP repairs: $what" true 'repaired'; fi
    else rec "$id UP repairs: $what" false "$(head -c 200 "$ERR")"; fi
  else
    if runc "$UP"; then rec "$id UP refuses: $what" false 'UP ran over a damaged installation'
    elif grep -q "$msg" "$ERR"; then rec "$id UP refuses: $what" true "$(grep -m1 "$msg" "$ERR" | cut -c1-90)"
    else rec "$id UP refuses: $what" false "wrong error: $(head -c 200 "$ERR")"; fi
    a="$(QC 'SELECT pgtest.pi_fp()')"
    [ "$b" = "$a" ] && rec "$id refused UP changed nothing: $what" true 'installation fingerprint identical' || rec "$id refused UP changed nothing: $what" false 'fingerprint changed'
  fi
}
sabotage S01 'the version-2 marker is missing but 002 tables exist (partial install)' "DELETE FROM public.pi_schema_version WHERE version = 2" 'Inconsistent or partial'
sabotage S02 'a NEWER schema version (3) is recorded' "INSERT INTO public.pi_schema_version (version, name) VALUES (3, '003_future')" 'newer Platform Intelligence schema'
sabotage S03 'version 2 is recorded under a different name' "UPDATE public.pi_schema_version SET name = '002_other' WHERE version = 2" 'different name'
sabotage S04 'a commit function is missing' 'DROP FUNCTION public.pi_commit_moderation_result(jsonb)' - "to_regprocedure('public.pi_commit_moderation_result(jsonb)') IS NOT NULL"
sabotage S05 'the policy snapshot trigger is missing' 'DROP TRIGGER pi_policy_snapshot_trg ON public.pi_policies' - "EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='pi_policy_snapshot_trg')"
sabotage S06 'an owner function was made callable by signed-in users' 'GRANT EXECUTE ON FUNCTION public.pi_owner_overview(uuid) TO authenticated' - "NOT has_function_privilege('authenticated','public.pi_owner_overview(uuid)','EXECUTE')"
sabotage S07 'anon was given write access to a 002 table' 'GRANT INSERT ON public.pi_system_alerts TO anon' - "NOT has_table_privilege('anon','public.pi_system_alerts','INSERT')"
sabotage S08 'RLS was switched off on a 002 table' 'ALTER TABLE public.pi_investigations DISABLE ROW LEVEL SECURITY' - "(SELECT relrowsecurity FROM pg_class WHERE oid='public.pi_investigations'::regclass)"
# every sabotage that UP refuses can be cleaned with the confirmed DOWN, and a fresh UP then works
newclone "$DB"; psql -X -q -d "$CL" -c "DELETE FROM public.pi_schema_version WHERE version = 2" >/dev/null
if { echo "SET pi.confirm_rollback = 'yes';"; cat "$DOWN"; } | psql -X -q -v ON_ERROR_STOP=1 -d "$CL" -f - >/dev/null 2>"$ERR"; then rec 'S09 DOWN refuses a partial install without the partial-cleanup confirmation' false 'ran'
elif grep -q 'marker is missing' "$ERR"; then rec 'S09 DOWN refuses a partial install without the partial-cleanup confirmation' true 'refused'; else rec 'S09 DOWN refuses a partial install without the partial-cleanup confirmation' false "$(head -c 200 "$ERR")"; fi
if confirm_down; then
  N="$(QC 'SELECT pgtest.pi_object_count()')"
  [ "$N" = "$OBJ_001" ] && rec 'S10 the confirmed DOWN cleans a partial install back to exactly the 001 objects' true "$N objects" || rec 'S10 the confirmed DOWN cleans a partial install back to exactly the 001 objects' false "$N objects, expected $OBJ_001"
else rec 'S10 the confirmed DOWN cleans a partial install back to exactly the 001 objects' false "$(head -c 200 "$ERR")"; fi
if runc "$UP"; then rec 'S11 a fresh UP works after the cleanup' true 'exit 0'; else rec 'S11 a fresh UP works after the cleanup' false "$(head -c 200 "$ERR")"; fi

echo "== 7b. Compatibility refusals (clones of the 001-only state)"
newclone "$C001"; psql -X -q -d "$CL" -c "ALTER TABLE public.posts RENAME COLUMN caption TO caption_renamed" >/dev/null
if runc "$UP"; then rec 'V1 UP refuses a database whose BMN tables differ from the baseline (posts.caption renamed)' false 'ran'
elif grep -q 'differs from the baseline BMN schema' "$ERR"; then rec 'V1 UP refuses a database whose BMN tables differ from the baseline (posts.caption renamed)' true "$(grep -m1 -o 'Missing column.*' "$ERR" | cut -c1-70)"; else rec 'V1 UP refuses a database whose BMN tables differ from the baseline (posts.caption renamed)' false "$(head -c 200 "$ERR")"; fi
[ "$(QC 'SELECT pgtest.pi_fp()')" = "$PI_FP_001" ] && rec 'V2 the refused UP changed nothing' true 'fingerprint identical' || rec 'V2 the refused UP changed nothing' false 'changed'
newclone "$BASE"
if runc "$UP"; then rec 'V3 UP refuses to run when migration 001 is not installed' false 'ran'
elif grep -q 'migration 001 is not installed' "$ERR"; then rec 'V3 UP refuses to run when migration 001 is not installed' true 'refused'; else rec 'V3 UP refuses to run when migration 001 is not installed' false "$(head -c 200 "$ERR")"; fi
[ "$(QC 'SELECT pgtest.pi_object_count()')" = "0" ] && rec 'V4 the refused UP created nothing on the bare baseline' true '0 objects' || rec 'V4 the refused UP created nothing on the bare baseline' false 'objects were created'
if runc "$DOWN"; then rec 'V5 002 DOWN refuses on a database without 001' false 'ran'; elif grep -q 'Rollback refused' "$ERR"; then rec 'V5 002 DOWN refuses on a database without 001' true 'refused'; else rec 'V5 002 DOWN refuses on a database without 001' false "$(head -c 200 "$ERR")"; fi

echo "== 7c. Post-install verification catches a migration that builds something unsafe"
newclone "$C001"
sed "s/EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);/NULL;/" "$UP" > "$ERR.mut.sql"
if cmp -s "$UP" "$ERR.mut.sql"; then rec 'W0 mutation of the migration was applied' false 'sed matched nothing'; else rec 'W0 mutation of the migration was applied' true 'privilege revoke removed'; fi
if runc "$ERR.mut.sql"; then rec 'W1 a migration that leaves default privileges on its tables fails its own verification' false 'ran'
elif grep -q 'Migration 002 verification failed' "$ERR"; then rec 'W1 a migration that leaves default privileges on its tables fails its own verification' true 'verification raised'; else rec 'W1 a migration that leaves default privileges on its tables fails its own verification' false "$(head -c 200 "$ERR")"; fi
[ "$(QC 'SELECT pgtest.pi_fp()')" = "$PI_FP_001" ] && rec 'W2 and it rolled back completely (installation identical to 001 alone)' true 'fingerprint identical' || rec 'W2 and it rolled back completely (installation identical to 001 alone)' false 'something was left behind'

echo "== 8. ROLLBACK of 002 on a database that holds engine data"
Q "SELECT pgtest.snap('before_down')"
AUDIT_BEFORE="$(Q 'select count(*) from public.pi_audit_log')"; ACT_BEFORE="$(Q 'select count(*) from public.pi_moderation_actions')"; FLAGS_BEFORE="$(Q "select count(*) from public.pi_feature_flags where enabled and key <> 'verification_evaluation'")"
PIFP_BEFORE="$(Q 'SELECT pgtest.pi_fp()')"
if P -f "$DOWN" >/dev/null 2>"$ERR"; then rec 'R1 002 DOWN refuses while engine data exists and is not confirmed' false 'ran'
elif grep -q 'Rollback refused' "$ERR"; then rec 'R1 002 DOWN refuses while engine data exists and is not confirmed' true "$(grep -m1 'Rollback refused' "$ERR" | cut -c1-100)"; else rec 'R1 002 DOWN refuses while engine data exists and is not confirmed' false "$(head -c 200 "$ERR")"; fi
[ "$(Q 'SELECT pgtest.pi_fp()')" = "$PIFP_BEFORE" ] && rec 'R2 the refused DOWN changed nothing' true 'fingerprint identical' || rec 'R2 the refused DOWN changed nothing' false 'changed'
if { echo "SET pi.confirm_rollback = 'yes';"; cat "$DOWN"; } | P -f - >/dev/null 2>"$ERR"; then rec 'R3 confirmed 002 DOWN runs cleanly' true 'exit 0'; else rec 'R3 confirmed 002 DOWN runs cleanly' false "$(head -c 300 "$ERR")"; fi
Q "SELECT pgtest.snap('after_down')"
P -c "SELECT pgtest.q('R4 DOWN removed every 002 object and left exactly the 001 objects', \$\$pgtest.pi_object_count() = $OBJ_001\$\$)" >/dev/null
P -c "SELECT pgtest.q('R5 BMN schema identical to the ORIGINAL baseline after rollback', \$\$(SELECT a.schema_fp = b.schema_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='baseline' AND b.label='after_down')\$\$)" >/dev/null
P -c "SELECT pgtest.q('R6 BMN data unchanged by the rollback', \$\$(SELECT a.data_fp = b.data_fp FROM pgtest.fps a, pgtest.fps b WHERE a.label='before_down' AND b.label='after_down')\$\$)" >/dev/null
P -c "SELECT pgtest.q('R7 migration-001 history survived: audit log, moderation actions and the flags the owner switched on are all still there', \$\$(SELECT count(*) = $AUDIT_BEFORE FROM public.pi_audit_log) AND (SELECT count(*) = $ACT_BEFORE FROM public.pi_moderation_actions) AND (SELECT count(*) = $FLAGS_BEFORE FROM public.pi_feature_flags WHERE enabled) \$\$)" >/dev/null
P -c "SELECT pgtest.q('R8 the version-2 marker and the verification_evaluation flag are gone, version 1 remains', \$\$(SELECT count(*) = 1 AND max(version) = 1 FROM public.pi_schema_version) AND NOT EXISTS (SELECT 1 FROM public.pi_feature_flags WHERE key = 'verification_evaluation')\$\$)" >/dev/null
P -c "SELECT pgtest.t('R9 the platform still accepts normal BMN writes after the rollback (as a normal user)', \$\$INSERT INTO public.posts (user_id, title) VALUES ('00000000-0000-0000-0000-000000000002', 'post after 002 rollback')\$\$, 'authenticated', pgtest.u(2))" >/dev/null
echo "== 8b. UP again after a rollback that kept data"
if P -f "$UP" >/dev/null 2>"$ERR"; then rec 'R10 002 UP applies again over the surviving 001 data' true 'exit 0'; else rec 'R10 002 UP applies again over the surviving 001 data' false "$(head -c 300 "$ERR")"; fi
P -c "SELECT pgtest.q('R11 the re-installed engine starts with a clean slate and the new flag OFF', \$\$(SELECT count(*) = 0 FROM public.pi_policy_decisions) AND (SELECT NOT enabled FROM public.pi_feature_flags WHERE key = 'verification_evaluation')\$\$)" >/dev/null

echo "== 9. Regression: the complete Batch 1 suites on a database with 001 AND 002 installed"
dropdb --if-exists "$REG"; createdb -T "$BASE" "$REG"
psql -X -q -v ON_ERROR_STOP=1 -d "$REG" -f "$UP1" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d "$REG" -f "$UP" >/dev/null
# The only intended differences: 002 adds ONE feature flag (9 instead of 8) and NINE tables (25 instead of 16). The three Batch 1
# checks that hard-code those counts are adapted by sed; nothing else in the Batch 1 suites is touched.
adapt() { sed "s/count(\*) = 8 AND bool_and(NOT enabled) FROM public.pi_feature_flags/count(*) = 9 AND bool_and(NOT enabled) FROM public.pi_feature_flags/; s/A3 all 8 feature flags/A3 all 9 feature flags (8 from 001 + verification_evaluation from 002)/; s/A1 sixteen pi_ tables exist/A1 twenty-five pi_ tables exist (16 from 001 + 9 from 002)/; s/relkind='r') = 16[$][$]/relkind='r') = 25\$\$/; s/relrowsecurity) = 16[$][$]/relrowsecurity) = 25\$\$/" "$1"; }
adapt "$T/20_pi_tests.sql" > "$ERR.b1_20.sql"; adapt "$T/30_pi_hardening_tests.sql" > "$ERR.b1_30.sql"
psql -X -q -v ON_ERROR_STOP=1 -d "$REG" -f "$ERR.b1_20.sql" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d "$REG" -f "$ERR.b1_30.sql" >/dev/null
rm -f "$ERR.b1_20.sql" "$ERR.b1_30.sql"
REG_TOTAL="$(psql -X -At -d "$REG" -c 'select count(*) from pgtest.results')"; REG_FAIL="$(psql -X -At -d "$REG" -c 'select count(*) from pgtest.results where not ok')"
rec "X1 Batch 1 regression (20_pi_tests + 30_pi_hardening_tests) on a 001+002 database: $REG_TOTAL checks, $REG_FAIL failed" "$( [ "$REG_FAIL" = "0" ] && [ "$REG_TOTAL" -gt 100 ] && echo true || echo false )" "$(psql -X -At -d "$REG" -F ' | ' -c "select name from pgtest.results where not ok limit 5" | tr '\n' ';')"

echo
echo "================ RESULTS ================"
psql -X -At -d "$DB" -F ' | ' -c "SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END, name, CASE WHEN ok THEN '' ELSE detail END FROM pgtest.results ORDER BY n" | sed 's/ | $//'
echo "-----------------------------------------"
TOTAL="$(Q 'select count(*) from pgtest.results')"; FAILED="$(Q 'select count(*) from pgtest.results where not ok')"
echo "TOTAL=$TOTAL  PASSED=$((TOTAL-FAILED))  FAILED=$FAILED   (plus the $REG_TOTAL Batch 1 checks run in section 9: $REG_FAIL failed)"
[ "$FAILED" = "0" ]
