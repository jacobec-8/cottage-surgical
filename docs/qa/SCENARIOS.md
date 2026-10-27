# Test scenario catalog

Generated from [scenarios.json](scenarios.json) with `node scripts/qa-suite.mjs catalog`.

These are test designs. See [README.md](README.md) for fixtures, role definitions, execution order, environment boundaries and readiness gates.

Run every listed variant independently. Apply the steps to that variant, using a fresh/reset fixture for destructive tests. A supporting local test does not certify the full scenario on the live deployment.

## Authentication and access

Sources: [src/contexts/AuthContext.tsx](../../src/contexts/AuthContext.tsx), [src/lib/staffAccessServer.ts](../../src/lib/staffAccessServer.ts), [src/components/ProtectedRoute.tsx](../../src/components/ProtectedRoute.tsx), [src/lib/workspaceNavigation.ts](../../src/lib/workspaceNavigation.ts), [src/lib/staffModules.ts](../../src/lib/staffModules.ts).

### AUTH-001 — Valid role logins

**P0 · device · demo pack**

**Actors:** A, SA, DA. **Setup:** Fresh independent browser sessions and active accounts.

1. Sign in at /admin-login.
2. Check role landing page and header.
3. Reload a protected page.

**Expected:** Admin reaches operations and administration; staff sees enabled store modules; driver sees My Deliveries only.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** A; SA; DA.

**Existing evidence / gap:** tests/unit/staff-login.test.ts covers username conversion only; hosted sign-in is untested locally.

### AUTH-002 — Anonymous protected-route guards

**P0 · fixture+device**

**Actors:** G. **Setup:** Signed out; no auth cookies.

1. Open each protected route directly.
2. Follow a protected link if present.
3. Inspect final page.

**Expected:** Redirect to /admin-login with working Sign In form and no private data or server exception.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** /admin; /requests; /orders; /new-order; /customers; /inventory; /inventory/00000000-0000-0000-0000-000000000001; /billing; /delivery; /drivers; /staff; /staff/00000000-0000-0000-0000-000000000001; /staff-access; /locations; /locations/onboard; /locations/00000000-0000-0000-0000-000000000001; /access-limited.

**Existing evidence / gap:** tests/e2e/anonymous-access.spec.ts executes all 17 routes with loopback Auth fixture.

### AUTH-003 — Invalid credentials and username rules

**P1 · device**

**Actors:** G. **Setup:** Active test login; no lockout-sensitive real accounts.

1. Try blank fields, wrong password and malformed username.
2. Try allowed owner email and a dynamic location username.
3. Correct input and retry.

**Expected:** Invalid entries give generic error; supported credentials work; no stale loading state or password exposure.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** blank; wrong-password; arbitrary-email; dynamic-username; allowed-owner-email.

**Existing evidence / gap:** tests/unit/staff-login.test.ts covers conversion and allowed identifiers, not Auth service.

### AUTH-004 — Inactive, missing and customer profiles

**P0 · device+api**

**Actors:** A, X. **Setup:** Disposable inactive account, missing-profile identity and customer-role identity.

1. Attempt sign-in and direct protected URL for each identity.
2. Try normal user-scoped operational read.

**Expected:** Access denied or safe sign-in redirect; missing profile has recoverable state; no protected record data.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** inactive; missing-profile; customer-role.

### AUTH-005 — Sign-out and account switch clear private data

**P0 · device · demo pack**

**Actors:** A, SA, SB, DA. **Setup:** Independent stores and recognizable fixture orders.

1. Open admin order detail.
2. Sign out.
3. Use browser Back.
4. Sign in as staff B, then driver A.

**Expected:** Prior private details never remain accessible; queries, selected records and navigation reflect current account.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

### AUTH-006 — Session expiry and backend outage fail closed

**P1 · isolated-browser**

**Actors:** SA. **Setup:** Isolated target; ability to expire test session or fail Auth requests.

1. Expire the session while detail is open.
2. Reload.
3. Restore Auth service and sign in.

**Expected:** No protected shell with stale data after revocation; usable recovery without reload loops.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** expired-session; auth-unreachable; profile-read-error.

### AUTH-007 — Driver cannot browse back office

**P0 · device**

**Actors:** DA. **Setup:** Assigned driver and known fixture record IDs.

1. Open each forbidden route directly and via browser Back.
2. Attempt record detail URL.

**Expected:** Driver remains limited to /delivery; private back-office data does not flash into view.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** /orders; /requests; /new-order; /customers; /inventory; /billing; /drivers; /staff; /staff-access; /locations; /staff/<id>; /locations/onboard.

### AUTH-008 — Staff cannot administer users or locations

**P0 · device+api**

**Actors:** SA. **Setup:** Staff account with all operational modules enabled.

1. Open admin-only list, detail and onboarding URLs.
2. Attempt normal-token administrative writes in isolated environment.

**Expected:** Denied without mutation; hidden navigation alone does not count as protection.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** /staff; /staff/<id>; /staff-access; /locations; /locations/<id>; /locations/onboard.

### AUTH-009 — Each staff module lock and restore

**P1 · device**

**Actors:** A, SA, SB, DA. **Setup:** Record original module settings; isolated environment preferred.

1. Lock the selected module as admin.
2. Observe staff A and B navigation and direct URL.
3. Confirm admin and driver access.
4. Restore original setting.

**Expected:** Lock applies globally to staff, route redirects to access-limited, admin and driver retain their intended access; restored module returns.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** dashboard; requests; orders; new_order; customers; inventory; billing; delivery; drivers.

**Existing evidence / gap:** tests/unit/staff-modules.test.ts checks route keys and missing-setting defaults; no deployed lock mutation test.

### AUTH-010 — Grouped tabs and all-locked fallback

**P1 · device**

**Actors:** A, SA, DA. **Setup:** Save module settings; isolate lock-all from other testers.

1. Try each Orders-tab and Delivery-tab combination.
2. Lock all.
3. Reopen a saved link.
4. Unlock and restore original settings.

**Expected:** Sidebar uses first permitted tab; hidden siblings stay inaccessible; empty groups disappear; driver retains standalone My Deliveries.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** orders-only; requests-only; new-order-only; delivery-only; drivers-only; all-locked; all-unlocked.

**Existing evidence / gap:** tests/unit/workspace-navigation.test.ts covers all grouped-tab combinations and role filtering.

### AUTH-011 — Live role, active-status and store reassignment

**P0 · device+api**

**Actors:** A, SA, DA. **Setup:** Disposable accounts; preserve one unaffected admin.

1. Change test user role or active flag while its session is open.
2. Focus window and wait up to 65 seconds.
3. Attempt a stale-session write.
4. Repeat with location_id reassignment through authorized isolated fixture setup.

**Expected:** Access refreshes, caches clear, and server refuses unauthorized writes immediately; no records from previous store survive a location reassignment.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

**Separate variants:** staff-to-driver; driver-to-staff; active-to-inactive; store-A-to-B.

### AUTH-012 — Self-promotion and assignment tampering

**P0 · api**

**Actors:** SA, DA. **Setup:** Isolated normal-token API harness.

1. Attempt to change own role, active flag or store scope.
2. Attempt to edit another profile.
3. Read profile again as admin.

**Expected:** Non-admin privilege escalation and cross-store reassignment fail; no partial changes.

**Verify:** Check destination, visible navigation and response data; reload; verify with a second actor. Never record passwords or tokens.

## Store isolation

Sources: [src/contexts/LocationContext.tsx](../../src/contexts/LocationContext.tsx), [supabase/migrations/054_multi_location_tenancy.sql](../../supabase/migrations/054_multi_location_tenancy.sql), [src/screens/Requests.tsx](../../src/screens/Requests.tsx), [src/screens/Dashboard.tsx](../../src/screens/Dashboard.tsx).

### TEN-001 — Admin A/B/All stores selection

**P0 · device · demo pack**

**Actors:** A. **Setup:** Two active stores; one inactive; distinct orders, customers, units, charges and drivers.

1. Select A, B, then All stores.
2. Visit each operational screen and inspect counts.
3. Reload selected scope.

**Expected:** Lists, dashboard and badges match selected scope; All stores aggregates exactly once; inactive store absent from active selector.

**Verify:** Use fixtures with distinct store IDs and matching display names; compare UI with normal-token RLS responses and admin evidence.

**Separate variants:** dashboard; requests; orders; customers; inventory; billing; delivery; drivers.

### TEN-002 — Staff store isolation in UI and data

**P0 · device+api · demo pack**

**Actors:** SA, SB. **Setup:** Two stores with recognizable private records.

1. Compare operational lists.
2. Open other-store known IDs and selected-order query URLs.
3. Read other-store rows with current user token.

**Expected:** No other-store private records, contacts, billing or counts are returned; access denial is safe. Shared public catalog is allowed.

**Verify:** Use fixtures with distinct store IDs and matching display names; compare UI with normal-token RLS responses and admin evidence.

**Separate variants:** orders+lines; customers; deliveries; units; recurring_charges+deposits+refunds; drivers; profiles.

### TEN-003 — Cross-store mutation RPCs

**P0 · api**

**Actors:** SA. **Setup:** Disposable B order, charge, unit, driver, line and stop IDs; snapshot records first.

