# Form saves checklist

Decision 1 in [README.md](README.md). Tick an item only when every "done"
check in the README passes for it, including the on-screen check. Line numbers
are from 2026-11-04 and will drift as files change.

## Click-handler saves to convert to form submits (24)

### Inventory and products

- [ ] Edit product, Save changes. `src/screens/InventoryItemDetail.tsx:762`
- [ ] Store stock and price override, Save stock. `src/screens/InventoryItemDetail.tsx:478`
- [ ] Unit editor, Save unit. `src/screens/InventoryItemDetail.tsx:628`
- [ ] Inventory note, Add inventory note. `src/screens/InventoryItemDetail.tsx:635`
- [ ] New product, Save. `src/screens/Inventory.tsx:464`
- [ ] In-place product field, Save. `src/components/ProductDetailsList.tsx:167`
- [ ] In-place product text, Save. `src/components/ProductDetailsList.tsx:345`

### Orders and customers

- [ ] New order, Create. `src/screens/NewOrder.tsx:426`
- [ ] Unit serial, Save. `src/screens/orders/UnitCell.tsx:70`
- [ ] In-place customer field, Save. `src/screens/customers/EditableRow.tsx:48`

### Delivery and drivers

- [ ] Schedule, Save. `src/screens/delivery/ScheduleForm.tsx:105`
- [ ] New stop, Add pickup. `src/screens/delivery/NewStopPanel.tsx:150`
- [ ] Missed stop, Confirm. `src/screens/delivery/MissedStop.tsx:63`
- [ ] Add driver, Save. `src/screens/Drivers.tsx:156`
- [ ] Edit driver, Save changes. `src/screens/Drivers.tsx:292`
  Watch: the driver row also renders Driver locations, which has its own Save.
  The two forms must sit side by side, never one inside the other.
- [ ] Driver locations, Save. `src/screens/drivers/DriverLocations.tsx:81`

### Staff and locations

- [ ] Staff profile, Save profile. `src/screens/StaffDetail.tsx:153`
- [ ] Driver settings, Save driver settings. `src/screens/StaffDetail.tsx:162`
- [ ] Staff note, Add private staff note. `src/screens/StaffDetail.tsx:166`
- [ ] Add login. `src/screens/staff/AddLoginForm.tsx:71`
- [ ] Login profile, Save profile. `src/screens/staff/LoginAccess.tsx:55`
- [ ] Set password. `src/screens/staff/LoginAccess.tsx:75`
- [ ] Location details, Save details. `src/screens/LocationDetail.tsx:224`
  Watch: the business contact form renders just above it, at line 202. The
  new form must wrap only the location detail fields, not the contact form.
- [ ] Location logins, Create. `src/screens/LocationDetail.tsx:234`

## Existing forms that need noValidate and visible errors (5)

- [ ] Business contact. `src/components/BusinessContact.tsx:31`
- [ ] Edit rental. `src/screens/orders/EditRentalModal.tsx:119`
- [ ] Return address. `src/screens/orders/ReturnAddressForm.tsx:25`
- [ ] Storefront checkout. `src/screens/shop/Checkout.tsx:191`
- [ ] Staff sign-in. `src/screens/Login.tsx:86`

Already done: business onboarding, `src/screens/onboarding/BusinessOnboarding.tsx:165`.

## Shared pieces

- [ ] `SaveForm` component: form with noValidate, submit button, Saving state,
  Saved and error messages.
- [ ] Plain-language translation of database errors, used by `SaveForm`.

## Deliberately left as buttons

One-click actions with no fields. They stay plain buttons with
`type="button"`.

- Mark all read. `src/components/NotificationsBell.tsx:100`
- Rent Now and Purchase. `src/components/shop/ProductCard.tsx:81`, `src/screens/shop/ProductPage.tsx:113`
- Start stop. `src/screens/Delivery.tsx:257`
- Mark picked up. `src/screens/delivery/StaffStopCard.tsx:98`
- Remove from catalog. `src/screens/Inventory.tsx:137`
- Add item to order. `src/screens/NewOrder.tsx:363`
- Add from catalog. `src/screens/inventory/CatalogPicker.tsx:69`
- Turn retail sales on or off. `src/screens/dashboard/RetailSalesSwitch.tsx:51`
- Allocate unit. `src/screens/orders/DetailSections.tsx:129`
- Mark refunded and Mark forfeited. `src/screens/orders/DetailSections.tsx:262`
- Schedule pickup. `src/screens/orders/OrderDetailPanel.tsx:138`
- Verify payment. `src/screens/orders/OrderDetailPanel.tsx:148`, `src/screens/orders/UnpaidRow.tsx:43`
- Use scanned code as the serial. `src/screens/orders/UnitCell.tsx:74`
- Remove stock during onboarding. `src/screens/onboarding/LocationEditor.tsx:106`

Not saves, so out of scope: the storefront search box
(`src/screens/shop/Shop.tsx:93`) and the customer assistant chat
(`src/components/shop/CustomerAssistant.tsx:127`).
