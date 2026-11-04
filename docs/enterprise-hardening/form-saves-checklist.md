# Form saves checklist

Decisions 1 and 2 in [README.md](README.md). "Checks" means the form runs its
own field checks before sending (decision 2). "On screen" means decision 1's
outcomes were watched on nu-yin on 2026-11-04 against the live database with
QA records. Line numbers drift; search by file.

## Saves converted to form submits (24)

| Save | File | Checks | On screen |
|---|---|---|---|
| Edit product | `src/screens/InventoryItemDetail.tsx` | yes | yes |
| Store stock and price override | `src/screens/InventoryItemDetail.tsx` | yes | yes |
| Unit editor | `src/screens/InventoryItemDetail.tsx` | yes | yes |
| Inventory note | `src/screens/InventoryItemDetail.tsx` | yes | yes |
| New product | `src/screens/Inventory.tsx` | yes | yes |
| In-place product field | `src/components/ProductDetailsList.tsx` | yes | yes |
| In-place product text | `src/components/ProductDetailsList.tsx` | yes | yes |
| New order | `src/screens/NewOrder.tsx` | yes | yes |
| Unit serial | `src/screens/orders/UnitCell.tsx` | yes | yes |
| In-place customer field | `src/screens/customers/EditableRow.tsx` | yes | yes |
| Schedule | `src/screens/delivery/ScheduleForm.tsx` | yes | yes |
| New return pickup | `src/screens/delivery/NewStopPanel.tsx` | yes | yes |
| Missed stop | `src/screens/delivery/MissedStop.tsx` | yes | yes |
| Add driver | `src/screens/Drivers.tsx` | yes | yes |
| Edit driver | `src/screens/Drivers.tsx` | yes | yes |
| Where a driver works | `src/screens/drivers/DriverLocations.tsx` | nothing typed | yes |
| Staff profile | `src/screens/StaffDetail.tsx` | yes | yes |
| Driver settings | `src/screens/StaffDetail.tsx` | yes | yes |
| Staff note | `src/screens/StaffDetail.tsx` | yes | yes |
| Add login | `src/screens/staff/AddLoginForm.tsx` | yes | yes |
| Login profile (owner view) | `src/screens/staff/LoginAccess.tsx` | yes | not run: needs an owner login |
| Set password | `src/screens/staff/LoginAccess.tsx` | yes | yes |
| Pharmacy details | `src/screens/LocationDetail.tsx` | yes | yes |
| Location users | `src/screens/LocationDetail.tsx` | yes | not run: the page needs https to add rows; the test server was http |

## Forms that already submitted (5)

| Form | File | Checks | On screen |
|---|---|---|---|
| Business contact | `src/components/BusinessContact.tsx` | yes | yes |
| Edit rental | `src/screens/orders/EditRentalModal.tsx` | yes | yes |
| Return address | `src/screens/orders/ReturnAddressForm.tsx` | yes | not run: no rental without an address to test on |
| Storefront checkout | `src/screens/shop/Checkout.tsx` | yes | not run: nu-yin unreachable; browser suite passes |
| Staff sign-in | `src/screens/Login.tsx` | yes | not run: nu-yin unreachable |

Decision 2's field marks and cursor move are covered by unit tests. Their
on-screen check is still to run.

## Left as buttons on purpose

One-click actions with no fields: Mark all read, Rent Now and Purchase, Start
stop, Mark picked up, Remove from catalog, Add item to order, Add from
catalog, Turn retail sales on or off, Allocate unit, Mark refunded and Mark
forfeited, Schedule pickup, Verify payment, Use scanned code as the serial,
Remove stock during onboarding.

Not saves, so out of scope: the storefront search box and the customer
assistant chat.