1. Call each operation with a B ID while signed in as A.
2. Compare all affected rows as admin.

**Expected:** Each call is denied or changes zero rows; no side effects to order, stock, billing, dispatch or customer.

**Verify:** Use fixtures with distinct store IDs and matching display names; compare UI with normal-token RLS responses and admin evidence.

**Separate variants:** confirm_rental_request; cancel_order; close_out_order; schedule_pickup; update_rental_details; set_order_payment_state; record_rental_payment; reserve_equipment_unit; release_line_item; start_delivery; complete_delivery; complete_store_pickup; direct-table-update.

### TEN-004 — Cross-store customer and driver injection

**P0 · api**

**Actors:** SA. **Setup:** A order creation form plus B customer and driver IDs.

1. Submit New Order payload referencing B customer.
2. Repeat with B driver and B unit.
3. Verify transaction rollback.

**Expected:** Cannot create or link cross-store private relationships; no orphan customer, order, reservation or stop.

**Verify:** Use fixtures with distinct store IDs and matching display names; compare UI with normal-token RLS responses and admin evidence.

### TEN-005 — Store change while forms and drawers are open

**P0 · device**

**Actors:** A. **Setup:** A customer, cart and driver selected in New Order; A order detail open in a separate page.

1. Switch header to B while form has values.
2. Attempt create.
3. Switch detail page scope and reload.

**Expected:** Selected customer, items and driver reset or revalidate; no A order is created under B; stale selected detail cannot defeat scope.

**Verify:** Use fixtures with distinct store IDs and matching display names; compare UI with normal-token RLS responses and admin evidence.

### TEN-006 — Stale saved, removed or inactive location

**P1 · isolated-browser**

**Actors:** A, SA. **Setup:** Saved admin scope referencing inactive/deleted fixture location; staff with no location.

1. Reload.
2. Visit New Order and list screens.
3. Attempt create with invalid location.

**Expected:** Explicit recoverable empty/selection state; no silent global staff access or creation in an arbitrary store.

**Verify:** Use fixtures with distinct store IDs and matching display names; compare UI with normal-token RLS responses and admin evidence.

**Separate variants:** saved-inactive; saved-missing; staff-unassigned.

### TEN-007 — Store-owned products and prices (rewritten 2026-10-27, migration 100)

**P0 · device · demo pack**

**Actors:** owner O, staff SA (store A), SB (store B). **Setup:** owner product P stocked at A and B.

1. SA tries to rename P; SA creates a store-only product Q; SA sets A's price override for P.
2. SB opens Inventory and P; SB searches for Q.
3. O renames P.

**Expected:** SA cannot change P (owner only); Q is visible and editable at A only and cannot be stocked at B; A's price override changes A's price only; SB sees nothing of A's changes; only the owner's rename of P is visible at both stores.

**Verify:** `scripts/check_store_separation.py` and the "Store separation (100)" block of `scripts/verify-three-location.py` (store B's view unchanged after store A's actions).

## Public storefront and cart

Sources: [src/screens/shop/Shop.tsx](../../src/screens/shop/Shop.tsx), [src/screens/shop/ProductPage.tsx](../../src/screens/shop/ProductPage.tsx), [src/components/shop/CartContext.tsx](../../src/components/shop/CartContext.tsx), [src/components/shop/CartDrawer.tsx](../../src/components/shop/CartDrawer.tsx), [src/lib/fulfillment.ts](../../src/lib/fulfillment.ts), [src/lib/shopFlags.ts](../../src/lib/shopFlags.ts).

### SHOP-001 — Public route smoke and history

**P0 · fixture+device · demo pack**

**Actors:** G. **Setup:** Live target or isolated catalog.

1. Open each route directly.
2. Follow header/footer links.
3. Use Back and Forward.
4. Reload.

**Expected:** Header/footer and intended content render with no client/hydration error or broken navigation.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** /; /product/<valid-handle>; /how-it-works; /faq; /return-policy.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers fixtures and browser history.

### SHOP-002 — Catalog search and categories

**P1 · device**

**Actors:** G. **Setup:** At least two products across categories.

1. Search name with mixed case and whitespace.
2. Use q URL parameter and category filters.
3. Clear search and try no matches.

**Expected:** Matching results and empty state are accurate; query initializes input; clearing restores results.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** name; q-parameter; category; no-match.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts partially covers q search; its error-state fallback does not prove filtering.

### SHOP-003 — Product missing, inactive or unavailable

**P1 · device**

**Actors:** G. **Setup:** Valid, unknown, inactive and disabled-offering fixtures.

1. Open product handles directly.
2. Inspect Rent controls, prices, stock and image fallback.

**Expected:** Missing/inactive products cannot be ordered; no missing price becomes a free rental; unavailable state is clear.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** unknown; inactive; no-price; no-fulfillment; image-failure.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers missing product only.

### SHOP-004 — Rent cart totals and persistence

**P0 · fixture+device · demo pack**

**Actors:** G. **Setup:** S rental with pickup 100 and delivery 140; two units requested.

1. Add from card and product page.
2. Increase/decrease/remove quantity.
3. Close/reopen cart and reload.
4. Empty cart.

**Expected:** One intended line per item/mode; correct quantities and totals persist; removed lines stay removed; empty cart cannot checkout.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers cart persistence and removal with fixture prices.

### SHOP-005 — Cart quantity bounds and corrupted storage

**P1 · isolated-browser**

**Actors:** G. **Setup:** Isolated browser storage.

1. Try zero, negative, fractional, excessive quantity and invalid JSON in cs_cart_v1.
2. Reload and open checkout.

**Expected:** Safe bounded quantities or explicit rejection; no crash, negative total or silent expensive quantity.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** zero; negative; fractional; over-50; invalid-json; malformed-line.

### SHOP-006 — Pickup and delivery have matching payment methods

**P0 · fixture+device · demo pack**

**Actors:** G. **Setup:** S supports both methods.

1. Select pickup then delivery then pickup.
2. Inspect address requirements, total and selected payment rail.

**Expected:** Pickup offers in-store/online; delivery offers on-delivery/online; incompatible previous rail resets; total updates to fulfillment price.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers payment-choice visibility, not persisted payment.

### SHOP-007 — Multi-item fulfillment intersection

**P0 · device**

**Actors:** G. **Setup:** S at A/B; T at B only; delivery-only D; pickup-only P at A.

1. Build each variant cart.
2. Open checkout.
3. Inspect available fulfillment and shared locations.

**Expected:** Only common pickup locations appear; delivery requires every item delivery-enabled; impossible cart cannot submit.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** S+T=>B; S+D=>delivery-only; S+P=>pickup-A; D+P=>no-valid-method.

**Existing evidence / gap:** tests/unit/fulfillment.test.ts covers intersection and delivery-only item.

### SHOP-008 — One, multiple and zero pickup locations

**P1 · device**

**Actors:** G. **Setup:** Product eligible at one, two or no active stocked stores.

1. Open checkout for each fixture.
2. Inspect selected location.
3. Attempt submit before choosing among multiple.

**Expected:** One location auto-selects; multiple require explicit choice; zero disables pickup; store details/instructions match choice.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** one; multiple; zero.

**Existing evidence / gap:** tests/unit/fulfillment.test.ts covers selection; browser fixtures cover one location.

### SHOP-009 — Stale saved cart revalidates catalog and store

**P0 · device**

**Actors:** G, A. **Setup:** Cart saved before admin changes stock/configuration.

1. Change product or store after cart saved.
2. Reload cart and checkout.
3. Submit stale API payload in isolated target.

**Expected:** Unavailable pickup/item is rejected by server; refreshed choices do not offer inactive or out-of-stock stores. Prices agree or change is explained.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** zero-stock; store-inactive; pickup-disabled; product-inactive; price-change.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers refreshing saved pickup settings only.

### SHOP-010 — Checkout required fields and recovery

**P1 · device**

**Actors:** G. **Setup:** S in cart.

1. Submit missing name/email.
2. Try malformed email.
3. Select delivery with missing address/city/ZIP.
4. Correct fields and retry.

**Expected:** Inline/native validation prevents bad submission; valid values remain after error; pickup does not require delivery address.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** missing-name; missing-email; invalid-email; incomplete-address; corrected.

### SHOP-011 — Guest pickup request enters right store

**P0 · device · demo pack**

**Actors:** G, SA, SB. **Setup:** S at A; controlled test contact address and inbox.

1. Submit pickup with pay in store.
2. Record returned order number.
3. Inspect Requests from SA, SB and A.

**Expected:** Exactly one requested rental at A with correct lines/rate/payment preference and pickup location; only authorized staff sees it.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

### SHOP-012 — Guest delivery request enters right store

**P0 · device · demo pack**

**Actors:** G, SA, A. **Setup:** S or D; delivery-capable store A; controlled contact.

1. Submit delivery with pay delivery person and instructions.
2. Inspect persisted request and location routing.

**Expected:** One requested rental with on_delivery preference and full service address; eligible fulfillment store selected; no premature stock reservation or billing start.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

### SHOP-013 — Submission double-click and uncertain retry

**P0 · isolated-browser**

**Actors:** G. **Setup:** Disposable checkout; ability to delay or drop response.

1. Double-click submit.
2. Repeat with response lost after commit.
3. Inspect orders before retry.

