#!/usr/bin/env python3
"""Regenerate (or verify) the install manifest embedded in 001_pi_schema.up.sql.

The manifest lists every pi_ object the migration creates, as produced by the migration's own
pg_temp.pi_actual() catalog query. It is generated from a REAL install on a throw-away local database,
never edited by hand.

    refresh_manifest.py --write   rewrite the manifest block in the migration
    refresh_manifest.py --check   exit 1 if the embedded manifest is stale (used by run_db_tests.sh)

SAFETY: local PostgreSQL only (refuses any non-local PGHOST). Creates and drops its own scratch database.
It never touches Supabase.
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DB_DIR = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(DB_DIR))
UP = os.environ.get("PI_UP", os.path.join(DB_DIR, "migrations", "001_pi_schema.up.sql"))
BASELINE = os.environ.get("PI_BASELINE", os.path.join(REPO, "supabase", "migrations", "20261102090000_bmn_baseline.sql"))
SHIM = os.path.join(DB_DIR, "tests", "00_supabase_shim.sql")
SCRATCH = "pi_manifest_scratch"

host = os.environ.get("PGHOST", "")
if host not in ("", "localhost", "127.0.0.1") and not host.startswith("/"):
    sys.exit(f"REFUSING: PGHOST='{host}' is not local.")

def block(text, begin, end):
    a = text.index(begin); b = text.index(end, a)
    return a, b + len(end)

def psql(args, stdin=None):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"] + args, input=stdin, text=True,
                       capture_output=True)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr)
    return r.stdout

def generate():
    up = open(UP).read()
    a0, a1 = block(up, "-- @@PI_ACTUAL_BEGIN@@", "-- @@PI_ACTUAL_END@@")
    d0, d1 = block(up, "-- @@PI_DDL_BEGIN@@", "-- @@PI_DDL_END@@")
    subprocess.run(["dropdb", "--if-exists", SCRATCH], check=True)
    subprocess.run(["createdb", SCRATCH], check=True)
    try:
        psql(["-d", SCRATCH, "-f", SHIM])
        base = "\n".join(l for l in open(BASELINE).read().splitlines()
                         if l not in ("SET transaction_timeout = 0;", "CREATE SCHEMA public;"))
        psql(["-d", SCRATCH, "-f", "-"], base)
        with tempfile.NamedTemporaryFile("r", suffix=".txt") as out:
            script = ("BEGIN;\n\\o /dev/null\n" + up[a0:a1] + "\n" + up[d0:d1] + "\n"
                      f"\\o {out.name}\nSELECT l FROM pg_temp.pi_actual() AS l;\n\\o\nROLLBACK;\n")
            psql(["-d", SCRATCH, "-f", "-"], script)
            lines = [l for l in open(out.name).read().split("\n") if l]
    finally:
        subprocess.run(["dropdb", "--if-exists", SCRATCH], check=False)
    return sorted(set(lines))   # Python sort is by code point, same as the C-locale order we embed

def embedded(up):
    a, b = block(up, "-- @@PI_MANIFEST_DATA_BEGIN@@", "-- @@PI_MANIFEST_DATA_END@@")
    body = up[a:b].split("\n")[1:-1]
    return a, b, [l for l in body if l and not l.startswith("--")]

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    lines = generate()
    up = open(UP).read()
    a, b, cur = embedded(up)
    if mode == "--check":
        if sorted(cur) == lines:
            print(f"manifest current ({len(lines)} lines)"); return 0
        miss = sorted(set(lines) - set(cur)); extra = sorted(set(cur) - set(lines))
        print(f"manifest STALE: {len(miss)} line(s) missing from the embedded manifest, {len(extra)} obsolete")
        for l in miss[:10]: print("  + " + l[:150])
        for l in extra[:10]: print("  - " + l[:150])
        return 1
    if "\n$manifest$" in "\n".join(lines) or "$manifest$" in "".join(lines):
        sys.exit("manifest text contains the dollar-quote tag")
    new = "-- @@PI_MANIFEST_DATA_BEGIN@@\n" + "\n".join(lines) + "\n-- @@PI_MANIFEST_DATA_END@@"
    open(UP, "w").write(up[:a] + new + up[b:])
    print(f"manifest written ({len(lines)} lines)")
    return 0

sys.exit(main())
