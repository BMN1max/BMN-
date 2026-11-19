#!/bin/bash
# Builds a DISPOSABLE local Postgres database (baseline + 001 + 002 + synthetic seed) for the Node integration test. Never run on production.
# usage: PI_REPO=/path/to/repo bash build_test_db.sh [dbname]
set -e
DB=${1:-pinode}; R=${PI_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}; D=$R/platform-intelligence/db
case "${PGHOST:-local}" in local|/*|localhost|127.*) ;; *) echo "refusing non-local PGHOST"; exit 1;; esac
dropdb --if-exists "$DB"; createdb "$DB"
P="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
$P -f $D/tests/00_supabase_shim.sql >/dev/null
grep -v -E '^(SET transaction_timeout = 0;|CREATE SCHEMA public;)$' $R/supabase/migrations/20261102090000_bmn_baseline.sql | $P -f - >/dev/null
$P -f $D/tests/15_test_harness.sql >/dev/null; $P -f $D/tests/10_seed_baseline_data.sql >/dev/null
$P -f $D/migrations/001_pi_schema.up.sql >/dev/null; $P -f $D/migrations/002_pi_engine.up.sql >/dev/null
echo "built $DB"