**Expected:** One request for double-click; uncertain commit is reconciled before retry; no duplicate order/customer/email. Lack of server idempotency is a defect to record.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** double-click; committed-response-lost; two-tabs.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts mocks one successful double-click request; no DB/network retry guarantee.

### SHOP-014 — Public purchases stay disabled

**P1 · device**

**Actors:** G. **Setup:** Current SHOP_PURCHASES_ENABLED=false.

1. Browse cards and product page.
2. Inspect any restored legacy purchase cart in isolated browser.

**Expected:** No public Buy flow appears in normal navigation; stale purchase state is handled honestly. Staff purchases remain a separate test.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Existing evidence / gap:** src/lib/shopFlags.ts is code evidence only.

### SHOP-015 — Sensitive data and catalog error states

**P1 · isolated-browser**

**Actors:** G. **Setup:** Catalog endpoint unavailable or empty; public response inspection.

1. Fail catalog reads or return no products.
2. Open storefront.
3. Inspect public catalog/location data.

**Expected:** Page remains usable and communicates unavailable/empty catalog; no customer, owner contact, private staff notes or auth secrets exposed.

**Verify:** Compare catalog/cart totals and choices with current product/store configuration; inspect request payload only without secrets; verify persisted order when submitted.

**Separate variants:** catalog-error; empty-catalog; public-data-privacy.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers rendering with catalog unavailable, not all privacy assertions.

## Online payments

Sources: [src/screens/shop/CheckoutSuccess.tsx](../../src/screens/shop/CheckoutSuccess.tsx), [src/components/shop/CartDrawer.tsx](../../src/components/shop/CartDrawer.tsx), [src/lib/useStripeReconcile.ts](../../src/lib/useStripeReconcile.ts), [supabase/migrations/044_online_rental_payments.sql](../../supabase/migrations/044_online_rental_payments.sql), [supabase/migrations/056_fulfillment_payment_methods.sql](../../supabase/migrations/056_fulfillment_payment_methods.sql), [supabase/migrations/060_sync_recorded_payment_state.sql](../../supabase/migrations/060_sync_recorded_payment_state.sql).

### PAY-001 — Online first-month rental lifecycle

**P0 · integration · demo pack**

**Actors:** G, SA, A. **Setup:** Stripe test-mode target, S qty 2, pickup/delivery prices known, controlled inbox.

1. Choose online payment.
2. Inspect pending_payment before completing test Checkout.
3. Complete payment.
4. Return to success.
5. Inspect Requests.

**Expected:** First month total is correct; verified payment promotes exactly one rental to requested/paid_online; stock approval remains staff work.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

**Separate variants:** pickup; delivery.

### PAY-002 — Stripe cancellation, decline and expiration

**P0 · integration**

**Actors:** G, A. **Setup:** Test Checkout sessions.

1. Cancel or decline card payment.
2. Inspect return page and Unpaid.
3. Expire session and run supported reconcile.

**Expected:** No paid badge or stock allocation without settlement; pending/expired states are recoverable and reconciliation cancels only eligible abandoned orders.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

**Separate variants:** cancel; card-decline; expired.

### PAY-003 — Payment success retry and invalid reference

**P1 · isolated-browser**

**Actors:** G. **Setup:** Controlled Stripe response or isolated mock.

1. Open success with missing/invalid ref.
2. Repeat with paid, unpaid, delayed and transient-error responses.

**Expected:** Only paid verification clears cart as success; four-attempt retry is bounded; error/unconfirmed copy is accurate; no duplicate promotions.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

**Separate variants:** missing-ref; invalid-ref; paid; unpaid; delayed-paid; API-error.

**Existing evidence / gap:** tests/e2e/anonymous-routes.spec.ts covers missing-ref rendering only.

### PAY-004 — Paid session without return redirect

**P0 · integration**

**Actors:** G, SA. **Setup:** Settled test Checkout; close tab before app redirect.

1. Open Requests/Orders as staff.
2. Allow/call reconciliation at eligible session age.
3. Inspect promoted request.

**Expected:** Payment is discovered without customer return; exactly one requested rental; report real elapsed reconciliation time.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

### PAY-005 — Repeated verify and concurrent reconciliation

**P0 · integration**

**Actors:** SA, A. **Setup:** Paid pending test order.

1. Verify same order twice and from two sessions.
2. Run reconciliation concurrently.
3. Inspect order, stock and outbox.

**Expected:** Promotion happens once; no duplicate lines, billing, notifications or emails.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

### PAY-006 — Bad Stripe config or unreachable provider

**P1 · integration**

**Actors:** G, SA. **Setup:** Isolated target; unset test key, disallowed redirect origin or provider outage.

1. Start checkout.
2. Try invalid redirect base via API.
3. Run reconcile.
4. Restore valid config.

**Expected:** No arbitrary redirect or false success; actionable customer error; operational screens remain usable; failed checkout leaves no misleading paid state.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

**Separate variants:** not-configured; invalid-redirect; provider-unreachable.

### PAY-007 — Payment amount and price tampering

**P0 · integration**

**Actors:** G. **Setup:** Normal anonymous API harness and test-mode Stripe.

1. Manipulate local cart price/quantity.
2. Submit known item IDs.
3. Inspect persisted rate and Stripe amount.

**Expected:** Server uses allowed catalog/location prices and validated quantities; customer cannot choose a cheaper amount via payload.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

**Separate variants:** pickup-override; delivery-override; tampered-price; negative-quantity; over-50.

### PAY-008 — Badge state and fulfillment restrictions

**P0 · device+api**

**Actors:** A, SA. **Setup:** Disposable pickup, delivery, refunded and pending orders.

1. Set each supported payment state.
2. Try in-store for delivery and on-delivery for pickup via API.
3. Reopen order in second session.

**Expected:** Valid badge persists with matching preference; invalid pairs and refunded changes reject; no processor charge occurs.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

**Separate variants:** paid_online; paid_in_store; paid_on_delivery; not_paid; refunded-guard.

### PAY-009 — Anonymous verify does not disclose order data

**P1 · api**

**Actors:** G, DA, SA. **Setup:** Isolated integration target; foreign and invalid order UUIDs.

1. Call verify_stripe_payment with unknown, other-store and unrelated test order IDs.
2. Inspect returned data and side effects.

**Expected:** Public success verification reveals no private order/customer/Stripe credentials; staff/driver cannot use helper to bypass scope.

**Verify:** Use Stripe test mode and normal role tokens in an isolated integrated environment; verify provider event/session plus persisted status. Never treat a manual badge as processor evidence.

## Request review and allocation

Sources: [src/screens/Requests.tsx](../../src/screens/Requests.tsx), [src/screens/requests/RequestActions.tsx](../../src/screens/requests/RequestActions.tsx), [src/screens/requests/stock.ts](../../src/screens/requests/stock.ts), [supabase/migrations/054_multi_location_tenancy.sql](../../supabase/migrations/054_multi_location_tenancy.sql), [supabase/migrations/057_store_pickup_workflow.sql](../../supabase/migrations/057_store_pickup_workflow.sql).

### REQ-001 — Approve delivery with stock

**P0 · device · demo pack**

**Actors:** SA, A. **Setup:** Fresh requested delivery rental, qty 2, two available A units.

1. Open detail and verify customer/items/payment.
2. Approve delivery once.
3. Refresh all affected screens.

**Expected:** Request leaves inbox; approved/open order, two unique reserved units, one driver-required delivery and one paused recurring charge appear.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

### REQ-002 — Approve pickup with stock

**P0 · device · demo pack**

**Actors:** SA, DA. **Setup:** Fresh requested pickup rental at A; available units.

1. Approve pickup.
2. Open dispatch board and driver session.

**Expected:** Correct store-address pickup leg has requires_driver=false and no driver; absent from driver queue; billing paused until handoff.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

### REQ-003 — Serialized shortage and aggregate duplicate lines

**P0 · device+api · demo pack**

**Actors:** SA. **Setup:** Requested qty exceeds available A units; plenty at B.

1. Open request and inspect shortage.
2. Attempt confirm through UI and normal API.
3. Add exactly missing A units and retry.

**Expected:** Approval blocks atomically until A has enough units; duplicates aggregate; B stock cannot satisfy A; failed approval reserves nothing.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

**Separate variants:** qty-short; repeated-item-lines; wrong-store-stock.

**Existing evidence / gap:** tests/unit/requests-stock.test.ts covers UI shortage derivation only.

### REQ-004 — Concurrent last-unit approvals

**P0 · integration · demo pack**

**Actors:** SA, SA2. **Setup:** Two requested rentals each need the single available A unit.

1. Keep both request details open in independent sessions.
2. Approve together.
3. Inspect both orders and unit references.

**Expected:** One approval wins; loser reports shortage/already-handled; active unit never assigned twice; no partial legs or charges.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

### REQ-005 — Approve versus decline same request

**P1 · integration**

**Actors:** SA, SA2. **Setup:** One fresh requested rental.

1. Approve in one session while other declines.
2. Reopen request and inspect all side effects.

**Expected:** One terminal decision is coherent; no cancelled order retains active reservations or live billing; stale actor gets clear result.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

### REQ-006 — Decline and duplicate approval

**P1 · device**

