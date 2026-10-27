# Cottage Surgical: agent operations and implementation guide

Updated 2026-10-06 from checkout `68af4f5` plus the existing working tree.
This guide connects natural-language requests to operating the service and
changing its implementation. It contains no credentials or customer records.

## Evidence and scope

The live storefront and admin, staff, and driver accounts were inspected with
`bc screen` on nu-yin. Inspection covered the catalog/cart, both fulfillment
choices, role navigation, Requests, Orders, New Order, Inventory, Billing,
Delivery & Pickup, Locations, and Staff Access. Creation and lifecycle steps
below were traced through the UI source and SQL; no live order, payment,
inventory, user, or store was created for this study. Empty queues prevented
live observation of some active-work states. These are operating instructions,
not a claim that every workflow has passed an end-to-end mutation test.

Recheck the current UI and data before acting. Prices, stock, enabled modules,
accounts, and stores are live state. The observed stores were Cottage Surgical
and 110 Pharmacy & Surgical; do not treat that list as permanent.

## Service and roles

Cottage Surgical combines a public home-medical-equipment rental storefront
with pharmacy operations: intake, inventory, fulfillment, billing, and returns.
The storefront describes service across Nassau and Suffolk counties, New York.
The catalog includes beds, wheelchairs, patient lifts, knee scooters, seating,
and respiratory equipment. Public purchasing is currently hidden by
`SHOP_PURCHASES_ENABLED = false`; staff order creation still supports purchases.

| Actor | Workspace and authority |
| --- | --- |
| Guest customer | `/`, `/product/[handle]`, cart and checkout. Current customer flow is guest-based; there is no implemented customer-account portal. |
| Store staff | Operational modules enabled by the admin, scoped to the account's assigned store. The header identifies that store. |
| Business owner | Every operational module in every branch of one business (074), with a header selector for **All my stores** or one branch. No Staff/Locations admin screens, no other business's data, and staff module switches do not restrict it. New branches of the business are covered automatically. |
| Driver | `/delivery`, labeled **My Deliveries**; assigned stops at every branch they serve, start/complete actions, and proof photos. A login needs a linked `drivers` record to receive assignments. One stop can be en route at a time (075). |
| Admin | Operational modules plus **Staff** (users and access tabs) and **Locations**. Can select a store or **All stores**. |

An admin role has global access even when its profile has a `location_id`.
Creating an "admin for a store" does not establish a separate, confined
store-admin role. Staff module switches apply to the staff role globally;
they are not individual user permissions. Admin and driver access are unaffected.

The sidebar groups related screens into horizontal tabs:

| Sidebar entry | Tabs and retained routes |
| --- | --- |
| **Orders** | **Orders** (`/orders`), **Requests** (`/requests`), **New Order** (`/new-order`). |
| **Delivery & Pickup** | **Delivery & Pickup** (`/delivery`), **Drivers** (`/drivers`). Driver accounts keep the standalone **My Deliveries** screen, without the roster tab. |
| **Staff** (admin only) | **Staff & Users** (`/staff`), **Staff Access** (`/staff-access`). Staff detail (`/staff/[id]`) keeps the users tab active. |

Each tab keeps its own role/module permission. The sidebar opens the first
permitted tab and hides a group when none are permitted. Its badge combines
the visible tabs' work-queue counts. Existing deep links remain usable.
Navigation definitions and role filtering live in
`src/lib/workspaceNavigation.ts`; the shared tab bar lives in `Layout.tsx`.
These changes are on `codex/orders-tabs`, added after the live-site inspection.
Tests cover staff module combinations, admin/driver separation, and staff
detail matching. Live permission settings are not changed for navigation tests.
On 2026-10-06, the local production build passed lint, type checking, and all
46 unit tests. nu-yin checks covered the admin tabs and staff detail navigation;
a driver login retained My Deliveries and was redirected away from `/drivers`.

Login is `/admin-login`. The form accepts configured usernames and the explicitly
allowed owner email; an arbitrary email is not necessarily a valid login.
Local authorized credentials are in the ignored `LOGINS.local.md`. Read/use them
without printing passwords, adding them to this guide, or saving them in browser
password storage. Do not recreate seed accounts to solve a login problem.

## Interpret the user's request

