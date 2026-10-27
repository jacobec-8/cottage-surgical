import { ShieldCheck } from 'lucide-react'
import type { CatalogItem } from '../../lib/locationOnboarding'
import { branchLabel, type BusinessDraft } from '../../lib/businessOnboarding'
import type { ExistingDriver } from './DriversStep'
import { ReviewCard, priceText } from './ui'

type Props = {
  draft: BusinessDraft
  businessName: string
  catalog: CatalogItem[]
  existing: ExistingDriver[]
  go: (step: number) => void
}

/** One review of access, branches, stock, prices and driver coverage. */
export default function ReviewStep({ draft, businessName, catalog, existing, go }: Props) {
  const name = (key: string) => {
    const index = draft.branches.findIndex((branch) => branch.key === key)
    return index < 0 ? 'Removed branch' : branchLabel(draft.branches[index], index)
  }
  const driverName = (id: string) => {
    const driver = existing.find((d) => d.id === id)
    return driver ? `${driver.first_name} ${driver.last_name}` : 'Existing driver'
  }
  const coverage = (key: string) => draft.drivers.filter((d) => d.homeKey === key || d.alsoKeys.includes(key)).length
  return (
    <div className="space-y-4">
      <ReviewCard title="Business and access" edit={() => go(0)}>
        <p className="font-medium text-slate-900">{businessName}</p>
        {!draft.businessId && <p>Contact: {draft.contactName} · {draft.contactEmail || draft.contactPhone}</p>}
        <ul className="mt-2 space-y-1">
          <li className="flex items-start gap-2"><ShieldCheck size={15} className="mt-0.5 shrink-0 text-blue-600" />
            {draft.ownerLogin
              ? <span><span className="font-medium">{draft.ownerFirstName} {draft.ownerLastName}</span> (@{draft.ownerUsername.trim().toLowerCase()}) sees orders, stock, billing and dispatch for {draft.businessId ? `every ${businessBranchWord(draft.branches.length)} and the existing ones` : draft.branches.length === 1 ? 'this branch' : `all ${draft.branches.length} branches`}.</span>
              : <span>No owner login. An admin can add one later from Staff.</span>}
          </li>
          {draft.branches.map((branch, index) => branch.staff.length > 0 && (
            <li key={branch.key} className="pl-6">{branch.staff.length} staff login{branch.staff.length === 1 ? '' : 's'} for {branchLabel(branch, index)} only</li>
          ))}
        </ul>
      </ReviewCard>

      {draft.branches.map((branch, index) => {
        const quantity = branch.stock.reduce((sum, row) => sum + (Number(row.quantity) || 0), 0)
        const drivers = coverage(branch.key)
        return (
          <ReviewCard key={branch.key} title={branchLabel(branch, index)} edit={() => go(1)}>
            <p>{branch.line1}{branch.line2 ? `, ${branch.line2}` : ''}, {branch.city}, {branch.state} {branch.zip}</p>
            <p>{branch.fulfillmentMode === 'pickup_only' ? 'Pickup only' : 'Pickup and delivery'} · {branch.partnerType === 'owned' ? 'Owned' : 'Partner'} · {branch.active ? 'Open to customers' : 'Not yet open to customers'}</p>
            <p className={branch.fulfillmentMode !== 'pickup_only' && drivers === 0 ? 'text-amber-700' : ''}>
              {drivers === 0 ? (branch.fulfillmentMode === 'pickup_only' ? 'No drivers (pickup only)' : 'No drivers yet — deliveries can’t be dispatched until one is added') : `${drivers} driver${drivers === 1 ? '' : 's'} available`}
            </p>
            <p className="pt-2 font-medium text-slate-800">Stock · {branch.stock.length} product{branch.stock.length === 1 ? '' : 's'}, {quantity} item{quantity === 1 ? '' : 's'}</p>
            {branch.stock.length ? (
              <ul className="space-y-1">
                {branch.stock.map((row) => {
                  const item = catalog.find((entry) => entry.id === row.itemId)
                  return (
                    <li key={row.itemId}>
                      {row.quantity} × {item?.name ?? 'Equipment'}
                      <span className="block text-xs text-slate-500">
                        {row.pickup && item?.pickup_enabled ? `Pickup ${priceText(row.pickupPrice, item.pickup_rental_price)}` : 'Pickup off'}
                        {item?.delivery_enabled && branch.fulfillmentMode !== 'pickup_only' ? ` · Delivery ${priceText(row.deliveryPrice, item.delivery_rental_price)}` : ''}
                      </span>
                    </li>
                  )
                })}
              </ul>
            ) : <p>No stock yet. Add it later in Inventory.</p>}
            {branch.staff.length > 0 && <p className="pt-2">Staff: {branch.staff.map((p) => `${p.firstName} ${p.lastName} (@${p.username.trim().toLowerCase()})`).join(', ')}</p>}
          </ReviewCard>
        )
      })}

      <ReviewCard title={`Drivers · ${draft.drivers.length}`} edit={() => go(2)}>
        {draft.drivers.length ? (
          <ul className="space-y-1">
            {draft.drivers.map((driver) => (
              <li key={driver.id}>
                {driver.existingDriverId
                  ? <><span className="font-medium">{driverName(driver.existingDriverId)}</span> (existing) also serves {driver.alsoKeys.map(name).join(', ')}</>
                  : <><span className="font-medium">{driver.firstName} {driver.lastName}</span> · home {name(driver.homeKey)}{driver.alsoKeys.length ? `, also ${driver.alsoKeys.map(name).join(', ')}` : ''} · {driver.login ? `@${driver.username.trim().toLowerCase()}` : 'no login'}</>}
              </li>
            ))}
          </ul>
        ) : <p>No drivers yet. Add them later from Drivers.</p>}
        <p className="pt-2 text-xs text-slate-500">A driver can’t be booked into overlapping times at any branch, and can only be on one stop at a time.</p>
      </ReviewCard>
    </div>
  )
}

function businessBranchWord(count: number) { return count === 1 ? 'new branch' : `one of the ${count} new branches` }