**Actors:** SA. **Setup:** Fresh request with no reservations.

1. Decline with provided default reason.
2. Inspect Cancelled and audit.
3. Repeat approve/decline on handled request.

**Expected:** Decline cancels once without allocating equipment; repeat action cannot recreate delivery, charge or email; handled-state message appears.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

**Separate variants:** decline; duplicate-approve; duplicate-decline.

### REQ-007 — Bulk request approval and stock reconciliation

**P1 · integration**

**Actors:** SA. **Setup:** Bulk B qty 5 with stock above, equal and below requirement.

1. Approve each variant.
2. Fulfill then return/cancel.
3. Compare counts.

**Expected:** Bulk policy is explicit; no negative or accidentally replenished stock. Existing helper exempts bulk shortage checks, so record implemented behavior and product decision rather than assuming serialized guarantees.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

**Separate variants:** enough; exact; shortage.

**Existing evidence / gap:** tests/unit/requests-stock.test.ts explicitly documents bulk bypass in UI helper.

### REQ-008 — Approval of stale or changed product

**P1 · integration**

**Actors:** SA, A. **Setup:** Request open while product/store deactivated, price changed or stock consumed.

1. Mutate fixture configuration in second session.
2. Approve original request.

**Expected:** Server revalidates eligibility/stock or gives explicit preserved-price behavior; no silent invalid fulfillment or price mismatch.

**Verify:** After each action compare rental_orders, lines, units, location inventory, deliveries, recurring_charges, Requests count and Orders from another session.

**Separate variants:** inactive-product; inactive-store; changed-price; consumed-stock.

## Staff order entry and order detail

Sources: [src/screens/NewOrder.tsx](../../src/screens/NewOrder.tsx), [src/screens/Orders.tsx](../../src/screens/Orders.tsx), [src/screens/orders/OrderDetailPanel.tsx](../../src/screens/orders/OrderDetailPanel.tsx), [src/screens/orders/EditRentalModal.tsx](../../src/screens/orders/EditRentalModal.tsx), [supabase/migrations/046_edit_rental_details.sql](../../supabase/migrations/046_edit_rental_details.sql), [supabase/migrations/054_multi_location_tenancy.sql](../../supabase/migrations/054_multi_location_tenancy.sql).

### ORD-001 — Create rental with existing customer

**P0 · device · demo pack**

**Actors:** SA. **Setup:** Known A customer with verified address, S units and linked DA.

1. Search at least two characters.
2. Add S qty 2.
3. Choose date/time/driver and deposit.
4. Create once.

**Expected:** One order with correct address, totals, allocated units, scheduled delivery, paused charge and applicable deposit; input clears only after success.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

### ORD-002 — Create rental and customer atomically

**P0 · device+integration · demo pack**

**Actors:** SA. **Setup:** Unique controlled contact; stocked A product.

1. Choose New Customer.
2. Enter contact/address.
3. Create.
4. Inject late failure on a separate isolated run.

**Expected:** Success persists one customer and complete workflow; failure rolls all new records back; no orphan customer.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

### ORD-003 — Staff purchase lifecycle

**P0 · device**

**Actors:** SA, DA. **Setup:** Purchasable serialized and bulk products at A.

1. Choose Purchase.
2. Add items and create.
3. Fulfill delivery with driver photo.
4. Inspect completed order and stock.

**Expected:** Sale total uses sale prices; purchase closes on fulfillment, serialized sold units retire and lines deactivate; no recurring rental charge.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

**Separate variants:** serialized; bulk.

### ORD-004 — Missing input, quantity bounds and mode switches

**P1 · device**

**Actors:** SA. **Setup:** New Order page; optional delivery scheduling fields initially blank.

1. Try no customer or no item.
2. Set qty 1,20,21 via controls and repeated item search clicks.
3. Toggle Rental/Purchase with existing lines.
4. Try invalid deposit and API dates.

**Expected:** Valid totals equal persisted quantities and rates; rejected/clamped values are explained; mode switch cannot retain ineligible lines or wrong rates.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

**Separate variants:** missing-input; qty-1; qty-20; qty-over-20; repeated-add-over-20; mode-switch; invalid-deposit; invalid-date.

### ORD-005 — All stores and pickup-only location creation guards

**P1 · device**

**Actors:** A, SA. **Setup:** Admin All stores scope and pickup-only fixture store P.

1. Open New Order in All stores then pickup-only store.
2. Attempt create using normal token.

**Expected:** All stores requires explicit selection; unsupported delivery creation at pickup-only store fails clearly; no order in fallback store.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

### ORD-006 — Staff shortage is explicitly unallocated

**P0 · device**

**Actors:** SA. **Setup:** Rental qty 2 with only one available A serialized unit.

1. Create staff order.
2. Inspect success message, details, stock and dispatch.
3. Attempt fulfillment with unallocated item.

**Expected:** Created order discloses unallocated count; allocated count matches actual stock; cannot claim all reserved or fulfill missing equipment silently.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

### ORD-007 — Create double-click and lost response

**P0 · isolated-browser**

**Actors:** SA. **Setup:** Disposable customer and available units; delayed response.

1. Double-click create.
2. Repeat with response lost after commit.
3. Search returned/customer data before retry.

**Expected:** One intended order; no duplicate customer or reservation; uncertain outcomes are reconciled and not blindly retried.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

**Separate variants:** double-click; committed-response-lost.

### ORD-008 — Order tabs, search, links and detail panel

**P1 · device**

**Actors:** SA, A. **Setup:** Fixtures in every supported status, including pending_payment and unallocated.

1. Switch tabs and search.
2. Open order card by keyboard.
3. Reload selected-order URL.
4. Use Escape, Back and Close.

**Expected:** Correct membership, badges, totals and selected ID; focus returns safely; invalid/missing/cross-store selected IDs do not leak or crash.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

**Separate variants:** status-tabs; text-search; deep-link; keyboard; invalid-id.

**Existing evidence / gap:** tests/unit/orders-format.test.ts, selected-param.test.ts and status.test.ts cover helper formatting only.

### ORD-009 — Edit customer, address, rate, deposit and notes

**P0 · device · demo pack**

**Actors:** SA, SA2, DA. **Setup:** Active rental with related pending/scheduled stops and another order sharing customer.

1. Edit rental fields.
2. Save and reopen.
3. Inspect shared customer, recurring charge, pending and completed stop addresses.

**Expected:** Only intended fields change; linked customer effects are visible; active recurring amount syncs; completed historical stops and allocation remain coherent.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

### ORD-010 — Dates, invalid rates and stale detail conflicts

**P1 · device**

**Actors:** SA, SA2. **Setup:** Known start/end dates; two open edit panels.

1. Set end before start, negative/decimal rate and blank required name.
2. Cancel.
3. Save conflicting valid changes in two sessions.

**Expected:** Invalid values reject without partial update; cancel discards changes; conflict policy does not silently overwrite unrelated edits.

**Verify:** Capture order number/UUID and compare customer, lines, rates, stock, delivery, deposit and billing after reload from another account.

**Separate variants:** end-before-start; invalid-rate; missing-name; cancel; concurrent-edit.

## Inventory and catalog

Sources: [src/screens/Inventory.tsx](../../src/screens/Inventory.tsx), [src/screens/InventoryItemDetail.tsx](../../src/screens/InventoryItemDetail.tsx), [supabase/migrations/005_equipment.sql](../../supabase/migrations/005_equipment.sql), [supabase/migrations/048_equipment_image_uploads.sql](../../supabase/migrations/048_equipment_image_uploads.sql), [supabase/migrations/051_return_units_to_inventory.sql](../../supabase/migrations/051_return_units_to_inventory.sql), [supabase/migrations/061_pickup_requires_stock.sql](../../supabase/migrations/061_pickup_requires_stock.sql).

### INV-001 — Create serialized product then actual units

**P0 · device · demo pack**

**Actors:** SA, A. **Setup:** Unique QA product and selected A store.

1. Add rentable product with pickup/delivery prices.
2. Observe zero initial stock.
3. Add two unique asset-tag units at A.

**Expected:** One catalog product; two physical available units at A; counts and pickup availability become two; no invented serial numbers.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

### INV-002 — Create bulk stock and edit local quantity

**P0 · device**

**Actors:** SA. **Setup:** Bulk B at A; known current quantity.

1. Create bulk offering or assign existing one.
2. Set Quantity on hand.
3. Increment from known baseline and reload.

**Expected:** Location stock persists as intended absolute total; no equipment_units created; other-store counts stay unchanged.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

### INV-003 — Catalog offering validation and decimals

**P1 · device**

**Actors:** SA. **Setup:** Disposable product.

1. Try no rental/sale offering or no fulfillment.
2. Omit required price.
3. Enter negative/decimal prices.
4. Save valid alternative.

**Expected:** Invalid combinations reject; valid cents persist; no blank price silently becomes zero; at least one usable offering and method.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

**Separate variants:** no-offering; no-fulfillment; missing-price; negative-price; decimal-price.

### INV-004 — Unit tags, duplicate identifiers and locked status

**P0 · device**

**Actors:** SA. **Setup:** Available, reserved and rented A units.

1. Add lowercase tag then duplicate uppercase tag.
2. Edit available unit details.
3. Try to relabel reserved/rented unit available.

