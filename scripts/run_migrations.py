#!/usr/bin/env python3
"""Run Cottage Surgical Supabase SQL migrations.

A single-file psycopg2 runner with no ledger: every numbered *.sql in
supabase/migrations is re-run in sorted order on each --all, so every
migration MUST be individually idempotent (CREATE ... IF NOT EXISTS /
CREATE OR REPLACE / DROP ... IF EXISTS).

000_baseline.sql is the whole schema as of migration 117, for a NEW database
only. It is not idempotent and the sweep skips it. Later migrations apply on
top of it.

Usage:
    python3 scripts/run_migrations.py --only 118_short_name.sql   # apply one file (the normal case)
    python3 scripts/run_migrations.py --all      # re-run every migration after the baseline, in order
    python3 scripts/run_migrations.py --only 000_baseline.sql     # new database: load the schema first
    python3 scripts/run_migrations.py --test     # connect only; print version + tables
    python3 scripts/run_migrations.py --list     # list discovered migration files

Running with no flag, or an unknown one, prints this help and touches nothing.

DB_CONNECTION resolution order:
    1. $DB_CONNECTION
    2. ../.env.local (a line beginning with `DB_CONNECTION=`)

Dependency: pip install psycopg2-binary
"""
import os
import sys
import glob

try:
    import psycopg2
except ImportError:
    sys.exit("psycopg2 not installed. Run: pip install psycopg2-binary")

HERE = os.path.dirname(os.path.abspath(__file__))
MIGRATION_DIR = os.path.join(HERE, "..", "supabase", "migrations")
ENV_LOCAL = os.path.join(HERE, "..", ".env.local")
BASELINE = "000_baseline.sql"  # new databases only; never part of the sweep


def resolve_db_connection():
    val = os.environ.get("DB_CONNECTION")
    if val:
        return val
    if os.path.exists(ENV_LOCAL):
        with open(ENV_LOCAL) as fh:
            for line in fh:
                if line.strip().startswith("DB_CONNECTION="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit(
        "DB_CONNECTION not set.\n"
        "  Set it in the environment, or add a DB_CONNECTION=... line to .env.local\n"
        "  (Supabase Dashboard > Project Settings > Database > Connection string > URI,\n"
        "   session pooler)."
    )


def discovered(include_baseline=False):
    files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(MIGRATION_DIR, "*.sql")))
    if not include_baseline:
        files = [f for f in files if f != BASELINE]
    return files


KNOWN_FLAGS = {"--all", "--test", "--list", "--only"}


def main():
    args = sys.argv[1:]
    flags = [a for a in args if a.startswith("-")]
    if not flags or any(f not in KNOWN_FLAGS for f in flags):
        sys.exit(__doc__)

    if "--list" in args:
        for f in discovered(include_baseline=True):
            tag = "  (new databases only, excluded from --all)" if f == BASELINE else ""
            print(f, tag)
        return

    dsn = resolve_db_connection()
    conn = psycopg2.connect(dsn, connect_timeout=10)
    conn.autocommit = True  # each file runs as its own implicit transaction
    cur = conn.cursor()

    if "--test" in args:
        cur.execute("SELECT version();")
        print(cur.fetchone()[0])
        cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1;")
        tables = [r[0] for r in cur.fetchall()]
        print(f"public tables ({len(tables)}):", ", ".join(tables) or "(none)")
        return

    if "--only" in args:
        idx = args.index("--only")
        if idx + 1 >= len(args):
            sys.exit("--only requires a filename, e.g. --only 007_rental_orders.sql")
        files = [args[idx + 1]]
    else:
        files = discovered()

    ok = 0
    for name in files:
        path = os.path.join(MIGRATION_DIR, name)
        if not os.path.exists(path):
            print(f"SKIP {name}: not found")
            continue
        with open(path) as fh:
            sql = fh.read()
        try:
            cur.execute(sql)
            print(f"OK   {name}")
            ok += 1
        except Exception as exc:  # noqa: BLE001 — report and continue (no global txn)
            print(f"ERR  {name}: {exc}")

    print(f"\n{ok}/{len(files)} migrations applied.")


if __name__ == "__main__":
    main()
