import { ShieldCheck } from 'lucide-react'
import type { CatalogItem } from '../../lib/locationOnboarding'
import { locationLabel, type OnboardingDraft } from '../../lib/businessOnboarding'
import { ReviewCard, priceText } from './ui'

type Props = {
  draft: OnboardingDraft
  ownerName: string
  catalog: CatalogItem[]
  go: (step: number) => void
  ownerNames: string[]
}

/** One review of access, then each business with its address, stock and prices. */
export default function ReviewStep({ draft, ownerName, catalog, go, ownerNames }: Props) {
  const count = draft.locations.length
  return (
    <div className="space-y-4">
      <ReviewCard title="Owner and access" edit={() => go(0)}>
        <p className="font-medium text-slate-900">{ownerName}</p>
        <ul className="mt-2 space-y-1">
          <li className="flex items-start gap-2"><ShieldCheck size={15} className="mt-0.5 shrink-0 text-blue-600" />
            {draft.ownerLogin
              ? <span><span className="font-medium">{draft.ownerFirstName} {draft.ownerLastName}</span> (@{draft.ownerUsername.trim().toLowerCase()}) sees every business {ownerName} owns, including {count === 1 ? 'this one' : `these ${count}`}.</span>
              : ownerNames.length ? <span>{ownerNames.join(', ')} (owner) sees every business {ownerName} owns, including {count === 1 ? 'this one' : `these ${count}`}.</span> : <span>No owner login yet. An admin can add one later from Staff.</span>}
          </li>
          {draft.locations.map((location, index) => location.staff.length > 0 && (
            <li key={location.key} className="pl-6">{location.staff.length} staff login{location.staff.length === 1 ? '' : 's'} for {locationLabel(location, index)} only</li>
          ))}
        </ul>
      </ReviewCard>

      {draft.locations.map((location, index) => {
        const quantity = location.stock.reduce((sum, row) => sum + (Number(row.quantity) || 0), 0)
        const delivers = location.fulfillmentMode !== 'pickup_only'
        return (
          <ReviewCard key={location.key} title={locationLabel(location, index)} edit={() => go(0)}>
            <p>{location.line1}{location.line2 ? `, ${location.line2}` : ''}, {location.city}, {location.state} {location.zip}</p>
            <p>{delivers ? 'Pickup and delivery' : 'Pickup only'} · {location.partnerType === 'owned' ? 'Owned' : 'Partner'} · {location.active ? 'Open to customers' : 'Not yet open to customers'}</p>
            {delivers && <p>Delivers to: {location.deliveryZips.trim() || 'no ZIP codes listed'}{location.deliversAnywhere ? ', plus ZIP codes no other business lists' : ''}</p>}
            {delivers && <p className="text-amber-700">Add its drivers on the Drivers page before booking deliveries.</p>}
            <p className="pt-2 font-medium text-slate-800">Stock · {location.stock.length} product{location.stock.length === 1 ? '' : 's'}, {quantity} item{quantity === 1 ? '' : 's'}</p>
            {location.stock.length ? (
              <ul className="space-y-1">
                {location.stock.map((row) => {
                  const item = catalog.find((entry) => entry.id === row.itemId)
                  return (
                    <li key={row.itemId}>
                      {row.quantity} × {item?.name ?? 'Equipment'}
                      <span className="block text-xs text-slate-500">
                        {row.pickup && item?.pickup_enabled ? `Pickup ${priceText(row.pickupPrice, item.pickup_rental_price)}` : 'Pickup off'}
                        {item?.delivery_enabled && delivers ? ` · Delivery ${priceText(row.deliveryPrice, item.delivery_rental_price)}` : ''}
                      </span>
                    </li>
                  )
                })}
              </ul>
            ) : <p>No stock yet. Add it later in Inventory.</p>}
            {location.staff.length > 0 && <p className="pt-2">Staff: {location.staff.map((p) => `${p.firstName} ${p.lastName} (@${p.username.trim().toLowerCase()})`).join(', ')}</p>}
          </ReviewCard>
        )
      })}
    </div>
  )
}