Use established context first. An instruction to perform an ordinary operation
authorizes that operation; do not turn each Save into a new permission question.
Resolve real ambiguity with a concise question and continue independent lookup.
Do not invent customer identities, equipment identifiers, prices, stock,
credentials, or a delivery commitment.

| Request | Interpretation and first step |
| --- | --- |
| "Add X to inventory" | Search existing inventory. Determine whether X is a new product, more physical units of an existing product, or a bulk-stock adjustment. Resolve store and quantity from context. |
| "Add three wheelchairs" | Match the specific model; add three physical units if serialized. This does not mean create three catalog products or set the total stock to three. |
| "Set stock to three" | Absolute available quantity for the stated store. For serialized items, reconcile actual unit records rather than editing only the displayed total. |
| "New order for this person on this date" | Resolve customer, items/quantities, store, rental/purchase, fulfillment, and what the date means. New Order currently creates a delivery workflow. |
| "Move it to Friday" | Identify the order and whether this is outbound delivery, in-store collection, return pickup, or a billing due date. Use the user's calendar/timezone for relative dates. |
| "Add a store" / "Set up a business with three branches" | Admin → Locations → Onboard a business or branches. One submission: business and owner login, every branch with its stock and staff, drivers with the branches they serve; review before creating (§4). |
| "Let this driver work at both stores" | Drivers → that driver → **Branches…** (owner or admin). Not a second driver record or login. |
| "Add a staff member/driver" | Resolve store and role. An authentication account, driver roster record, and assignment are distinct objects. A login acts as a driver only while its profile is an active `driver` at the roster record's store (065). Changing a driver's role, store or activation releases their open stops for reassignment. Moving a driver to another store means updating both the profile and the roster record. |
| "Mark paid" / "Record payment" | Establish which actual payment is being recorded. Updating a payment badge is different from recording a monthly rental payment or charging a card. |
| "Cancel it" / "It's returned" | Check whether equipment is still reserved or has gone out. Cancellation, physical return, and a refund have different effects. |

For any mutation: identify the exact record and store, inspect current values,
apply the requested change once, reopen/refetch the record, and verify relevant
downstream state. A click receipt or success toast alone is insufficient.
After an uncertain response, inspect whether it committed before retrying.
Report concrete identifiers, store, quantity/date, and any unfinished allocation.

## 1. Add equipment or stock

### New catalog product

Inputs: name/model, category, store, serialized versus bulk, quantity, rental
and/or sale offering, pickup and/or delivery offering, and the price for each
enabled offering. SKU, description, image, installation requirement, and
same-day-pickup setting are optional details when supplied. Categories currently
are `mobility`, `seating`, `bedroom`, and `respiratory`.

1. Open **Inventory** (`/inventory`), select the intended store, and search name
   and SKU to avoid duplicating an existing product.
2. Choose **Add Item**. Set name, category, **Track individual units**, offering
   flags, and relevant prices. Rental prices are monthly; pickup and
   **Delivery + return pickup rental** are separate fields. Purchasable items
   need a sale price. At least one offering and fulfillment method is required.
3. Save. Creating a serialized product initializes quantity to zero: it does
   not add physical stock. If the product disappears under a store filter,
   inspect **All stores** before assuming Save failed.
4. Open the product detail (`/inventory/[id]`). Use **Units** to add physical
   units and **Locations** to inspect/configure store assignments. Adding a
   serialized unit creates/updates that store's inventory assignment via a
   database trigger. Bulk inventory needs the intended location assignment
   and quantity under **Locations**.
5. Verify product identity, store assignment, available units/quantity, prices,
   fulfillment flags, and relevant storefront visibility.

Images accept JPG, PNG, WebP, or GIF up to 5 MB. Uploads use the public
`equipment-images` bucket. Do not infer that making an item purchasable enables
public Buy buttons; the storefront feature flag still controls them.

Catalog names, offering flags, and default prices are shared across stores.
Selecting a store does not turn **Edit item** into a store-only catalog edit.
Use the item's **Locations** controls for store stock and price overrides, and
verify the effective order price as well as the displayed catalog price.

### More units of an existing product

1. Search and open the correct product. Select the correct store in the header.
2. For serialized stock: **Units → Add unit**, enter a unique **Asset tag**
   (required), optional serial/acquired date/condition notes, and actual status.
   **Save unit** for each physical unit. The app uppercases asset tags.
