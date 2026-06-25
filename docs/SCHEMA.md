# Cottage Surgical (cottagedme) — Database Schema

Internal DME (durable medical equipment) **rental + delivery** management system
for Cottage Pharmacy. Three roles: **Admin**, **Staff**, **Driver**. No public
customers, no payment processing in v1.

Stack target: React + Vite + Supabase (Postgres + Auth + RLS + Realtime) on
Vercel — same lineage as the WheelsforWellness and rank1seo projects this schema
borrows patterns from.

## Migrations

Run with the no-ledger, idempotent runner (mirrors rank1seo):

```bash
pip install psycopg2-binary
# put DB_CONNECTION=... in .env.local (session pooler URI), then:
python3 scripts/run_migrations.py --test     # verify connection
python3 scripts/run_migrations.py            # apply all (excludes seed)
python3 scripts/run_migrations.py --only seed_demo_data.sql   # dev demo data
```

Every file is idempotent (re-run safe). No `schema_migrations` table — the
runner re-applies every file each time, so idempotency is mandatory.

| File | Purpose |
|------|---------|
| `001_extensions_and_helpers.sql` | pgcrypto, `update_updated_at_column()` |
| `002_profiles.sql` | profiles + role model (admin/staff/driver), role helpers, signup trigger, role-escalation guard |
| `003_org_settings.sql` | single-row business header config |
| `004_customers.sql` | customers (patients) + payment methods on file (display metadata only) |
| `005_equipment.sql` | equipment catalog + serialized units + qty sync |
| `006_drivers.sql` | driver operational records + live-location cache + `current_driver_id()` |
| `007_rental_orders.sql` | rental orders + line items + **unit double-booking backstop** |
| `008_deliveries.sql` | delivery/pickup dispatch legs + driver-scoped read policies |
| `009_driver_locations.sql` | GPS breadcrumb history + realtime |
| `010_billing.sql` | recurring charges, deposits, refunds (records only) |
| `011_notifications.sql` | notification inbox + delivery status fan-out + realtime |
| `012_operational_rpcs.sql` | atomic reserve + delivery lifecycle + availability functions |
| `013_ops_views_and_realtime.sql` | dashboard KPI view + realtime on live boards |
| `seed_demo_data.sql` | demo data matching the Figma screenshots (dev only, guarded) |

## Core model

- **profiles** ← `auth.users`; `role ∈ {admin, staff, driver}`. Authoritative
  role lives here (not in JWT metadata), read via SECURITY DEFINER helpers
  `is_admin()` / `is_staff_or_admin()` / `is_driver()`. A guard trigger blocks
  self-promotion.
- **customers** 1—* **rental_orders** 1—* **rental_line_items** *—1 **equipment_items** 1—* **equipment_units**.
- A **rental_order** spawns up to two **deliveries** (`leg_type = delivery | pickup`),
  each independently assigned to a **driver** and tracked.
- **drivers** 1—* **driver_locations** (GPS trail); `drivers.active_delivery_id`
  marks the in-flight leg.
- **recurring_charges**, **deposits**, **refunds** hang off rental_orders.

### Reliability: no double-booking

The customer's #1 requirement. Guaranteed at the database layer, not the UI:

1. **Structural backstop** — `uq_line_item_active_unit`, a partial unique index,
   makes it impossible for any serialized `equipment_unit` to appear in more than
   one *active* line item.
2. **Atomic allocation** — `reserve_equipment_unit(order, item)` takes a
   transaction-scoped advisory lock keyed per item, picks an available unit, and
   reserves it in one step, so two staff clicking "add" simultaneously can't grab
   the same/last unit.
3. **Lifecycle as one operation** — `start_delivery()` / `complete_delivery()`
   transition delivery status, unit status, order status, and billing together
   (SECURITY DEFINER, caller-authorized), instead of trusting a sequence of
   client writes that can half-fail.

On pickup completion, returned units go to `maintenance` (sterilization/inspection
before re-rental) rather than straight to `available`.

### Status lifecycles

- **rental_orders.status**: `open → pending → scheduled → delivered → active →
  (overdue) → pickup_scheduled → closed` (or `cancelled`).
- **deliveries.status**: `pending → scheduled → en_route → completed` (or `cancelled`).
- **equipment_units.status**: `available → reserved → rented → maintenance → retired`.

### RLS summary

- **Staff/Admin**: full operational access to all business tables.
- **Driver**: read-only access scoped to their own assigned deliveries and the
  orders/customers/units reachable from them; all driver writes go through the
  validated lifecycle RPCs.
- **Admin-only**: editing org settings; changing another user's role.

## Open questions for the customer

These were genuinely ambiguous in the designs — sensible defaults were chosen but
should be confirmed:

1. **Serialized vs. bulk inventory.** Schema assumes serialized units (per the
   "serial/asset tracking" note) and allocates a specific physical unit per
   rental. Confirm every item is individually tracked, or flag which categories
   are bulk/consumable (those can skip units and use `quantity_on_hand` only).
2. **Billing depth.** "No payments" is taken as *no payment processor* — billing
   tables track what's owed/held/refunded as records. Confirm we are NOT
   integrating Stripe/ACH now, and whether monthly charges need an invoice-level
   ledger (per-month rows) vs. the current subscription-level state.
3. **Time windows.** Stored as explicit `window_start`/`window_end` times. The
   New Order screen showed a "Select window…" dropdown — confirm whether windows
   are a fixed predefined set (e.g. 10–12, 1–3, 3–5) we should enumerate.
4. **Delivery vehicles.** Not in the current screens, so no `vehicles` table yet
   (dispatch is driver-only). Easy to add if vans need tracking.
5. **"Overdue" status.** Modeled as an explicit status the app sets. Confirm
   whether it should instead be derived (rental past due date / payment overdue)
   and computed rather than stored.
6. **Purchase orders.** `order_type = purchase` is supported (one-time sale,
   serial recorded), but the purchase screens are thinner — confirm purchases
   should live in the same orders table (current assumption) vs. separate.
