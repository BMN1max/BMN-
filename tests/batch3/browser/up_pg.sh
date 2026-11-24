#!/bin/bash
# starts the static site (port 8124) and the PostgreSQL-backed stand-in (port 8130)
SITE=${SITE:-/tmp/site}
pkill -f "node [p]gserver"; pkill -f "node [d]bserver"; pkill -f "http.server 8124"; sleep .4
bash /home/claude/work/pg/start.sh
(cd $SITE && nohup python3 -m http.server 8124 >/dev/null 2>&1 &)
(cd "$(dirname "$0")" && nohup node pgserver.js > pgserver.log 2>&1 &)
sleep 1.2
