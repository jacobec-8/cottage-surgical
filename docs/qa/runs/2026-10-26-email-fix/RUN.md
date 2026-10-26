# Customer email fixes and verification — October 26, 2026

Migrations **070–073 are deployed** to the configured live Cottage Surgical
service. These are targeted database changes; no older migrations or seed files
were replayed. Source branch: `fix/customer-email-integrity`, based on `cc4ba92`.

| Finding | Fix | Verification |
| --- | --- | --- |
| EMAIL-001 | Scope outbox reads to the parent order's store. | Live admin/own-store staff positive; foreign staff/driver/anonymous negative. Disposable SQL tests also verify both stores' positive access and inactive staff rejection. |
| EMAIL-002 | Defer staff confirmation until transaction commit with final equipment/rate and truthful allocation copy. | Live scheduled and unscheduled orders 124–126 include the kit, quantity and $140. SQL tests cover rollback, unallocated wording and HTML escaping. |
| EMAIL-003 | Atomically journal an accepted offline monthly payment and queue its receipt. | Live simultaneous retries on 124 accept one payment, one journal entry and one email. Receipt contains amount, paid date, offline method and next due. Foreign staff cannot read it. SQL tests cover concurrent retries, rollback, another intentional period and month end. |
| EMAIL-004 | Add payment and expected-return reminders at 3 days before, due today and 7 days overdue; recheck stale mail before dispatch. | All six stages pass controlled-clock SQL tests, including DST, closure, payment and extension. Normal live cron sent the four due-soon/due-today messages; all reached COS. **The two overdue inbox checks remain pending because the daily quota was reached.** |
| EMAIL-005 | Notify on address-only appointment corrections; ignore unchanged saves and completed/cancelled stops. | Live order 124's changed address produces a corrected email, the identical save produces none. SQL also covers correcting back to the original address. |
| Quota recovery | Keep quota/rate-limited mail pending without spending retries; account-wide backoff. | Real SQL sender tested against fake HTTP for daily/monthly/rate-limit responses, successful recovery and stable idempotency keys. No live quota rejection was deliberately generated. |

Actual delivery: **18/18 messages in the COS Gmail INBOX**, each with one exact
subject/plaintext body match and distinct message IDs. Reads through BC did not
mark mail read. Recipient was exclusively **cos@eightmind.ai**. Three dedicated
synthetic rentals used the pre-existing QA kit at Store A and real staff/driver
RPCs with clearly labeled QA proof. No real Stripe charge/refund occurred.

Checks passed: **57 unit tests**, lint, type checking, production build with
Next's webpack builder, **67 SQL assertions** plus concurrency/rollback tests,
and eight static email renders at 390/800px with no horizontal overflow.
Turbopack could not bind its local worker port under this environment's process
restriction, including an escalated retry; webpack compiled all routes. Static
Chromium rendering does not certify every email client.

Resend's read-only `GET /usage` returned **116/100 daily**, **116/3000 monthly**,
with the daily reset at **2026-10-27 00:00 UTC / October 26, 8 PM EDT**. The
new transport backoff is initialized until that reset, based on the confirmed
usage; no extra send was used to probe the limit. If the plan is upgraded,
verify the new usage/limit before clearing the transport backoff.

Cleanup: all three rentals (124–126) are closed, all three recurring charges
ended, all five QA units available, product visibility restored, QA driver's
active marker clear. Three cleanup messages were marked skipped in the same
transaction as close-out, so cleanup consumed no further email quota. No QA
mail is pending. Historical QA artifacts and earlier failures are retained.

Local evidence in this run directory includes `deployment.json`,
`journeys.json`, `inbox-initial.json`, `verification-initial.json`,
`provider-usage.json`, `quota-check.json`, and `render-checks.json`.
The privacy rerun is `../2026-10-26-email-pass/email-access-fix-070.json`.
HTML/screenshots are under `artifacts/qa-email-fix/screens/`.

To finish live reminder coverage after quota is available: create a fresh
COS-only synthetic active rental with valid historical start/end and a charge
seven days overdue; observe the normal cron's billing/expected-return emails;
compare actual inbox subject/body and duplicates; then close the fixture and
restore stock. Do not reopen or replay completed fixtures 124–126. All other
full-suite scenarios retain their own historical status; this run does not
certify the entire 430-variant test design or actual Stripe settlement.