3. Reopen Units and verify every added identifier and the available count.
   Reserved/rented unit status belongs to the order workflow and is locked
   in this editor; do not relabel it available to satisfy a new order.
4. For bulk stock: **Locations → [store] → Quantity on hand → Save stock**.
   Calculate old quantity plus requested increment when the user says "add".
   This number is the store's *available* bulk stock: orders take from it when
   created/approved (line `bulk_stock = 'held'`), a fulfilled sale keeps it
   consumed, and a return, cancellation, close-out or release puts it back
   (064). Overview counts bulk from these store rows, not unit rows.

The Locations editor exposes a quantity field even for serialized items, but
serialized allocation checks the actual available `equipment_units` rows.
Changing only that number can produce misleading stock. Use physical units
for serialized additions.

Pickup availability needs an active product/location, enabled pickup on both,
and positive store stock. Multi-item carts offer only locations shared by every
item. A delivery-only item makes the whole cart delivery-only. Final request
approval checks enough serialized units for the requested quantities.

Implementation: [Inventory.tsx](../src/screens/Inventory.tsx),
[InventoryItemDetail.tsx](../src/screens/InventoryItemDetail.tsx),
[005 equipment](../supabase/migrations/005_equipment.sql),
[054 locations/stock](../supabase/migrations/054_multi_location_tenancy.sql),
[061 pickup stock](../supabase/migrations/061_pickup_requires_stock.sql).

## 2. Create a customer order

Inputs: correct customer or new-customer name/contact/address, store, equipment
models and quantities, rental or purchase, fulfillment, intended date/time,
and any provided driver, deposit, or instructions. A matching name alone is not
enough to distinguish two customers; use existing contact details.

1. Open **Orders → New Order** (`/new-order`). Admins must select a store; **All stores**
   cannot create an order. Staff use their assigned store.
2. Choose **Rental** or **Purchase**. Search an **Existing** customer (at least
   two characters), or choose **New Customer**. An existing customer's stored
   address is used for delivery; verify it before committing.
3. **Search equipment…**, select the intended models, and set quantities.
   This picker uses inventory assigned to the store. Rental choices require
   delivery enabled and a delivery rental price. Quantities are capped at 20
   per cart line in this staff flow.
4. Set **Schedule delivery → Date**, **Delivery time**, **Until** (blank means one
   hour), and driver when supplied. The driver list shows the store's own and
   shared drivers, marking those already booked then; a double booking is refused.
   Add deposit and access/parking instructions when applicable. An unassigned
   driver can be left unassigned; do not choose one arbitrarily.
5. Choose **Create rental order** or **Create purchase order** once.
6. Verify the returned order number in **Orders**, its customer and line items,
   unit allocation, and its stop's date/time/driver in **Delivery & Pickup**.
   Check the billing/deposit records if relevant. The staff RPC can succeed
   with unallocated lines; disclose that condition instead of reporting all
   equipment reserved. Do not create another order to fix missing allocation.
   Once a unit is in stock at that store, use **Allocate unit** on the line in
   the order detail (`allocate_line_item`). A serialized order with any
   unallocated line cannot be started, completed (including staff override) or
   marked picked up (063).
7. The equipment list and total use the selected store's delivery price
   override when one exists, matching the rate `create_staff_order` saves.

New Order is currently a delivery-oriented staff tool, with no in-store-pickup
selector. Do not substitute delivery for a user's pickup request. The guest
storefront supports pickup, but creates a request requiring approval and has
different contact/payment requirements. Use that path only when it matches
the authorized task, or identify the missing staff capability.

The `create_staff_order` RPC creates a new customer, order, lines, reservations,
delivery, and applicable billing/deposit records together. Preserve that
transaction rather than reproducing it as unrelated table writes.

Implementation: [NewOrder.tsx](../src/screens/NewOrder.tsx), latest
`create_staff_order` in [054](../supabase/migrations/054_multi_location_tenancy.sql),
[Orders.tsx](../src/screens/Orders.tsx), and
[workflowKeys.ts](../src/lib/workflowKeys.ts).

## 3. Change dates, customer details, or rates

- **Delivery/collection appointment:** open **Delivery & Pickup** (`/delivery`),
  identify the order and stop type, set date/time and applicable driver, then
  **Save**. Verify the saved stop and order status. In-store collection needs
  no driver. A date by itself does not mean equipment has been handed over.
