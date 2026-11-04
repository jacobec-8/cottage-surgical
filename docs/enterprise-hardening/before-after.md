# Before and after

Screenshots from nu-yin on 2026-11-04. "Before" is `main` at 497906d.
"After" is this change. Every test used QA records; personal details on
order #1210 are blacked out.

## The product page

| | |
|---|---|
| **Before:** a negative sale price shows the raw database text. | ![](screens/before-01-negative-price.png) |
| **After:** a plain reason. | ![](screens/after-01-negative-price.png) |
| **Before:** a good save closes the form with no confirmation. | ![](screens/before-02-product-saved.png) |
| **After:** "Product saved." | ![](screens/after-02-product-saved.png) |
| **Before:** Save stock changes nothing on screen, saved or not. | ![](screens/before-03-stock-save.png) |
| **After:** Enter submits; a negative override is refused in plain words. | ![](screens/after-03-stock-refused-with-enter.png) |
| **After:** a good stock save is confirmed. | ![](screens/after-04-stock-saved.png) |
| **After:** in-place price editor. | ![](screens/after-05-in-place-price.png) |
| **After:** inventory note added. | ![](screens/after-06-note-added.png) |
| **After:** a unit with no asset tag. | ![](screens/after-07-unit-refused.png) |

## Orders, customers and delivery

| | |
|---|---|
| New Order: Enter in a field places nothing; an empty order is refused. | ![](screens/after-08-new-order-refused.png) |
| In-place customer email. | ![](screens/after-09-customer-email-refused.png) |
| Unit serial: an unknown code. | ![](screens/after-10-serial-refused.png) |
| Schedule: end before start. | ![](screens/after-11-schedule-refused.png) |
| New return pickup: end before start, refused before anything is booked. | ![](screens/after-12-new-pickup-refused.png) |
| Missed stop: "Other" needs a note. | ![](screens/after-13-missed-stop-refused.png) |
| Edit driver: blank name. | ![](screens/after-14-driver-refused.png) |
| Where a driver works: saved. | ![](screens/after-15-driver-locations-saved.png) |

## Staff and locations

| | |
|---|---|
| Staff profile, short password and staff note. | ![](screens/after-16-staff-forms.png) |
| Add login: empty form. | ![](screens/after-17-add-login-refused.png) |
| Driver settings: blank name. | ![](screens/after-18-driver-settings-refused.png) |
| Pharmacy details: short ZIP. | ![](screens/after-19-pharmacy-zip-refused.png) |
| Business contact: blank name. | ![](screens/after-20-business-contact-refused.png) |
| Edit rental: blank name. | ![](screens/after-21-edit-rental-name-refused.png) |
| Edit rental: bad email. | ![](screens/after-22-edit-rental-email-refused.png) |

These screenshots show decision 1, taken before decision 2 added the red
field marks and the cursor move. Decision 2 is covered by its unit tests
(`tests/unit/form-checks.test.ts`, `field-rules.test.ts`) and the guard that
every save form runs its checks (`form-saves.test.ts`). Its on-screen check
is still to run: nu-yin was unreachable when it was attempted.

## In code

**Before.** Each save checked inline and stopped at the first problem, with
one sentence and no field:

```tsx
mutationFn: async () => {
  if (!form.name.trim()) throw new Error('Name is required.')
  if (form.purchasable && form.sale === '') throw new Error('Enter a sale price for purchasable items.')
  // a negative sale price reached the database, which returned raw text
}
<button onClick={() => save.mutate()}>Save changes</button>
```

**After.** The form's checks return every problem with its field; the shared
form marks, explains and focuses them before sending:

```tsx
<SaveForm onSave={() => save.mutateAsync()} validate={() => productFormProblems({ ...values })}>
  <Checked name="salePrice"><input inputMode="decimal" value={form.sale} … /></Checked>
  <SubmitButton>{(pending) => pending ? 'Saving…' : 'Save changes'}</SubmitButton>
</SaveForm>
```