**Expected:** Tags normalize consistently; duplicate identity rejects; active allocation cannot be bypassed through unit editor.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

**Separate variants:** tag-normalization; duplicate-tag; reserved-lock; rented-lock.

### INV-005 — Assign and unassign product locations

**P1 · device**

**Actors:** SA, A. **Setup:** Shared S at A/B; available and active reserved units.

1. Change location assignment/pickup enabled flag.
2. Attempt removal with live units/orders.
3. Inspect storefront choices.

**Expected:** Assignments and stock stay consistent; no removal strands active equipment or exposes another store; checkout revalidates changed configuration.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

**Separate variants:** assign; disable-pickup; remove-empty; remove-with-units.

### INV-006 — Local serialized quantity field versus actual units

**P0 · integration**

**Actors:** SA. **Setup:** S has one actual available unit at A.

1. Set location quantity higher without adding units.
2. Request two S.
3. Attempt approval.

**Expected:** Real unit allocator remains authoritative; no oversubscription; UI count inconsistency is reported as defect rather than used to fake stock.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

### INV-007 — Inventory image upload and failure rollback

**P1 · device**

**Actors:** SA. **Setup:** Disposable product; allowed image files and isolated storage failure.

1. Upload image.
2. Try invalid type and over-5MB file.
3. Force metadata save failure after upload.
4. Reopen product.

**Expected:** Valid image persists; invalid upload rejected; no false saved preview; newly orphaned upload cleaned up on failed save.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

**Separate variants:** jpg; png; webp; gif; invalid-type; over-5MB; metadata-failure.

### INV-008 — Catalog deactivate and history

**P1 · device**

**Actors:** SA, G. **Setup:** Product in active rental and saved guest cart.

1. Deactivate product.
2. Reopen catalog, active order and saved cart.

**Expected:** Public ordering stops; historical order retains readable item/unit identity; active rental can still complete and return.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

### INV-009 — Product notes, linked rentals and filters

**P1 · device**

**Actors:** SA, SA2. **Setup:** Serialized item with current and returned assignments.

1. Search SKU/name/category/stock filters.
2. Open detail and linked rental.
3. Add multiline note with HTML-like text.
4. Reopen as second staff.

**Expected:** Correct assignments and status; notes retain author/time and render as text; private notes absent from public storefront.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

**Separate variants:** filters; linked-rentals; notes.

### INV-010 — Return unit to stock action state guards

**P1 · device+api**

**Actors:** SA. **Setup:** Unassigned returned/available, rented, reserved and retired units.

1. Invoke Return to stock where offered.
2. Attempt unsafe transitions with normal token.
3. Inspect active lines and available counts.

**Expected:** Only valid transition succeeds; cannot make allocated or sold equipment available twice; counts agree with actual units.

**Verify:** Reopen product/unit/location tabs; compare actual equipment_units and location counts, storefront availability and price in a second user session.

**Separate variants:** available; rented; reserved; retired.

## Delivery, store collection and proof

Sources: [src/screens/Delivery.tsx](../../src/screens/Delivery.tsx), [src/lib/useDriverStopContacts.ts](../../src/lib/useDriverStopContacts.ts), [supabase/migrations/026_start_delivery_driver_only.sql](../../supabase/migrations/026_start_delivery_driver_only.sql), [supabase/migrations/032_driver_rls.sql](../../supabase/migrations/032_driver_rls.sql), [supabase/migrations/035_photo_storage_and_redirect_allowlist.sql](../../supabase/migrations/035_photo_storage_and_redirect_allowlist.sql), [supabase/migrations/057_store_pickup_workflow.sql](../../supabase/migrations/057_store_pickup_workflow.sql).

### FUL-001 — Schedule and assign delivery

**P0 · device · demo pack**

**Actors:** SA, DA. **Setup:** Approved delivery order at A, linked active driver DA.

1. Set appointment date/time and driver.
2. Save.
3. Reload and open DA session.

**Expected:** Scheduled stop/order agree; only assigned driver receives it and contact/instructions; appointment is America/New_York local time.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

### FUL-002 — Driver start and photo completion

**P0 · device · demo pack**

**Actors:** DA, SA. **Setup:** Scheduled assigned rental delivery; controlled test proof image.

1. Start stop as DA.
2. Complete + photo.
3. Reload Completed and Orders/Billing/Inventory.

**Expected:** En route then completed; proof linked and viewable; rental active/Open, units rented, billing current and start date set once.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

### FUL-003 — Only assigned driver can start

**P0 · device+api**

**Actors:** DA, DA2, SA. **Setup:** Assigned DA stop; DA2 same store but unrelated.

1. Try staff Start and DA2 start API.
2. Try start unassigned and already-completed stop.

**Expected:** Only assigned eligible driver can start; rejected actions preserve stock/order/billing; UI control availability matches server.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** staff; other-driver; unassigned; completed.

### FUL-004 — Driver completion requires valid proof

**P0 · device+api**

**Actors:** DA. **Setup:** En-route assigned stop and normal-token API harness.

1. Complete with no proof path, wrong stop path or nonexistent object.
2. Try invalid/oversized file.
3. Retry with valid image.

**Expected:** No false completed stop without required evidence; errors preserve en-route state and permit valid retry.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** missing-photo; other-stop-path; nonexistent-object; invalid-type; oversized-upload.

### FUL-005 — Photo upload or completion RPC fails

**P1 · isolated-browser**

**Actors:** DA, SA. **Setup:** Isolated browser with failure injection.

1. Fail upload.
2. Repeat with upload success then complete_delivery failure.
3. Restore endpoint and retry.
4. Inspect photo rows/objects.

**Expected:** No partial completed lifecycle, duplicate state changes or inaccessible evidence; usable retry; orphan storage recorded if not cleaned.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** upload-fails; RPC-fails-after-upload.

### FUL-006 — Staff override without photo

**P0 · device · demo pack**

**Actors:** SA, DA. **Setup:** En-route assigned test stop.

1. Complete (override) as staff.
2. Reopen Completed.
3. Attempt same operation as unrelated driver.

**Expected:** Authorized override completes coherent lifecycle with no-photo indication; driver cannot use override to evade proof.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

### FUL-007 — Reassign driver and revoke old access

**P0 · device · demo pack**

**Actors:** SA, DA, DA2. **Setup:** Scheduled and en-route stop variants open in both driver sessions.

1. Reassign DA to DA2 and Save.
2. Inspect both queues without manual reload.
3. Attempt stale DA action and proof URL.

**Expected:** Old driver loses stop/contact access and cannot act; new driver sees correct stop; driver active marker stays coherent.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** scheduled; en-route.

### FUL-008 — Store collection date and handoff

**P0 · device · demo pack**

**Actors:** SA, DA. **Setup:** Approved pickup rental at A.

1. Set pickup date/time without driver.
2. Save.
3. Mark picked up.
4. Inspect driver queue and rental/billing/units.

**Expected:** In-store appointment schedules without driver; handoff activates rental, rents units and starts billing once; driver sees no store collection.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

### FUL-009 — Collection is not a return regression

**P0 · device · demo pack**

**Actors:** SA. **Setup:** Complete FUL-008; rental remains active with equipment held by customer.

1. Open Billing and order detail/card.
2. Inspect return label and Schedule pickup action.
3. Attempt schedule actual return pickup.

**Expected:** Billing must not say Returned; real return scheduling must be available; initial requires_driver=false pickup leg cannot count as equipment returned.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Existing evidence / gap:** Known source-level defect: billing/derive.ts pickupLeg and OrderCard/OrderDetailPanel checks ignore requires_driver; requires deployed reproduction.

### FUL-010 — Schedule clear, inactive and unlinked drivers

**P1 · device**

**Actors:** SA, DA. **Setup:** Test stop; inactive, on-leave and roster-only drivers.

1. Assign then clear driver/date.
2. Inspect normalization.
3. Try roster-only/inactive driver assignment and cross-store driver payload.

**Expected:** Pending/scheduled states stay consistent; unlinked driver warning is explicit; invalid scope rejected; no misleading promise that roster-only driver can log in.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** clear-driver; clear-date; roster-only; inactive; on-leave; cross-store.

### FUL-011 — Driver contact and proof privacy

**P0 · device+api**

**Actors:** DA, DA2, G. **Setup:** Each driver has distinct assigned fixture customer and proof photo.

1. Read own contact helper and phone link.
2. Request unrelated customer/order/unit/photo by ID and storage path.

**Expected:** Assigned stop has usable minimum contact; unrelated contacts, staff notes and proof objects inaccessible through normal API/storage.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

### FUL-012 — Repeat and concurrent completion

**P0 · integration**

**Actors:** DA, SA. **Setup:** En-route delivery with independent actor sessions.

1. Double-click completion.
2. Race driver completion with staff override.
3. Reopen all related state.

**Expected:** One completed lifecycle, one billing start, no double unit updates or duplicate completion email.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** double-click; driver-vs-override.

### FUL-013 — Board tabs and detail context

**P1 · device**

**Actors:** SA, DA. **Setup:** Pending/scheduled/en-route/completed outbound, return and store-collection stops.

1. Use status/kind/date filters.
2. Open row detail.
3. Reload selected stop.
4. Compare driver and staff layouts.

