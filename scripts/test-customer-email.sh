#!/usr/bin/env bash
# Disposable PostgreSQL tests. No production DSN, provider credentials or TCP.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${PG_BINDIR:-}" ]]; then
  qa_pg="$PG_BINDIR"
elif [[ -x /opt/homebrew/opt/postgresql@17/bin/initdb ]]; then
  qa_pg=/opt/homebrew/opt/postgresql@17/bin
else
  qa_pg="$(pg_config --bindir)"
fi
qa_cluster=$(mktemp -d "${TMPDIR:-/tmp}/cottage-email-XXXXXX")
mkdir "$qa_cluster/socket"
cleanup() {
  "$qa_pg/pg_ctl" -D "$qa_cluster/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$qa_cluster"
}
trap cleanup EXIT
"$qa_pg/initdb" -D "$qa_cluster/data" --auth=trust --no-locale >/dev/null
"$qa_pg/pg_ctl" -D "$qa_cluster/data" -l "$qa_cluster/postgres.log" -o "-k $qa_cluster/socket -p 55451 -c listen_addresses=''" -w start >/dev/null
"$qa_pg/createdb" -h "$qa_cluster/socket" -p 55451 email_tests
python3 tests/sql/email-bootstrap.py > "$qa_cluster/schema.sql"
psql_test() { "$qa_pg/psql" -X -h "$qa_cluster/socket" -p 55451 -d email_tests -v ON_ERROR_STOP=1 "$@"; }
if ! psql_test -f "$qa_cluster/schema.sql" > "$qa_cluster/bootstrap.log" 2>&1; then cat "$qa_cluster/bootstrap.log"; exit 1; fi
# Each deployed migration must be safe to apply again without replaying mail.
for qa_file in 070_customer_email_store_isolation.sql 071_customer_email_lifecycle.sql 072_customer_billing_reminders.sql; do
  if ! psql_test -f "supabase/migrations/$qa_file" > "$qa_cluster/reapply.log" 2>&1; then cat "$qa_cluster/reapply.log"; exit 1; fi
done
for qa_test in customer-email-access customer-email-lifecycle customer-email-reminders; do
  if ! psql_test -f "tests/sql/$qa_test.sql" > "$qa_cluster/result.log" 2>&1; then cat "$qa_cluster/result.log"; exit 1; fi
  echo "PASS $qa_test"
done
python3 tests/sql/customer-email-concurrency.py "$qa_cluster/socket"

if ! psql_test -f tests/sql/customer-email-provider.sql > "$qa_cluster/provider.log" 2>&1; then cat "$qa_cluster/provider.log"; exit 1; fi
echo "PASS customer-email-provider (real sender, fake HTTP)"
