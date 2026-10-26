Run `npm run test:sql` from the repository root. Requirements: PostgreSQL server
binaries (tested with 17) and Python 3 with `psycopg2`. Set `PG_BINDIR` when the
server tools are not returned by `pg_config --bindir`.

The runner creates a fresh local cluster with no TCP listener, loads real
migration tables and email functions, and removes the cluster on exit. Auth
identity, selected later schema additions, and the HTTP sender are local
stand-ins. Every send goes to an inert test table. There are no provider keys,
cron jobs, production DSNs or external network calls. This is database workflow
coverage, supplemented by the COS-only live QA evidence.

The suite checks migration reapplication, positive and negative store/role
reads, final staff-order content after commit, rollback, allocation wording,
HTML escaping, storefront receipt refresh, address-only changes and no-op
saves, receipt snapshots and access, failed/replayed/concurrent payments,
month-end dates, all six due/return reminder stages, DST/quiet hours,
ended/closed/extended rentals, stale suppression, concurrent dispatchers, real-sender HTTP response parsing, daily/monthly quotas,
rate-limit backoff, preserved retry budgets and delivery recovery.

Never run these SQL fixtures against an existing database. The shell runner is
the supported entry point; it intentionally ignores `DB_CONNECTION`.
