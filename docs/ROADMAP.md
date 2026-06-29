# Cottage Surgical — Roadmap & Backlog

Internal DME rental + delivery ops, plus a customer-facing shop/rental storefront.

## Status (2026-06-29)
- ✅ **Backend** — 15-table Supabase schema (profiles/roles, customers, equipment + serialized units, drivers, rental orders, deliveries/dispatch, GPS, billing, notifications, ops views). RLS on all tables, anti-double-booking (partial-unique + atomic reserve RPC), validated delivery lifecycle RPCs. Live on Supabase.
- ✅ **Catalog** — 14 products imported read-only from Shopify (`cottage-pharmacy-surgical`).
- ✅ **Internal app** (Vite/React on Vercel) — login + Admin/Staff/Driver shell, Dashboard, Inventory (live), Customers/Billing/Delivery (live, empty until data entered), New Order intake.
- ✅ **Auth** — admin/staff/driver accounts for Jacob + 3 demo accounts.

## Architecture (agreed)
Customers can **both buy and rent online**. Shopify = buy/checkout/payments + catalog source of truth. Supabase = rentals, ops, customer + staff auth. One site, three zones:
- **Storefront** (public) — browse → **Buy** (Shopify) or **Rent** (custom flow).
- **Customer portal** (customer login) — track my rentals/orders.
- **Staff app** (staff login) — ops (built). The **New Order screen is a staff back-office tool** (call-in entry, stock edits), NOT the primary rental path.

## Phase 2 — Public storefront + customer accounts (next)
- Storefront with product pages offering **Rent or Buy**.
- **Buy** → Shopify checkout (Storefront API / cart permalink); payments handled by Shopify.
- **Rent** → custom flow (select period + delivery) → creates a `rental_order` (status `requested`) → appears in the staff app for fulfillment.
- **Customer accounts** → Supabase auth with a new `customer` role + RLS (customers see only their own orders). Allow guest rent initially.

## Phase 3 — Payments + sync
- Online **rent payment** via Stripe (deposits + recurring monthly). Schema already models `deposits` / `recurring_charges`.
- Scheduled **Shopify → Supabase** catalog/inventory sync (edge function; client_credentials token refresh).

## Backlog / TODO
- [ ] **Driver proof-of-delivery photo — BOSS REQUEST.** Amazon-style: when a driver completes a delivery (and a pickup), they take a photo to confirm hand-off.
  - Storage: Supabase Storage bucket `delivery-photos`.
  - Data: `delivery_photos` table — `delivery_id`, `type` (`proof_of_delivery` | `proof_of_pickup`), `photo_url`, `captured_at`, `captured_by` (driver), optional `latitude`/`longitude`, `notes`.
  - Driver UX: prompt/require a photo in the "Complete" step (web: camera capture via `<input capture>`; native Expo camera if we go native). Extend `complete_delivery()` to record the photo reference.
  - Staff/customer: surface the photo on the order/delivery detail.
  - Depends on the Driver route screen (below).
- [ ] **Driver route screen** (not yet built) — today's stops, Maps/Waze deep-links, start/complete per stop, live GPS, + the proof-of-delivery capture above.
- [ ] Faithful build of remaining staff screens — Customers, New Order wizard, Billing (Recurring/Refunds tabs), Delivery & Pickup board.
- [ ] Connect `cottagesurgical.com` (registrar: Network Solutions) to Vercel — deploy first, then DNS.
- [ ] Optional: seed sample business data (customers + rentals using the real catalog) so the app looks populated for demos.