**Expected:** Rows classified by leg type plus requires_driver; completed context and proof remain usable; correct order opens; no roster tab for driver.

**Verify:** Compare stop, order, units, recurring charge, driver active_delivery_id and proof storage from independent staff/driver contexts after reload.

**Separate variants:** status; kind; completed; selected-deep-link.

## Billing and returns

Sources: [src/screens/billing/derive.ts](../../src/screens/billing/derive.ts), [src/screens/billing/useBillingActions.ts](../../src/screens/billing/useBillingActions.ts), [src/screens/orders/useSchedulePickup.ts](../../src/screens/orders/useSchedulePickup.ts), [src/screens/orders/CloseOutControls.tsx](../../src/screens/orders/CloseOutControls.tsx), [supabase/migrations/031_return_lifecycle.sql](../../supabase/migrations/031_return_lifecycle.sql), [supabase/migrations/038_cancel_and_close_out.sql](../../supabase/migrations/038_cancel_and_close_out.sql), [supabase/migrations/051_return_units_to_inventory.sql](../../supabase/migrations/051_return_units_to_inventory.sql), [supabase/migrations/060_sync_recorded_payment_state.sql](../../supabase/migrations/060_sync_recorded_payment_state.sql).

### BILL-001 — Billing starts at fulfillment

**P0 · device · demo pack**

**Actors:** SA, DA. **Setup:** Approved rental with paused charge.

1. Inspect before handoff.
2. Complete outbound delivery or store collection.
3. Reopen Billing.

**Expected:** Paused before fulfillment; current with billing_start afterward; correct monthly amount; no premature overdue flag.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** delivery; store-collection.

### BILL-002 — Record one offline monthly payment

**P0 · device · demo pack**

**Actors:** SA, SA2. **Setup:** Active overdue rental, known due date and unpaid badge; only simulated money in test target.

1. Record payment once.
2. Reopen charge and order in second session.

**Expected:** Last paid stored, next due advances exactly one calendar month, overdue clears appropriately and order badge is paid; no processor call.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

### BILL-003 — Payment date/state guards and repeat semantics

**P0 · device**

**Actors:** SA. **Setup:** Paused, ended and active test charges.

1. Attempt record on paused/ended and with future date.
2. Record valid backdated payment.
3. Record second intentional payment.

**Expected:** Invalid cases leave dates unchanged; valid date stored; each intentional repeat advances another month. Do not retry blindly after uncertain receipt.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** paused; ended; future; backdated; deliberate-second-payment.

### BILL-004 — Payment double-click and uncertain outcome

**P0 · isolated-browser**

**Actors:** SA, SA2. **Setup:** Active charge at known next_due_date in isolated target.

1. Double-click Record payment.
2. Simulate commit with lost response.
3. Race two sessions recording same receipt.

**Expected:** Single intended payment must advance once; duplicate advancement is a defect; inspect persisted date before retrying.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** double-click; response-lost; concurrent-same-receipt.

### BILL-005 — Due dates, overdue sweep and summaries

**P1 · device**

**Actors:** SA, A. **Setup:** Charges due yesterday, today, +7,+8 days, missing due, paused and ended.

1. Set/clear due date.
2. Visit Dashboard to run mark_overdue.
3. Inspect Billing tabs/totals and order badge.

**Expected:** Calendar-day categories and totals match fixture rows; ended/paused excluded from active overdue; forward date clears applicable charge warning.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** yesterday; today; plus-7; plus-8; no-date; ended; paused.

**Existing evidence / gap:** tests/unit/billing-derive.test.ts covers category and summary helpers, not DB sweep.

### BILL-006 — Month-end, leap-year and timezone

**P1 · integration**

**Actors:** SA. **Setup:** Controlled test clock and due dates.

1. Record payment from Jan 31 and leap-year Feb 29.
2. Render dates near midnight and DST.
3. Save appointment and reread.

**Expected:** PostgreSQL calendar-month dates and UI agree; date-only values never shift a day; appointment time stays intended New York time.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** Jan-31; Feb-29; midnight; DST-change.

### BILL-007 — Rate edit and deposit accounting

**P1 · device**

**Actors:** SA. **Setup:** Active rental with held deposit.

1. Edit monthly rate and deposit field.
2. Inspect recurring charge, held deposit rows and summary.
3. Cancel or close order.

**Expected:** Rate syncs once; recorded deposit balance matches declared behavior; close/cancel does not silently refund or forfeit funds; discrepancies are explicit.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

### RET-001 — Return pickup lifecycle

**P0 · device · demo pack**

**Actors:** SA, DA, SA2. **Setup:** Active delivered rental with rented units and current charge.

1. Schedule pickup.
2. Set return date/time/driver.
3. Driver starts and completes with photo.
4. Reload all screens.

**Expected:** One driver-required RETURN PICKUP; order pickup_scheduled then closed; charge ended and lines inactive; returned units immediately available under migration 051.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

### RET-002 — Repeat scheduling and cancelled return leg

**P1 · integration**

**Actors:** SA, SA2. **Setup:** Eligible active rental; pending pickup and separately cancelled-pickup variants.

1. Click Schedule pickup twice/in two sessions.
2. Try again when existing leg is cancelled.

**Expected:** No duplicate live return legs; cancelled prior leg permits one new booking; billing remains active until actual return.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** double-click; two-sessions; cancelled-prior.

### RET-003 — Return due versus payment due

**P1 · device**

**Actors:** SA. **Setup:** Distinct charge due date and scheduled return date.

1. Change payment due then return appointment independently.
2. Inspect Billing payment and equipment return badges.

**Expected:** Changing one date does not alter the other; late return and overdue money are separately identified; no billing end before completion.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Existing evidence / gap:** tests/unit/billing-derive.test.ts covers return/date helper categories only.

### RET-004 — Cancel before handoff

**P0 · device · demo pack**

**Actors:** SA. **Setup:** Approved/scheduled rental with reserved units, open stop, paused charge and deposit.

1. Cancel with reason.
2. Inspect audit, Cancelled tab and all related state.
3. Repeat on same order.

**Expected:** Reserved stock restored once, active lines released, open legs cancelled, charge ended, reason/actor/time recorded; deposit unchanged.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

### RET-005 — Close out after equipment is out

**P0 · device**

**Actors:** SA. **Setup:** Active or overdue rental with open return pickup.

1. Close out with reason.
2. Reload order, units, legs, charge and deposit.

**Expected:** Order closed, billing ended, open pickup cancelled, lines inactive and stock immediately available per migration 051; deposit untouched.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

### RET-006 — Close/cancel invalid-state guards

**P0 · device+api**

**Actors:** SA, DA. **Setup:** Requested, active, closed and cancelled fixtures.

1. Try blank reason.
2. Cancel active order.
3. Close unfulfilled order.
4. Driver calls close/cancel APIs.
5. Repeat final action.

**Expected:** Wrong operation/state/role rejected without mutation; no accidental stock restoration or billing reactivation.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** blank-reason; cancel-active; close-unfulfilled; driver; repeated-final-action.

### RET-007 — Return versus payment/edit races

**P1 · integration**

**Actors:** SA, SA2, DA. **Setup:** Active rental with return en route and one open payment/edit form.

1. Race return completion with record payment or rental edit.
2. Inspect charge/order/units afterward.

**Expected:** Ended rental cannot be reactivated by stale write; stock restored once; outcome explains whether payment accepted or rejected.

**Verify:** Inspect persisted charge/payment dates, order status, line activity, units, deposit and return legs; compare Billing totals and another staff session after every mutation.

**Separate variants:** return-vs-payment; return-vs-edit; cancel-vs-start.

## People, drivers and private notes

Sources: [src/screens/Customers.tsx](../../src/screens/Customers.tsx), [src/screens/StaffDirectory.tsx](../../src/screens/StaffDirectory.tsx), [src/screens/StaffDetail.tsx](../../src/screens/StaffDetail.tsx), [src/screens/Drivers.tsx](../../src/screens/Drivers.tsx), [supabase/migrations/032_driver_rls.sql](../../supabase/migrations/032_driver_rls.sql), [supabase/migrations/041_staff_profile_notes.sql](../../supabase/migrations/041_staff_profile_notes.sql), [supabase/migrations/059_location_user_accounts.sql](../../supabase/migrations/059_location_user_accounts.sql).

### PEOPLE-001 — Customer directory and promised history

**P1 · device**

**Actors:** SA. **Setup:** Two A customers with orders and one B customer.

1. Open Customers.
2. Try displayed customer-card action.
3. Open same customer through order detail.

**Expected:** Directory scopes correctly and displays safe contact details; advertised click/history behavior works or is logged as known capability gap.

**Verify:** Read back profile/driver links and notes under each actual role; test hosted sign-in separately from roster/account creation.

**Existing evidence / gap:** Known source-level gap: Customers.tsx renders non-clickable cards despite history copy.

### PEOPLE-002 — Driver roster, login link and duplicate link

**P0 · device · demo pack**

**Actors:** SA, A, DA. **Setup:** Roster-only driver and active driver-role profile in A.

1. Add/edit roster entry.
2. Link login.
3. Attempt link already-linked/non-driver/B profile.
4. Log in as driver and assign stop.

