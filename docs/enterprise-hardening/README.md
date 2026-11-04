# Enterprise hardening

Decisions for making Cottage Surgical behave like enterprise software. Each
decision lists what we chose, why, and what "done" means. Work items live in
their own checklist files in this folder.

## Decision 1: saves use real form submits (2026-11-04)

**Rule.** If staff enter something and it does not save, that must be
obvious. The screen never shows staff a value the database did not accept
without saying so.

**What we found.** 24 data-entry saves in the staff app call the save from a
button's click handler instead of a form submit. Five existing forms still
rely on the browser's tooltip checks. The product edit form showed raw
Postgres text on a rejected price and gave no confirmation on success.

**What enterprises do.** Data entry uses a real form element with a submit
button. GitHub, Shopify's admin and the Next.js documentation all build forms
this way. Browser tooltip checks are turned off with `noValidate`, and the app
shows its own message next to the field. The server stays the final authority,
because browser checks can be skipped by anyone calling the API.

**What we chose.**

- Every save that has fields to fill in becomes a form submit.
- Every form gets `noValidate`.
- Every save shows a visible "Saved" on success and a plain-language error on
  failure, next to the Save button.
- One-click actions with no fields stay plain buttons. Examples: Verify
  payment, Mark picked up, Mark all read, Rent Now.
- The save logic itself does not change. Only the wiring and the feedback do.

**How the change is made.** One shared component, so all saves behave the
same way:

```tsx
<SaveForm onSave={() => save.mutate()} pending={save.isPending} error={save.error} saved={save.isSuccess}>
  {/* existing fields, unchanged */}
</SaveForm>
```

The component:

1. Renders `<form noValidate>` and calls `preventDefault` before the save, so
   the page never reloads.
2. Renders the Save button with `type="submit"`, disabled and reading
   "Saving…" while the save runs, so a double click saves once.
3. Shows "Saved" with `role="status"` on success, and the error with
   `role="alert"` on failure, both beside the button.
4. Translates database errors into plain words, for example a negative price
   becomes "Prices can't be negative" instead of the check-constraint text.

Each converted screen also follows two rules:

- Every other button inside the form gets `type="button"`. A button without a
  type submits the form, so an unmarked Cancel would save.
- A form never contains another form. HTML does not allow it, and the browser
  silently drops the inner one.

**Done means, for each save.**

- Pressing Enter in a single-line field saves.
- Cancel and other buttons inside the form do not save.
- A double click produces one save.
- Success shows "Saved"; failure shows a plain error and nothing changes.
- No form sits inside another form.
- Typecheck and lint pass.
- Checked on screen, not only in code.

Tracking: [form-saves-checklist.md](form-saves-checklist.md).
