# Enterprise hardening

A form is only as good as the checks and error handling in its code. These
decisions make every save in Cottage Surgical honest about what happened.
Each lists what we chose, why, and what "done" means.

- [form-saves-checklist.md](form-saves-checklist.md) tracks every save.
- [before-after.md](before-after.md) shows the change on screen, before and after.

## Decision 1: saves are real form submits with honest outcomes (2026-11-04)

**Rule.** If staff enter something and it does not save, that must be
obvious. The screen never shows a value the database did not accept without
saying so.

**What we chose.**

- Every save with fields is a form submit through the shared `SaveForm`
  (`src/components/SaveForm.tsx`). Browser tooltip checks are off
  (`noValidate`).
- The Save button is a `SubmitButton`. It locks while saving, so a double
  click or a scanner's double Enter saves once.
- Three outcomes, worded the same everywhere:
  - **Saved.** A green notice, shown only after the database confirmed it.
  - **Not saved.** A plain reason, never raw database text.
  - **Not confirmed.** The connection dropped, so the save may have gone
    through. The message says to reload and check before trying again.
- Once a save is confirmed, nothing after it (closing an editor, reloading a
  list) can show it as failed.
- Updates confirm a row changed. A save blocked by access rules returns no
  error and changes nothing; without the check it would say "Saved".
- One-click actions with no fields (Verify payment, Mark picked up) stay
  plain buttons.

## Decision 2: every form checks its own fields before sending (2026-11-04)

**Rule.** The form's code, not the browser and not only the database,
catches a mistake before anything is sent, and points at the field.

**What we chose.**

- **One shared set of field rules**, `src/lib/fieldRules.ts`: required,
  price, whole number, email, phone, ZIP, state. The same mistake gets the
  same words on every form.
- **Each form's checks** live in `src/lib/formChecks/`, as plain functions
  that return every problem with its field. They reuse each form's existing
  wording and add the checks only the database made before: prices,
  quantities, driver and staff phone and email, deposits and rates, ZIPs.
- **The shared form runs them first.** A flagged field turns red, its message
  sits under it, the list of problems sits beside Save, the cursor goes to
  the first flagged field, and nothing is sent. Editing a field clears its
  mark.
- **Server refusals can name their field** (`FieldRefusal`), so "username
  already taken" lands on the username box.
- **Price and quantity boxes are text fields with a number keypad.** A browser
  number field reports "empty" when someone types "$450", so the check could
  not see what was typed.
- **Forms that run their own submit** (sign-in, checkout, edit rental, return
  address) use `FieldMarks` for the same marking.

**Found and fixed on the way.** The store stock count used to save −3 or
"ten" as 0 without a word. It is now refused on the field.

## Decision 3: failures carry their source, and retries can't duplicate (2026-11-04)

- Every save attempt gets a request ID, sent as `x-request-id`. Postgres reads it (`current_request_id()`) and stamps it on order history and money records.
- Every blocked or refused save is logged to `save_failures` with the ID, user, page, form, field, layer and code, never typed values. Staff see "Ref 3F9A2C" on the error. Only admins read the table.
- Staff orders, storefront requests and both Stripe checkouts go through "once" functions with a save key. A repeat returns the first result. The key claim, the write and the stored result commit in one transaction. A refusal releases the key.
- Migration 118, applied 2026-11-04. Checked by `tests/sql/save-keys-check.py`, which runs in a transaction that always rolls back.

## Done means, for each save

- Pressing Enter in a single-line field saves (New Order is the exception:
  Enter there never places an order).
- Cancel and other buttons inside the form do not save.
- A double click produces one save.
- A bad field is marked, explained and focused, and nothing is sent.
- Success shows "Saved"; a refusal shows "Not saved." with the reason.
- Typecheck, lint and the guard tests pass; the guards run in CI.