**Expected:** Correct one-to-one scoped link; invalid/duplicate links reject; no-login warning clears only after usable identity linked.

**Verify:** Read back profile/driver links and notes under each actual role; test hosted sign-in separately from roster/account creation.

### PEOPLE-003 — Staff profile edits and driver conversion

**P1 · device+integration**

**Actors:** A. **Setup:** Disposable staff profile with and without driver record.

1. Edit name/phone.
2. Change role to driver.
3. Force profile save failure after driver insert in isolated run.
4. Reopen.

**Expected:** One linked roster record at proper store; failed profile update does not strand new driver; role and available controls agree.

**Verify:** Read back profile/driver links and notes under each actual role; test hosted sign-in separately from roster/account creation.

### PEOPLE-004 — Admin self-lockout controls

**P1 · device**

**Actors:** A. **Setup:** Active demo admin; separate recovery admin exists.

1. Inspect own profile role/status controls.
2. Attempt ordinary self-demotion through UI.

**Expected:** Self role/status protected in UI; no accidental loss of only active admin. Do not mutate the live demo owner for this test.

**Verify:** Read back profile/driver links and notes under each actual role; test hosted sign-in separately from roster/account creation.

### PEOPLE-005 — Private staff notes and hostile text

**P0 · device+api**

**Actors:** A, SA, DA, G. **Setup:** Disposable profile and note containing HTML-like text and multiline Unicode.

1. Add and reload note as admin.
2. Attempt note table read with lower-privilege tokens.
3. Render note.

**Expected:** Text escaped with correct author/time; admin-only notes never exposed to staff/driver/public.

**Verify:** Read back profile/driver links and notes under each actual role; test hosted sign-in separately from roster/account creation.

### PEOPLE-006 — Roster status and account status are distinct

**P1 · device**

**Actors:** A, SA, DA. **Setup:** Linked driver profile and roster entry.

1. Toggle roster on_leave/inactive without changing login.
2. Separately deactivate profile.
3. Inspect assignment and stale driver session.

**Expected:** Operational availability and login access have explicit separate effects; inactive identity cannot act with old session.

**Verify:** Read back profile/driver links and notes under each actual role; test hosted sign-in separately from roster/account creation.

**Separate variants:** roster-on-leave; roster-inactive; account-inactive.

## Location onboarding and settings

Sources: [src/screens/LocationOnboarding.tsx](../../src/screens/LocationOnboarding.tsx), [src/lib/locationOnboarding.ts](../../src/lib/locationOnboarding.ts), [src/screens/LocationDetail.tsx](../../src/screens/LocationDetail.tsx), [src/components/BusinessContact.tsx](../../src/components/BusinessContact.tsx), [supabase/migrations/062_guided_location_onboarding.sql](../../supabase/migrations/062_guided_location_onboarding.sql), [tests/sql/location-onboarding.sql](../../tests/sql/location-onboarding.sql).

### LOC-001 — Onboard full active location

**P0 · integration · demo pack**

**Actors:** A, SN, DN. **Setup:** Isolated integrated target with migration 062, existing catalog S/B, authorized test usernames.

1. Complete new business/contact/address/services, S qty 3, B qty 12 and local price.
2. Add staff, linked driver and roster-only driver.
3. Review, explicitly activate and Create once.

**Expected:** One coherent transaction: business/contact/location, three actual tagged units, bulk quantity 12, local prices, accounts and linked drivers; no global admin or invitation email.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Existing evidence / gap:** tests/sql/location-onboarding.sql verifies DB core with Auth stand-ins; hosted sign-in and browser steps remain untested.

### LOC-002 — Existing business, optional steps and inactive default

**P1 · device**

**Actors:** A. **Setup:** Existing business with multiple locations.

1. Select existing business.
2. Skip stock/team.
3. Create without activation.
4. Reopen old and new location.

**Expected:** Existing business/contact unchanged; new location inactive; absent from active header/checkout; zero team or stock is allowed.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Existing evidence / gap:** tests/unit/location-onboarding.test.ts and tests/sql/location-onboarding.sql cover parts of this flow.

### LOC-003 — Wizard required fields and navigation

**P1 · device**

**Actors:** A. **Setup:** Unsaved isolated draft.

1. Try skipping Business/Location validation.
2. Edit via Review links.
3. Add/remove stock and team.
4. Leave with dirty draft then cancel.

**Expected:** Errors focus correct step; values retained across steps; review mirrors draft; dirty-leave warning works; no partial DB write before Create.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** empty-business; empty-location; review-edit; add-remove; leave-cancel.

### LOC-004 — Stock bounds, tags and offering eligibility

**P1 · integration**

**Actors:** A. **Setup:** Serialized S, bulk B, inactive product and zero-stock item.

1. Try negative/fractional/over-500 stock, blank override and negative price.
2. Create valid qty 0/1/500 in separate isolated variants.

**Expected:** Invalid stock rejects atomically; generated serialized tags unique with blank manufacturer serials; bulk has no units; zero stock not published; local price preserves catalog.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** negative; fractional; 501; zero; one; 500; blank-override; negative-price.

**Existing evidence / gap:** tests/unit/location-onboarding.test.ts and tests/sql/location-onboarding.sql cover validation and stock core.

### LOC-005 — Team credentials and role boundaries

**P1 · integration**

**Actors:** A. **Setup:** Disposable team entries; no real passwords in evidence.

1. Try reserved/malformed/case-duplicate usernames, invalid email, short or over-72-byte password.
2. Try role admin.
3. Try >20 members.
4. Correct and submit.

**Expected:** Invalid entries reject without partial identity creation; owner/team access is staff, not global admin; credentials absent from receipt/logs.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** reserved; malformed; case-duplicate; invalid-email; password-short; password-UTF8-bytes; admin-role; over-20-team.

**Existing evidence / gap:** tests/unit/location-onboarding.test.ts covers selected boundaries; SQL tests cover admin-role rejection and hashed passwords.

### LOC-006 — Onboarding retry, double-click and late failure

**P0 · integration · demo pack**

**Actors:** A. **Setup:** Isolated browser and DB; ability to fail after identity insertion.

1. Double-click Create.
2. Drop committed response and use Check and finish setup with same UUID.
3. Inject late driver failure on separate request.

**Expected:** Retry returns identical receipt without duplicate stock/users; uncertain draft locked for same-ID recovery; late failure rolls back business, contacts, location, stock and Auth identities.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** double-click; response-lost-same-UUID; late-failure.

**Existing evidence / gap:** tests/sql/location-onboarding.sql covers identical receipt and late rollback, not actual browser transport.

### LOC-007 — Missing RPC and expired admin session

**P1 · integration**

**Actors:** A. **Setup:** Isolated target with 062 absent or admin session expired.

1. Open wizard.
2. Submit valid draft.
3. Restore endpoint/auth and recover.

**Expected:** Clear migration/access error, no false success or partial creation; no blind full migration replay; saved/retried draft outcome understood.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** missing-RPC; expired-session.

### LOC-008 — Onboarding permissions and owner-contact privacy

**P0 · api**

**Actors:** G, SA, DA, X. **Setup:** Normal-token API harness and known receipt/contact IDs.

1. Call onboarding as each forbidden actor.
2. Read owner contact/receipt.
3. Attempt write.

**Expected:** Anonymous, staff, driver, inactive admin and customer cannot onboard or read private contacts/receipts.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** anonymous; staff; driver; inactive-admin; customer.

**Existing evidence / gap:** tests/sql/location-onboarding.sql covers anonymous grant, staff and inactive-admin; not driver/customer hosted sessions.

### LOC-009 — Location edit does not rename business

**P1 · device**

**Actors:** A. **Setup:** Two locations under one business; saved original settings.

1. Rename one location and edit address/phone/instructions/services.
2. Reload sibling and public pickup details.

**Expected:** Location changes persist locally; parent/sibling name unchanged; checkout and future appointment details match intended store; completed history coherent.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

### LOC-010 — Business contact edit shared and private

**P1 · device+api**

**Actors:** A, SA. **Setup:** Two locations under same business.

1. Edit Business contact from first location.
2. Reopen sibling.
3. Try public/staff contact reads.

**Expected:** Owner contact shared across business locations and remains admin-only; public store phone is independent.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

### LOC-011 — Legacy location Users creation versus roster link

**P1 · device**

**Actors:** A, SN, DN. **Setup:** Isolated legacy Users editor at existing location.

1. Add staff and driver accounts.
2. Sign in.
3. Inspect roster and assignment.
4. Link driver explicitly if missing.

**Expected:** Account role/store correct; distinguish Auth account from driver record; no claim driver is dispatch-ready until link verified.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

### LOC-012 — Activation and pickup-only/partner configuration

**P1 · device**

**Actors:** A, G. **Setup:** Inactive test location with positive stock.

1. Activate/deactivate and change pickup-only versus pickup+delivery.
2. Toggle owned/partner relationship.
3. Reopen checkout.

**Expected:** Active stocked pickup visible only when allowed; pickup-only excluded from delivery routing; partner status alone does not disable delivery.

**Verify:** Read receipt and persisted business/contact/location/stock/unit/profile/driver rows as admin, then sign in with created test identities and check storefront eligibility.

**Separate variants:** activate; deactivate; pickup-only; pickup-and-delivery; partner.

## Realtime, notifications and email

