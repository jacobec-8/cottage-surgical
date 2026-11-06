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
# Email fixtures insert logins directly; sign-ups are closed (119), so raise the login flag for that database.
psql_test -c "ALTER DATABASE email_tests SET cottage.login_create = '1'" > /dev/null
if ! psql_test -f "$qa_cluster/schema.sql" > "$qa_cluster/bootstrap.log" 2>&1; then cat "$qa_cluster/bootstrap.log"; exit 1; fi
for qa_test in customer-email-access customer-email-lifecycle customer-email-reminders; do
  if ! psql_test -f "tests/sql/$qa_test.sql" > "$qa_cluster/result.log" 2>&1; then cat "$qa_cluster/result.log"; exit 1; fi
  echo "PASS $qa_test"
done
python3 tests/sql/customer-email-concurrency.py "$qa_cluster/socket"

if ! psql_test -f tests/sql/customer-email-provider.sql > "$qa_cluster/provider.log" 2>&1; then cat "$qa_cluster/provider.log"; exit 1; fi
echo "PASS customer-email-provider (real sender, fake HTTP)"

# Roles run in their own database so their fixtures never meet the email ones.
"$qa_pg/createdb" -h "$qa_cluster/socket" -p 55451 roles_tests
psql_roles() { "$qa_pg/psql" -X -h "$qa_cluster/socket" -p 55451 -d roles_tests -v ON_ERROR_STOP=1 "$@"; }
if ! psql_roles -f "$qa_cluster/schema.sql" > "$qa_cluster/roles-bootstrap.log" 2>&1; then cat "$qa_cluster/roles-bootstrap.log"; exit 1; fi
if ! psql_roles -f tests/sql/roles.sql > "$qa_cluster/roles.log" 2>&1; then cat "$qa_cluster/roles.log"; exit 1; fi
echo "PASS roles (one assertion per cell of the role contract)"

"$qa_pg/createdb" -h "$qa_cluster/socket" -p 55451 pairings_tests
psql_pairings() { "$qa_pg/psql" -X -h "$qa_cluster/socket" -p 55451 -d pairings_tests -v ON_ERROR_STOP=1 "$@"; }
if ! psql_pairings -f "$qa_cluster/schema.sql" > "$qa_cluster/pairings-bootstrap.log" 2>&1; then cat "$qa_cluster/pairings-bootstrap.log"; exit 1; fi
if ! psql_pairings -f tests/sql/product-pairings.sql > "$qa_cluster/pairings.log" 2>&1; then cat "$qa_cluster/pairings.log"; exit 1; fi
echo "PASS product-pairings (goes well with: who picks, what, who reads)"

# Staff New Order takes the payment (130): its own database; 130 re-applied first to prove it is safe to re-run.
"$qa_pg/createdb" -h "$qa_cluster/socket" -p 55451 staff_order_tests
psql_orders() { "$qa_pg/psql" -X -h "$qa_cluster/socket" -p 55451 -d staff_order_tests -v ON_ERROR_STOP=1 "$@"; }
if ! psql_orders -f "$qa_cluster/schema.sql" > "$qa_cluster/orders-bootstrap.log" 2>&1; then cat "$qa_cluster/orders-bootstrap.log"; exit 1; fi
if ! psql_orders -f supabase/migrations/130_staff_order_payment.sql > "$qa_cluster/orders-rerun.log" 2>&1; then cat "$qa_cluster/orders-rerun.log"; exit 1; fi
if ! psql_orders -f tests/sql/staff-order-payment.sql > "$qa_cluster/orders.log" 2>&1; then cat "$qa_cluster/orders.log"; exit 1; fi
echo "PASS staff-order-payment (a delivery is paid before it is saved; pickups pay at the counter)"

# One payment for a rental and a purchase (128), against a fake Stripe, in its own database.
"$qa_pg/createdb" -h "$qa_cluster/socket" -p 55451 checkout_tests
psql_checkout() { "$qa_pg/psql" -X -h "$qa_cluster/socket" -p 55451 -d checkout_tests -v ON_ERROR_STOP=1 "$@"; }
if ! psql_checkout -f "$qa_cluster/schema.sql" > "$qa_cluster/checkout-bootstrap.log" 2>&1; then cat "$qa_cluster/checkout-bootstrap.log"; exit 1; fi
# The runner has no ledger, so 128 and 129 must be safe to apply twice: run them again before the test.
if ! psql_checkout -f supabase/migrations/128_one_payment_checkout.sql > "$qa_cluster/checkout-rerun.log" 2>&1; then cat "$qa_cluster/checkout-rerun.log"; exit 1; fi
if ! psql_checkout -f supabase/migrations/129_store_collects_payment.sql > "$qa_cluster/checkout-rerun.log" 2>&1; then cat "$qa_cluster/checkout-rerun.log"; exit 1; fi
if ! psql_checkout -f tests/sql/one-payment-checkout.sql > "$qa_cluster/checkout.log" 2>&1; then cat "$qa_cluster/checkout.log"; exit 1; fi
echo "PASS one-payment-checkout (a rental and a purchase on one Stripe session, fake HTTP)"

