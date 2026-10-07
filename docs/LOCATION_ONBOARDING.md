# Location onboarding

Admins open **Locations → Onboard a location** (`/locations/onboard`). The five
steps collect a new business and private owner contact (or an existing business),
a location, quantities from the shared active catalog, optional staff/drivers,
and a review with explicit activation. New locations default to inactive.

Staff logins belong to one location. Owners added as team members receive staff
access, not a new business-owner role or global admin access. Driver logins are
linked to operational driver records; roster-only drivers are also supported.
Credentials are entered by the admin and shared directly. No invitation is sent.
Drafts are held only in memory and passwords never enter the retry receipt.

The `onboard_business_location` RPC validates and commits business, contact,
location, inventory assignments, actual serialized units, accounts and driver
records in one transaction. A request UUID and advisory transaction lock make
retries return the original result. Each physical unit gets a generated asset
tag; manufacturer serial numbers remain blank. Bulk quantities do not create
unit records. Price overrides remain local; the shared catalog is unchanged.

Owner contact information is admin-only and editable from the location detail.
Renaming a location does not rename its parent business.

## Rollout

Apply `supabase/migrations/062_guided_location_onboarding.sql` to the target
database before deploying the app. It is additive and replayable. Do not use a
full migration replay just to apply this feature; older migrations include data
backfills. The UI explains a missing RPC instead of reporting creation success.
No production migration is performed by the tests below.

## Verification

Run `npm run lint`, `npm run typecheck`, `npm run test:unit`, and `npm run build`.
For database integration, use a disposable PostgreSQL 17 cluster (requires
Python 3, PostgreSQL binaries on PATH, and pgcrypto):

```sh
cluster=$(mktemp -d /tmp/cottage-onboarding.XXXXXX)
initdb -D "$cluster/data" --auth=trust --no-locale
pg_ctl -D "$cluster/data" -l "$cluster/postgres.log" -o '-p 55449 -h 127.0.0.1' start
python3 tests/sql/onboarding-bootstrap.py > "$cluster/schema.sql"
psql -h 127.0.0.1 -p 55449 -d postgres -v ON_ERROR_STOP=1 -f "$cluster/schema.sql"
psql -h 127.0.0.1 -p 55449 -d postgres -v ON_ERROR_STOP=1 -f tests/sql/location-onboarding.sql
pg_ctl -D "$cluster/data" stop
```

The bootstrap uses real public schema/function/trigger fragments from migrations
002, 005, 006, 015, 053, 054, 059, 061 and 062. Auth tables are minimal stand-ins:
these tests verify hashed credentials and linked identities, not the hosted
Supabase Auth sign-in service. Migration 062 is applied twice to check replay.
Tests cover stock/prices, driver links, existing businesses, inactive locations,
retry idempotency, forced late failure rollback (including auth records), invalid
inputs, and anonymous/staff/inactive-admin permissions plus contact privacy.

Browser review should cover empty-step validation, a new business, an existing
business, catalog search and quantities, adding/removing both team roles, review
editing, and a narrow viewport. Use an isolated database for creation tests;
stop at review when inspecting against live data with fictional details.