Sources: [src/components/RealtimeSync.tsx](../../src/components/RealtimeSync.tsx), [src/components/NotificationsBell.tsx](../../src/components/NotificationsBell.tsx), [src/lib/useRealtimeInvalidateMany.ts](../../src/lib/useRealtimeInvalidateMany.ts), [src/lib/customerEmails.ts](../../src/lib/customerEmails.ts), [supabase/migrations/034_notification_fanout.sql](../../supabase/migrations/034_notification_fanout.sql), [supabase/migrations/047_customer_email_lifecycle.sql](../../supabase/migrations/047_customer_email_lifecycle.sql), [supabase/migrations/050_customer_email_content.sql](../../supabase/migrations/050_customer_email_content.sql).

### SYNC-001 — Guest-to-staff request and count propagation

**P0 · device · demo pack**

**Actors:** G, SA, SA2, A. **Setup:** All sessions scoped to A except one B observer; baseline counts recorded.

1. Submit guest test request.
2. Observe Requests, dashboard and grouped sidebar counts without reload.

**Expected:** New request appears on authorized screens; no duplicate count or B private details; record realtime and 15-second request polling fallback latency.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

### SYNC-002 — Lifecycle propagation across open screens

**P0 · device · demo pack**

**Actors:** SA, SA2, DA. **Setup:** Open same fixture in Orders detail, Inventory, Billing, Dashboard and dispatch.

1. Approve, assign, complete and return with actor transitions.
2. Keep observers open without navigation.

**Expected:** List and open detail, stock, billing and badges update coherently; stale open detail is recorded even if list refetches.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

**Separate variants:** approve; assign; complete; return; payment-recorded; customer-edited; stock-added.

### SYNC-003 — Notifications unread, ownership and read failure

**P1 · device+api**

**Actors:** SA, DA, DA2. **Setup:** More unread notifications than bell list limit; separate user inboxes.

1. Inspect unread count.
2. Open and mark read.
3. Reopen in second same-user session.
4. Force read update failure.
5. Try other-user notification IDs.

**Expected:** Exact unread total independent of list limit; read changes persist across sessions; failures visible; no other-user read/write.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

**Separate variants:** unread-count; mark-read; same-user-tabs; update-failure; foreign-ID.

### SYNC-004 — Old-driver notification on reassignment

**P0 · device**

**Actors:** SA, DA, DA2. **Setup:** DA has assigned A stop.

1. Reassign to DA2.
2. Observe notifications and queues in both sessions.

**Expected:** Both intended assignment/revocation paths update; old driver removal works even when delivery realtime event no longer passes its RLS.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

### SYNC-005 — Reconnect and background fallback

**P1 · isolated-browser**

**Actors:** SA, DA. **Setup:** Isolated network controls; foreground and background pages.

1. Disconnect realtime.
2. Mutate elsewhere.
3. Reconnect or focus page.
4. Wait documented polling interval and inspect.

**Expected:** Screen eventually converges; no duplicate channels/notifications; record 15s Requests, 30s Dashboard/Billing and 60s profile refresh behavior separately.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

**Separate variants:** socket-down; tab-background; reconnect.

### MAIL-001 — Customer status and appointment emails

**P0 · integration**

**Actors:** G, SA, DA. **Setup:** Controlled reachable test inbox; isolated provider or approved test recipient only.

1. Create request.
2. Approve, schedule/reschedule, fulfill and return/cancel.
3. Inspect outbox and actual messages.

**Expected:** Correct order number, items, prices, payment rail, store/address/time and lifecycle wording; in-store collection never described as return; no duplicate event mail.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

**Separate variants:** request; approval; schedule; reschedule; collection; delivery; return; cancel.

### MAIL-002 — Provider outage, missing email and retry dedupe

**P1 · integration**

**Actors:** SA. **Setup:** Isolated email transport; no external recipients except controlled inbox.

1. Fail transport during action.
2. Repeat with missing/invalid email.
3. Restore transport and flush twice.

**Expected:** Business action stays committed; pending outbox can retry; no duplicate delivery for same event; invalid recipient skipped safely.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

**Separate variants:** provider-failure; missing-email; invalid-email; repeated-flush.

### MAIL-003 — Scheduled day-of reminders without open browser

**P1 · integration**

**Actors:** A. **Setup:** Isolated cron/provider target and controlled New York clock.

1. Schedule fixture stop today.
2. Close staff pages.
3. Run/observe configured reminder job twice.

**Expected:** One appropriate day-of reminder per event; correct local date/window; cron/provider evidence captured; no promise of webhook-driven recurring billing.

**Verify:** Keep independent roles open; timestamp mutation, UI arrival and fallback; inspect outbox dedupe keys and controlled inbox/provider evidence separately from business transaction.

## Resilience, usability and demo readiness

Sources: [playwright.config.ts](../../playwright.config.ts), [src/app/error.tsx](../../src/app/error.tsx), [src/app/not-found.tsx](../../src/app/not-found.tsx), [src/app/globals.css](../../src/app/globals.css), [src/components/Layout.tsx](../../src/components/Layout.tsx), [src/screens/Delivery.tsx](../../src/screens/Delivery.tsx).

### UX-001 — Desktop, narrow staff and mobile driver layouts

**P0 · device · demo pack**

**Actors:** G, SA, DA, A. **Setup:** Viewports 1440x900, 768x1024, 390x844 and 360x800.

1. Run cart, order detail, dispatch controls, proof selection and onboarding review.
2. Open sidebar/tabs and scroll.

**Expected:** Primary action reachable without overlapping sticky UI or horizontal clipping; touch and keyboard usable; no control hidden below unscrollable panel.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

**Separate variants:** desktop; tablet; mobile-390; mobile-360.

### UX-002 — Keyboard, focus and screen labels

**P1 · device**

**Actors:** G, SA, A. **Setup:** Fresh pages, keyboard only.

1. Tab through cart and order panel.
2. Activate card by Enter/Space.
3. Escape and close.
4. Follow onboarding validation.

**Expected:** Visible focus and labeled inputs; intended focus trap/restore in panels; nested action does not trigger parent; no keyboard dead end.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

**Separate variants:** cart; order-panel; nested-action; onboarding.

### UX-003 — Slow, empty and failed reads

**P1 · isolated-browser**

**Actors:** G, SA, DA. **Setup:** Isolated read failures and empty store.

1. Delay or fail each major screen query.
2. Restore service and retry/navigation.

**Expected:** Useful loading/empty/error state; no stale action on undefined data, frozen spinner, blank exception screen or false zero KPIs.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

**Separate variants:** requests; orders; inventory; billing; dispatch; locations; staff; catalog.

### UX-004 — Mutation denied or network failure preserves work

**P1 · isolated-browser**

**Actors:** SA, A. **Setup:** Isolated failure injection before commit.

1. Deny/fail save in inventory, dispatch, rental edit and onboarding.
2. Correct failure and retry after checking state.

**Expected:** Entered values survive; message clear; busy state releases; no partial data or duplicate save; controls re-enable.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

**Separate variants:** inventory-save; dispatch-save; rental-edit; onboarding.

### UX-005 — Hostile text and unusual characters

**P1 · integration**

**Actors:** G, SA, A. **Setup:** Harmless HTML-like strings, quotes, apostrophes, accented names and long text; synthetic contacts only.

1. Submit notes/customer/product text.
2. Render in UI and controlled email.
3. Search quoted name.

**Expected:** Text escaped rather than executed; Unicode and whitespace handled; bounded inputs and useful overflow; no broken query or data loss.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

**Separate variants:** customer-name; notes; product-name; email-body.

### DEMO-001 — Live endpoint and deployed-version preflight

**P0 · device · demo pack**

**Actors:** G, A. **Setup:** https://cottagesurgical.com; expected demo build/branch recorded; configured backend only.

1. Open HTTPS homepage/admin-login and one valid product.
2. Check required migration/RPC availability read-only.
3. Compare deployed navigation to checkout feature set.

**Expected:** Live service reachable without TLS/browser errors; identify actual deployed feature differences before mutation scenarios; no claims based only on local build.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

### DEMO-002 — End-to-end rehearsal and preserved demo dataset

**P0 · device · demo pack**

**Actors:** G, A, SA, DA. **Setup:** Dedicated named demo fixtures, controlled inbox, tested date and appointment.

1. Run the ordered demo journeys in README.
2. Record result/evidence per variant.
3. Prepare separate untouched demo records and verify IDs.
4. Stop destructive retests on rehearsal records.

**Expected:** Every in-scope demo journey passes on current deployment, no open P0, no real customer disruption; known unsupported features explicitly excluded or fixed and retested.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

### DEMO-003 — Evidence, cleanup and repeatability

**P0 · device · demo pack**

**Actors:** A. **Setup:** Run manifest with every created fixture ID and original setting.

1. Reopen all mutated records for final verification.
2. Restore module/store settings and clean disposable records only where lifecycle permits.
3. Run demo smoke again on reserved fixtures.

**Expected:** No unresolved uncertain commits or stale test settings; intended demo stock/accounts remain usable; cleanup does not erase financial or workflow history blindly.

**Verify:** Record browser/viewport, console exception, exact route/role, timing and screenshot with private data redacted; rerun affected scenario after fix.

