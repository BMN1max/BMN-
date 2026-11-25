#!/bin/bash
# Test fixture launcher (local only): throwaway PostgreSQL with baseline + overlay + M0-M3 + B1, static site on 8124, stand-in on 8130.
R=/home/claude/work/repo
bash /home/claude/work/pg_up.sh >/dev/null 2>&1
bash /home/claude/work/build_db.sh 2>&1 | tail -2
su postgres -c "psql -h /tmp/pgt -p 5499 -X -q -d bmn_t -v ON_ERROR_STOP=1 -f $R/supabase/proposed/B1_board_core.sql" 2>&1 | grep -v "NOTICE\|^$" | head -5
pkill -f "node [p]gserver"; pkill -f "http.server 8124"; sleep .4
(cd $R && nohup python3 -m http.server 8124 >/dev/null 2>&1 &)
(cd $R/tests/board/browser && PGDATABASE=bmn_t nohup node pgserver.js > pgserver.log 2>&1 &)
sleep 1.5; echo up
