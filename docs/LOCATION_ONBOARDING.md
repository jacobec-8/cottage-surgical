# Business onboarding

Admins open **Locations → Onboard a business or branches** (`/locations/onboard`).
Four steps collect a new business and private contact (or an existing business)
with an optional owner login, a repeatable list of branches (each with address,
services, explicit activation, stock from the shared active catalog with local
prices, and branch staff logins), drivers with a home branch and the other
branches they serve, and one review. New branches default to inactive.

The owner login is the `owner` role (migration 074): store-staff tools in every
branch of that business, never global admin access. Staff logins belong to one
branch. Driver logins are linked to driver records; roster-only drivers are also
supported, and an existing driver of the business can be shared with new
branches. Credentials are entered by the admin and shared directly. No invitation
is sent. Drafts are held only in memory and passwords never enter the receipt.

The `onboard_business` RPC (076) validates and commits the business, contact,
every branch with its inventory and actual serialized units, the owner, staff and
driver accounts, driver records and branch memberships in one transaction. A
failure anywhere rolls everything back and names the branch at fault. A request
UUID and advisory transaction lock make retries return the original result. Each
physical unit gets a generated asset tag; manufacturer serial numbers remain
blank. Bulk quantities do not create unit records. Price overrides remain local.
The single-branch `onboard_business_location` RPC (062) still works and shares
the per-branch code (`_onboard_branch`).

Owner contact information is admin-only and editable from the location detail.
Renaming a location does not rename its parent business.

## Rollout

Apply migrations 062 and 074–076 to the target database before deploying the
app. They are additive and replayable. Do not use a
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
