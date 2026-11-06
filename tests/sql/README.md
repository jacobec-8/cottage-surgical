Run `npm run test:sql` from the repository root. Requirements: PostgreSQL server
binaries (tested with 17) and Python 3 with `psycopg2`. Set `PG_BINDIR` when the
server tools are not returned by `pg_config --bindir`. CI runs this on every push.

The runner creates a fresh local cluster with no TCP listener, loads
`standins.sql` (local stand-ins for the Supabase roles, auth tables, vault and
the http extension) and then the real schema from
`supabase/migrations/000_baseline.sql` plus every numbered migration after it,
swaps the mail sender for an inert one, runs the suites, and removes the
cluster on exit. There are no provider keys, cron jobs, production DSNs or
external network calls.

Suites: customer-email-access (store and role boundaries on the outbox),
customer-email-lifecycle (order, allocation, appointment and payment mail,
receipts, per-location branding), customer-email-reminders (due and return
reminders, DST and quiet hours, stale suppression), customer-email-concurrency.py
(row locks: one payment, one receipt, one email; concurrent dispatchers),
customer-email-provider (the real Resend sender against a fake HTTP transport:
quotas, rate limits, retries, idempotency keys, sender name) and roles (one
assertion per cell of the role contract in `~/cottagedme/BUSINESS-SHAPE.md`:
reach per role, switched-off pharmacies, owners and logins, membership fences,
closed sign-ups; it runs in its own database), product-pairings (goes well
with) and one-payment-checkout (migration 128 against a fake Stripe transport: a
rental and a purchase on one session, request keys, verify and the sweep,
cancelling in Stripe, split refunds, today's single-type checkouts unchanged,
who may call what; it re-applies 128 first to prove it is safe to re-run, and
runs in its own database).

Never run these SQL fixtures against an existing database. The shell runner is
the supported entry point; it intentionally ignores `DB_CONNECTION`.
