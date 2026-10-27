#!/usr/bin/env python3
"""Run Cottage Surgical (cottagedme) Supabase SQL migrations.

Mirrors the rank1seo convention: a single-file psycopg2 runner with NO
schema_migrations ledger — every *.sql in supabase/migrations is re-run in
sorted order on each invocation, so every migration MUST be individually
idempotent (CREATE ... IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS).

Usage:
    python3 scripts/run_migrations.py --all      # re-run every migration in order
    python3 scripts/run_migrations.py --test     # connect only; print version + tables
    python3 scripts/run_migrations.py --list     # list discovered migration files
    python3 scripts/run_migrations.py --only 007_rental_orders.sql   # run one file

Running with no flag, or an unknown one, prints this help and touches nothing.
A full re-run replays old backfills and function bodies in order, so prefer
--only for the new file.

DB_CONNECTION resolution order:
    1. $DB_CONNECTION
    2. ../.env.local (a line beginning with `DB_CONNECTION=`)

Dependency: pip install psycopg2-binary

NOTE: seed_demo_data.sql, catalog_import.sql, seed_accounts.sql, and
seed_ui_scenarios.sql are EXCLUDED from the default sweep. Run a seed
explicitly with --only seed_ui_scenarios.sql.
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
SKIP_FROM_SWEEP = {
    "seed_demo_data.sql",
    "catalog_import.sql",
    "seed_accounts.sql",
    "seed_ui_scenarios.sql",
}


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


def discovered(include_seed=False):
    files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(MIGRATION_DIR, "*.sql")))
    if not include_seed:
        files = [f for f in files if f not in SKIP_FROM_SWEEP]
    return files


KNOWN_FLAGS = {"--all", "--test", "--list", "--only"}


def main():
    args = sys.argv[1:]
    flags = [a for a in args if a.startswith("-")]
    if not flags or any(f not in KNOWN_FLAGS for f in flags):
        sys.exit(__doc__)

    if "--list" in args:
        for f in discovered(include_seed=True):
            tag = "  (seed, excluded from sweep)" if f in SKIP_FROM_SWEEP else ""
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
