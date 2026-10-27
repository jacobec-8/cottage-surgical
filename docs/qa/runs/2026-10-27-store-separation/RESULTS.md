# Store separation — on-screen retest results (2026-10-27)

All runs were on nu-yin through `bc screen test … --fresh-browser --record`, against production after migrations 100 and 101 and PRs #38–#43.
Evidence (checkpoint PNGs + recording.webm) is in the session scratchpad under `screen/artifacts/<run>/`; nu-yin keeps the recordings for 3 days (`bc screen recordings`).

| Flow | Store(s) | Result on screen | Run |
|---|---|---|---|
| Login page names no business | — | Neutral "Pharmacy Portal" | sep-screen |
| Staff cannot edit the owner's template product | Greenport | No Edit item | sep-screen |
| Staff-created product stays in its store | Montauk → East Hampton | Ice pack invisible at East Hampton | sep-product-* |
| Website pickup → approve → Mark picked up | Montauk | #1276 active, stop completed | sep-customer-pickup, sep-staff-approve, sep-handover |
| Website delivery to 11954 routes to Montauk at its price | Montauk | #1277 at $69, customer belongs to Montauk | sep-delivery-customer |
| Approve + dispatch to Driver 1 | Montauk | Scheduled, Saved | sep-delivery-dispatch2 |
| Driver Start → Couldn't deliver | Montauk | Stop off route; alert titled with the store; only that store's staff, owner and admins alerted | sep-driver-start, sep-driver-miss2 |
| Store sees alert, reschedules | Montauk | Bell shows the alert; "Missed Oct 27" card rescheduled | sep-reschedule |
| Driver completes with photo | Montauk | #1277 active, "Delivery Completed · 1 photo" | sep-driver-complete |
| Store page: delivery ZIPs + reply-to | Montauk | Saved; ZIP 11977 then quoted Montauk's $69 | sep-store-page5, sep-cart-zip |
| Header shows the store's reply-to (PR #39) | Montauk | cos@eightmind.ai in header | sep-header |
| Shipment unit with a tag another store uses | Pharmacy 2 | P1-RW-3 saved at Pharmacy 2; Montauk's untouched | sep-p2-unit |
| Phone order via New Order (per-store numbering) | Pharmacy 2 | "Order #1 created" | sep-p2-phone2 |
| Counter close-out | Montauk | #1276 closed "Returned at the counter" | sep-counter-p1 |
| Return pickup | Montauk | #1277 pickup scheduled at Montauk | sep-counter-pickup |
| Record payment | Montauk | "Payment recorded — next due 2026-11-27" | sep-p1-pay |
| Phone cancel | Pharmacy 2 | #1 cancelled, unit back to available | sep-p2-cancel |
| Billing shows only the store's own rentals | Pharmacy 2 | Awaiting delivery 1, nothing from Montauk | sep-counter-p2 |
| Retail switch per store (owner) | Montauk | Off → On → Off | sep-retail-on, sep-retail-off5 |
| Purchase to a ZIP whose store sells nothing online | Pharmacy 2 area | Refused (migration 101 gives the right reason) | sep-retail-p2zip3 |
| Purchase to Montauk with retail on | Montauk | Stripe checkout $19.99 (not paid; #1278 cancelled) | sep-retail-p1zip |
| Owner sets module switches per store (PR #42, #43) | Montauk vs Pharmacy 2 | Billing locked at Montauk only; tile and nav hidden there; Pharmacy 2 kept it; unlocked | sep-mod2-*, sep-mod3-* |
| Onboard a branch with delivery ZIPs | Pharmacy 5 | Empty ZIPs refused with message; created closed with 11935, 11952 and its own module switches | sep-onboard, sep-onboard2 |
| Restock at one store doesn't take another's customers | Montauk / Pharmacy 2 | 11954 → $69 (Montauk), 11957 → $75 (Pharmacy 2) after Pharmacy 2 restocked | sep-cart2-* |

## Bugs found on screen and fixed today

- PR #39: header showed the business email, not the store's reply-to.
- PR #40: a website request's confirmation email waited for a staff browser poll (the guest flush became staff-only in 100).
- PR #41 + migration 101: a purchase refused because the area's store sells nothing online said "Delivery is not available".
- PR #42: owners couldn't open Staff Access although 100 made the switches theirs per store; the page said "Your staff account".
- PR #43: the dashboard showed tiles for modules locked at the store.

## State after the run

QA-DEMO Pharmacies 1–5 are closed and have retail off. Montauk's ZIPs and reply-to are restored. QA orders #1271, #1272, #1274, #1277, #1278 and #1301 were cancelled or closed with the app's own cancel/close functions. The QA-SEP ice pack is inactive.
`verify-three-location.py` 167/167; `check_store_separation.py` 0 failures.
