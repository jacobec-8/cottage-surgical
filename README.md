# Cottage Surgical

Rental and delivery operations for Cottage Pharmacy & Surgical's home medical
equipment, plus the public storefront at https://www.cottagesurgical.com.

## Stack

- Next.js (App Router), React, TypeScript, Tailwind, all under `src/`
- Supabase (Postgres, auth, row-level security); the schema lives in `supabase/migrations/`
- Vercel deploys `main` automatically
- Tests: Node unit tests (`tests/unit`), Playwright browser tests (`tests/e2e`),
  and a SQL harness that boots a throwaway Postgres (`tests/sql`, run by CI)

## Run it locally

```
npm ci
cp .env.example .env.local    # Supabase URL + anon key, DB_CONNECTION, APP_PUBLIC_URL
npm run dev                   # http://localhost:5173
```

The storefront is `/`. Staff sign in at `/admin-login`.

## Where things are

| Path | What |
|---|---|
| `src/app` | Routes. `(shop)` is public, `(staff)` is the back office, `(auth)` is sign-in. |
| `src/screens` | The body of each page, grouped by area: orders, delivery, shop, customers, reports, billing, requests, staff, onboarding, inventory. |
| `src/components` | Shared UI (layout, product cards, cart, notifications). |
| `src/lib` | Small helpers and the Supabase clients. `src/contexts` holds auth and cart state. |
| `supabase/migrations` | Numbered SQL files, applied in order by `scripts/run_migrations.py`. |
| `scripts` | Migration runner, catalog import, catalog image hosting, SQL test runner. |
| `docs/SCHEMA.md` | Tables and roles. `docs/LOCATION_ONBOARDING.md` describes the onboarding flow. |

## Checks

```
npm run typecheck
npm run lint
npm run test:unit
npm run test:e2e     # builds, then drives the site against a local fixture backend; never live data
npm run test:sql     # needs PostgreSQL 17 binaries and psycopg2; CI runs this for you
```

## Changing the database

`supabase/migrations/000_baseline.sql` is the whole schema as of migration 117:
tables, functions, triggers, policies, grants, plus the realtime, auth, storage
and cron pieces. Read it to learn the database. Migrations 001 to 117 live in
git history only.

1. Add `supabase/migrations/NNN_short_name.sql` with the next number (118 is
   next). Every file must be safe to re-run (`CREATE OR REPLACE`, `IF NOT EXISTS`).
2. Apply it to the live project before merging the code that needs it:
   `python3 scripts/run_migrations.py --only NNN_short_name.sql`
   (reads `DB_CONNECTION` from `.env.local`).
3. A brand-new database starts with `--only 000_baseline.sql`, then `--all`.
   `--all` never touches the baseline. Avoid it on the live database.

## Shipping

Branch from `main`, open a PR, let CI pass (lint, typecheck, unit, browser,
SQL), merge. Vercel deploys `main` within a few minutes. To roll back, revert
the PR.