- **Customer/contact/address/rental dates/rate/deposit/notes:** open the order
  detail → **Edit rental**. Equipment allocation and status are managed
  separately. `update_rental_details` also changes the customer record, active
  recurring charge amount, and addresses of pending/scheduled stops; understand
  those effects before changing a shared customer address. The deposit field is
  the held deposit: an edit updates the held deposit record, and clearing it
  is refused while money is held. Record the deposit first with **Mark refunded**
  or **Mark forfeited** under Billing in the order detail (`settle_deposit`,
  069). That records the outcome only; it does not move money.
  A driver stop with no address can also be filled on the Delivery board.
- **Billing due date:** use **Billing → Set due date**. This does not schedule
  delivery or return pickup.
- **Return collection:** use **Orders → Schedule pickup**, then assign date/time
  and driver on the board. An order's end-date field is not a dispatch booking.
  A completed in-store collection does not count as a return (063).

Date-only fields use `YYYY-MM-DD`; appointment fields are local clock times.
Do not let the remote machine's timezone reinterpret the user's date. For this
business use America/New_York unless the user establishes another context.

Implementation: [Delivery.tsx](../src/screens/Delivery.tsx),
[EditRentalModal.tsx](../src/screens/orders/EditRentalModal.tsx),
[046 edit rental](../supabase/migrations/046_edit_rental_details.sql),
[useSchedulePickup.ts](../src/screens/orders/useSchedulePickup.ts),
[031 returns](../supabase/migrations/031_return_lifecycle.sql),
[057 store pickup](../supabase/migrations/057_store_pickup_workflow.sql).

## 4. Add or edit a business, its branches and users

**Locations → Onboard a business or branches** (`/locations/onboard`) sets up a
whole business in one submission (migration 076): Business → Branches → Drivers
→ Review. Use it for a new business, or choose an existing business to add
branches to it.

1. **Business.** Choose an existing business or enter a new business name and
   primary contact (name plus email or phone). Existing details are preserved.
   Optionally create the **owner login**: one username that works in every
   branch of this business (orders, customers, stock, billing, dispatch). It is
   not an admin account and cannot see other businesses or admin settings.
2. **Branches.** Add one branch per store (up to 10), each with a distinct name,
   street/city/state/ZIP, phone, pickup instructions, services
   (pickup-only or pickup+delivery), owned/partner relationship and an explicit
   "open to customers now" checkbox, initially off. Its **Stock** tab picks
   products from the shared catalog with quantities and optional rental price
   overrides for that branch only; **Start from another branch's stock** copies a
   list to adjust. Serialized quantities create real units with generated asset
   tags. Its **Staff** tab adds logins confined to that branch.
3. **Drivers.** Add each driver once with a home branch, then tick every other
   branch they also serve. One login serves all ticked branches. For an existing
   business, **Share an existing driver** adds the new branches to a current
   driver without new credentials.
4. **Review** shows access (owner covers all branches; staff their branch),
   each branch's address, stock and prices, and how many drivers serve each
   delivery branch. Click **Create N branches** once. Everything commits in one
   transaction or nothing does; an error names the branch at fault. On an
   uncertain network response use **Check and finish setup**, which retries with
   the same request ID and cannot create duplicates.
5. Verify the result: each branch in Locations, its Inventory, the owner and staff
   in Staff, and driver home/shared branches in Drivers.

Existing edits remain at `/locations/[id]`. An admin can also add an owner later
(**Location → Add user → Business owner**, or **Staff → user → Role → Business
owner**); the owner's business is that user's store's business. The private
**Business contact** editor updates the owner contact shared across branches.

Shared drivers after onboarding: **Delivery & Pickup → Drivers → Branches…**
(owner or admin only) ticks the branches a driver serves. Unticking a branch
takes the driver off their open stops there. Branch staff see drivers shared
with their branch and can assign them, but only the home branch edits the
driver record. Every assignment path refuses a driver who does not serve the
stop's branch (075).

Logins use 3–63 letters/numbers/hyphens, starting with a letter or number;
`admin`, `administrator`, and `root` are reserved, and every username in one
setup must be different. Passwords require at least eight characters and no
more than 72 UTF-8 bytes. Never record passwords in reports, screenshots, or
this guide. Drafts live only in the open page. No invitation emails are sent.

