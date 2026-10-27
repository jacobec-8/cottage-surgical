# Store separation — fix and retest plan (2026-10-27)

**Requirement (user, verbatim intent):** one owner owns all the pharmacies. No pharmacy may see,
or be affected by, any other pharmacy. Only the owner sees across them. Everything a pharmacy does
(products, prices, stock, customers, orders, deliveries, alerts, emails, settings, numbering) belongs
to that pharmacy.

**Lens for this reread:** every test from 2026-10-26 and 2026-10-27 is classified as
- **KEEP** — still valid as written; rerun.
- **REWRITE** — the test asserted shared/blended behaviour as correct; rewrite to the requirement, then run.
- **NEW** — not covered before; add.

## Tests that certified the blending (REWRITE)

| Test | What it asserted | Rewrite to |
|---|---|---|
| SCENARIOS TEN-007 | "shared catalog edits are visibly global" | Store A's product edits are invisible to store B; only the owner edits the template |
| verify-three-location.py §086 routing (lines ~292–299) | delivery goes to the numerically nearest ZIP | delivery goes only to a stocked store whose delivery area lists the ZIP; none → refused |
| Flow 1 (2026-10-27) | (exposed it) | rerun end to end: open cart stays at its store; new/restocked store takes nothing outside its area; staff cannot rename the shared product |
| "Add from catalog" (PR #22) | stores attach the shared product row | a store gets its own store product (template copy); edits stay in the store |
| Retail switch (094/095) | one switch for the business | per store; owner/admin set it per store |
| Stores overview / dashboard tiles (093, 013) | three definitions of "open rental" | one definition everywhere |
| Requests stock counts | product-wide total across stores | that store's count |
| Staff module switches (AUTH-009/010) | one global switch set | per store |
| Customer email branding (083/084/099) | business name and reply-to | the store's name, phone, reply-to |
| Order numbers in all scripts | one global sequence (#1301 at a new store) | per-store numbering; scripts look orders up by id or (store, number) |

## KEEP (rerun unchanged)
Out-of-stock blocking + hold while paying (088) · three customers / two in stock (090) · staff
retire/restore while a cart is open (089, PR #20) · owner team logins (087) · onboarding of a store,
staff, driver (076, PR #25/#27/#34) · pickup order → approve → Mark picked up · dispatch → driver
start → complete + photo · Couldn't deliver + Late badge (097) · counter cancel, phone cancel,
counter return, return pickup, record payment (busy day 1–20) · cancellation wording (098) ·
remove-product confirmation (PR #36) · exact prices (PR #33) · product page after retail on (PR #31) ·
2026-10-26 BUG-001…011, 3LOC-001…005, business-isolation link checks (079) · email SQL suite.

## NEW
- Schema check (CI): every table is store-owned (`location_id NOT NULL` + store rule), a child of a
  store-owned table via FK with the parent-delegating rule, or on the explicit owner/platform list;
  no unique index on store data without `location_id`; no rule-bypassing function writes without a
  store check.
- Cross-store behaviour check (CI): every staff action at store A leaves every row store B can see
  unchanged.
- Each item A1–A5, B6–B8, C9–C12, D13–D17, E18–E19 from the 2026-10-27 audit gets a failing-first check.
- Reviewer findings that are store-level: missed-stop alert to the store (#4), alerts name the store and
  stop going to moved staff (#5), driver home change only releases stops at stores no longer served (#6),
  replies go to the store (#7), one definition for owner totals (#8), pickup-only stores can create orders (#1).