Implementation: [BusinessOnboarding.tsx](../src/screens/onboarding/BusinessOnboarding.tsx)
and its step components, [validation/payload](../src/lib/businessOnboarding.ts),
[076 atomic onboarding](../supabase/migrations/076_multi_branch_onboarding.sql)
(`onboard_business`; the single-branch `onboard_business_location` from 062
still works on the same per-branch code), [owner scope](../supabase/migrations/074_business_owner_scope.sql),
[shared drivers and schedules](../supabase/migrations/075_shared_drivers_dispatch_conflicts.sql),
[review hardening](../supabase/migrations/078_business_scope_hardening.sql).
Linked records stay in one store (079): an order's customer, its stops, its
allocated units and its billing records' customer must match it, on every path;
moving a customer, order or unit between stores is refused while linked records
would be left behind. Store logins are owner, staff or driver only (080); create
platform admins from Staff. Regression check against a database with 074–080 applied (one transaction, always
rolled back): `VERIFY_DB_URL=... python3 scripts/verify-three-location.py`.

## 5. Requests, fulfillment, payments, and returns

| Operation | Action and resulting state | Verify |
| --- | --- | --- |
| Guest rental request | Cart → pickup/delivery → payment choice. Pay in store/on delivery submits `requested`; online starts `pending_payment`, then verified Stripe payment promotes it to `requested`. | Request/order number and actual payment state. Submission/payment does not promise stock or an appointment. Delivery requests go to a branch with every item in stock, owned before partner, nearest the delivery ZIP; with no stocked branch the nearest listing branch takes it for review. The cart quote uses the same rule, so the quoted price is the charged price (086). |
| Approve request | **Requests → Approve pickup / Approve delivery** calls `confirm_rental_request`. It reserves stock, creates the appropriate stop and paused rental billing, and sets `open` (displayed **Approved**). | Request leaves inbox; order, correct store/stop type, and allocations appear. Shortages block serialized approval. |
| Dispatch delivery | Staff assigns driver/date/start/**Until** on **Delivery & Pickup → Save**. Only drivers who serve the stop's branch are listed; "busy then" marks a booked driver. | Correct assigned driver with a login, saved date and window, scheduled state. A stop without an end time occupies one hour; a driver cannot hold overlapping open stops at any branch, including under simultaneous saves, but back-to-back stops are allowed (no travel buffer). Cancelling or completing a stop frees its slot. Reassigning clears the previous driver's active stop; an en-route stop returns to scheduled and the new driver starts it (064, 075). |
| Driver stop | Driver: **Start stop**, then **Complete + photo** when the real stop is complete. A second start is refused until the en-route stop is completed, unassigned or cancelled (075). Staff has **Complete (override)** for an en-route stop. | Completion, proof photo (or intentional override), order/unit state. Do not fabricate handoff evidence. Outbound stops with unallocated serialized lines are refused; a photo path must be an uploaded image under that stop's `delivery-photos/{delivery_id}/` folder (063). |
| Customer collects at store | Staff: **Mark picked up**, no driver or photo required. | Rental becomes `active` (displayed **Open**); units rented; billing starts. Purchase closes instead. |
| Record monthly payment | **Billing → Record payment** after money is actually received. | Last-paid date, next due advanced one month, and order payment badge. This records payment and queues a customer receipt (071); it does not charge a card. Each submission names the due date on screen, so a double-click, retry or concurrent duplicate is refused as already recorded; recording another month after the refresh advances again (064). The first due date is set at handoff: the billing start, or a month later when the first month was already paid (085); Set due date remains for corrections. |
| Set order payment badge | Order detail **Payment** selection calls `set_order_payment_state`. | Persisted badge and correct payment method. A manually set **Paid Online** badge is not independent proof of Stripe settlement. |
| Return pickup | **Schedule pickup**, then dispatch/start/complete the return stop. Own-store staff and admins can schedule; another store's staff is refused; a repeat returns the existing stop. A rental with no home address (e.g. collected in store) asks for the collection address first; never substitute the store's address. If the customer brings it back to the store, use Close out instead. A driver cannot start a stop with no address (068). | Order closed, billing ended, equipment released. Current implementation makes returned units immediately available. |
| Cancel before handoff | **Cancel order**, reason, confirm; Requests **Decline** invokes the same cancellation RPC with a fixed reason. | Cancelled order, released reservations, cancelled stops, ended billing. A paid order with a Stripe session attempts a full refund first and fails cancellation if refunding fails. |
| Close after handoff | **Close out (mark returned)** with a reason, for an actual return/closeout. | Closed order, released units and bulk stock, ended billing, cancelled open stops. Held deposits remain held until recorded as refunded or forfeited under Billing on the order (069). |

Online rental checkout collects the first month as a one-time Stripe payment.
Recurring rental billing currently tracks amounts and due dates; it is not an
implemented Stripe subscription collection system. Request/fulfillment changes
can trigger customer emails; treat these as part of the operation's effects.
The email outbox/Resend integration and scheduled reminders exist in migrations;
the original October 6 study did not test provider delivery. On October 26,
live COS-only QA verified the configured Resend sender and BC's read-only Gmail
inbox access. The email regression evidence is under
`docs/qa/runs/2026-10-26-email-pass/` and `2026-10-26-email-fix/`.

Customer email behavior (070–073):

- Staff order confirmations are generated at transaction commit, after equipment,
  allocation and the final monthly rate are saved. Unallocated orders say the
  team is still confirming availability. The storefront receipt workflow remains.
- Each accepted **Record payment** operation saves an immutable
  `rental_payment_receipts` record and queues a receipt with amount, paid date,
  offline payment method and next due date. It does not charge a card. Preserve
  `p_expected_due` on retries: a second request for that due period is rejected.
  An intentionally recorded next period creates its own receipt. The original
  order's first-month payment preference does not describe the new payment.
- Changing an open appointment's address or date/window sends updated details.
  An unchanged save does not repeat the email; correcting back to an earlier
  address does notify. Completed/cancelled stops do not send scheduling updates.
- The existing ten-minute scheduler now includes rental-payment and expected
  return reminders **3 days before**, **on the date**, and **7 days overdue**.
  It uses the America/New_York calendar and queues these reminders from 8 AM to
  before 8 PM. Each stage is deduplicated for the charge/order and due date.
  Only active rentals qualify. An actual driver return leg takes over expected
  return reminders; an initial in-store collection does not count as a return.
  An expected return email explicitly says it is not a booked pickup.
- Pending billing/return reminders are rechecked before sending. Payments,
  extensions, closed/cancelled rentals, ended charges and an elapsed reminder
  day invalidate stale messages; they become `skipped` without a provider call.
- Resend quota/rate-limit responses retain pending mail without consuming the
  five-attempt retry budget. The account-wide dispatcher backs off to midnight
  UTC for a daily quota, six hours for a monthly quota, and one minute for a
  request-rate limit. If the account is upgraded during a backoff, verify the
  new usage/limit first, then clear `customer_email_transport_state.blocked_until`
  with the backend operator connection. Staff/anonymous sessions cannot edit
  this state. Provider limits are separate from successful workflow commits.
- Customer email bodies and payment receipts are visible only to active staff
  at the parent order's store, or global admins. Drivers and anonymous users
  cannot read them. Reminder generation and its clock parameter are private.

Verification: `npm run test:sql` creates and removes a disposable PostgreSQL
cluster using a private Unix socket, with an inert sender. Install PostgreSQL
server tools and Python `psycopg2`; set `PG_BINDIR` if needed. It tests role/store
boundaries, transactional confirmations and receipts, replay/concurrency,
address edits, calendar/DST behavior, stale suppression and concurrent dispatch.
It never uses `DB_CONNECTION`, Vault secrets, a live provider or production
fixtures. CI runs the same SQL tests separately. For live verification, use only
explicitly approved recipients and record exact fixture IDs. The global flush
must be deferred when any queued recipient/order is outside the approved run.
Deploy only the targeted migration filenames; do not replay older migrations
or backfill historical receipts/emails.

Core status meanings:

| Stored order state | Meaning in the UI |
| --- | --- |
| `pending_payment` | Online checkout not yet verified; Orders → Unpaid. |
| `requested` | Awaiting staff review; Requests. |
| `open` | **Approved**, awaiting fulfillment. |
| `scheduled` | Fulfillment scheduled. |
| `active` | **Open**, equipment has gone out. |
| `overdue` | Billing/payment attention; distinguish from a late return. |
| `pickup_scheduled` | Return pickup queued. |
| `closed` / `cancelled` | Ended rental/purchase or cancelled order. |

The Orders **Open** tab groups approved, active, and overdue orders. Always
inspect the individual order and its stops before choosing the next action.

## Known limitations to recognize, not silently work around

1. **In-store pickup versus return pickup:** fixed in 063 and
   `src/lib/legs.ts`. A `pickup` leg with `requires_driver = false` is the
   outbound handoff; only a driver pickup is a return. Billing, order cards and
   order detail use `isReturnLeg`. Still check the stop type before reporting
   equipment returned.
2. **Customer Directory:** fixed. A card expands to contact details and the
   customer's order history; each order links to its detail.
3. **Staff pickup creation:** New Order has no fulfillment selector. This is
   a product capability gap for call-in pickup orders, not missing user input.
4. **Policy copy versus implemented behavior:** FAQ and Return Policy source
   explicitly identify their wording as draft policy. Login/dashboard copy
   also describes capabilities more broadly than implemented (for example,
   automated recurring charges). Confirm authoritative business policy before
   teaching phone agents to promise timing, deposits, coverage, or refunds.
5. **Historical docs:** ROADMAP/SCHEMA and the parent HANDOFF predate later
   changes. Examples: customer emails and first-month rental payments now have
   implementations; migration 051 returns stock directly to available; 061
   supersedes 058 by requiring positive stock for pickup-location visibility.
   The roadmap's live GPS/maps claims were not found in the current driver UI.

## Implementation map for making changes

One Next.js App Router app, React, Tailwind, Supabase Auth/Postgres/RLS/Storage,
and React Query/Realtime. `src/app` route wrappers enforce access; most actual
screen behavior is under `src/screens`. Core domain operations live in SQL RPCs
and triggers, not in Next API routes. Stripe HTTP calls run from Postgres using
a Vault secret. Shopify supplied catalog data; do not write back to Shopify
as a side effect of an inventory operation.

| Change area | Start here | Related data/behavior |
| --- | --- | --- |
| Navigation, roles, store selection | `src/lib/roles.ts`, `src/components/Layout.tsx`, `src/lib/staffAccessServer.ts`, `src/contexts/LocationContext.tsx`, `src/contexts/AuthContext.tsx`, `src/app/(staff)` | `profiles` (`business_id` for owners), `staff_module_access`; 039/054/059; owner scope, `can_access_location` and `current_business_id` in 074. |
| Products, quantities, photos | `src/screens/Inventory.tsx`, `InventoryItemDetail.tsx`, `src/components/StockStatusBadges.tsx`, `src/lib/useCatalogManager.ts` | `equipment_items`, `equipment_units`, `equipment_location_inventory`, `equipment-images`; 005/048/051/054/061. The shared catalog (items, images) is edited only by admins and Cottage Surgical's own staff/owner (`is_catalog_manager`, 078); other businesses set their stores' stock and prices. Item notes are visible within the author's business. |
| Storefront, cart, fulfillment, pricing | `src/screens/shop`, `src/components/shop/CartContext.tsx`, `CartDrawer.tsx`, `src/lib/shop.ts`, `shopServer.ts`, `fulfillment.ts`, `shopFlags.ts` | Guest requests/Stripe wrappers; 044/053–058/061. Catalog server cache is 60 seconds. |
| Staff order creation and allocation | `src/screens/NewOrder.tsx`, `Requests.tsx`, `requests/stock.ts`, `orders/useAllocateLine.ts` | `create_staff_order`, `confirm_rental_request`, `reserve_equipment_unit`; latest definitions in 054; `allocate_line_item` and `order_unallocated_count` in 063. |
| Order detail, edit, cancellation/closeout | `src/screens/Orders.tsx`, `src/screens/orders` | `update_rental_details` 046; `cancel_order` 044; `close_out_order` 051; location guards 054. |
| Stops, driver access, proof | `src/screens/Delivery.tsx`, `Drivers.tsx`, `src/screens/drivers/DriverBranches.tsx`, `src/lib/driverBranches.ts`, `src/lib/dispatchErrors.ts`, `src/lib/useDriverStopContacts.ts` | `deliveries`, `drivers`, `delivery_photos`; lifecycle 012/024–026, returns 031, driver RLS 032, assignments 043, store handoff 057; latest `schedule_pickup`, `complete_delivery`, `complete_store_pickup` in 063; `driver_branches`, `set_driver_branches`, overlap constraint `deliveries_driver_no_overlap`, one-en-route index, latest `start_delivery`, `create_staff_order` and `get_busy_driver_ids` in 075. |
| Billing and payment labels | `src/screens/Billing.tsx`, `src/screens/billing`, `src/screens/orders/format.ts`, `src/lib/useStripeReconcile.ts` | `recurring_charges`, deposits/refunds; Stripe 029/033/044/056, payment state 055–056/060. |
| Stores and accounts | `src/screens/Locations.tsx`, `LocationDetail.tsx`, `StaffDirectory.tsx`, `StaffDetail.tsx`, `StaffAccess.tsx`, `src/screens/onboarding` | `businesses`, `pharmacy_settings`, `pickup_locations`, profiles/driver linkage; 039/041/054/059; owners 074; `onboard_business` 076. |
| Customer communication and refresh | `src/lib/customerEmails.ts`, `workflowKeys.ts`, `src/components/RealtimeSync.tsx`, `NotificationsBell.tsx` | Internal notifications 011/028/034 go to admins, the order store's staff and its business owner (074); customer outbox/content/reminders 045/047/049/050. |

Migration numbers above are entry points, not substitutes for finding the last
definition of a function. Later files override earlier functions. Search the
whole migration directory for the target name before editing behavior.

### Change and verification discipline

- Read the Next.js guides identified in root AGENTS.md before writing framework
  code. Preserve existing working-tree changes. The study began with unrelated
  edits to the migration runner and an untracked UI-scenario seed.
- Trace screen → query/mutation → latest RPC/triggers/RLS → affected screens.
  Preserve transaction boundaries, serialized double-booking protection,
  location scope, and role checks. Client-side hiding is not data authorization.
- Changes to shared order detail, status, payment, or fulfillment types can
  affect Requests, Orders, Billing, and Delivery simultaneously. Update query
  projections, invalidation keys, and Realtime subscriptions as needed.
- For pricing changes, check catalog display, cart totals, staff-order rates,
  location overrides, and the server's effective Stripe/request amount. They
  are separate calculation paths; do not assume a displayed price proves the
  amount charged.
- The migration runner has no migration ledger and replays files. Migrations
  must be idempotent. Running it applies database changes; it is not a local
  verification command. Do not run seed files or a migration sweep just to
  inspect a workflow. Use a targeted, reviewed migration when deployment is
  actually part of the task.
- Run checks appropriate to the change: `npm run lint`, `npm run typecheck`,
  relevant unit tests (`npm run test:unit`), and build/browser checks when
  needed. Existing unit tests cover status/formatting, billing derivation,
  fulfillment intersections, stock checks, staff access, login, and selection.
  Existing E2E tests cover anonymous routes/catalog/cart using a Supabase
  fixture; they do not prove authenticated allocation, role isolation,
  live Stripe, or fulfillment behavior.
- For workflow changes, verify the relevant role and store, the successful
  action and a meaningful failure path, persisted records, and downstream UI.
  Payment, notification, stock, and proof-photo effects require an appropriate
  test environment or an authorized real operation; browsing alone is not
  evidence that those effects passed.
- Keep this guide's inputs, labels, effects, and known limitations synchronized
  with the final implementation.

## Screen operation notes

`bc screen` on nu-yin can inspect the actual headed browser and different roles.
Use its lease/queue (`bc screen status`, then `run` or `test`), observe before
acting, and verify after each meaningful action. Prefer current text/labels to
stored coordinates. `bc screen browser text` helps semantic inspection, but a
screenshot is needed to confirm layout, overlays, and icon-only controls.
Use `type --secret-stdin` for passwords. Log out after a role-specific study and
release the screen lease. Do not start or complete real stops to populate an
empty screen during inspection.

On the inspected authoring machine, the custom executable was
`~/.local/bin/bc`; bare `bc` could resolve to the system calculator. The runtime
checkout was `~/black_cube`. Use the tool's current help and remote-screen guide
if transport details differ; these paths are environment observations, not
dependencies of Cottage Surgical itself.
