'use client'

import { useState, type ReactNode } from 'react'
import type { StaffLocation } from '../../contexts/LocationContext'
import { nextLocation } from '../../lib/locationSteps'
import AddProductsPanel from './AddProductsPanel'
import LocationCards from './LocationCards'
import YourProducts from './YourProducts'
import { importLocations } from './useAddProducts'
import { useOwnerProducts } from './useOwnerProducts'

type Props = {
  businessId: string
  locations: readonly StaffLocation[]
  initialId?: string | null
  /** The wizard's buttons, given the location being done and the next one still to do. */
  renderNav?: (current: StaffLocation, next: StaffLocation | null, select: (id: string) => void) => ReactNode
}

/**
 * Products one location at a time (owner, 2026-11-10): choose a location, add
 * all its products, then the next. Your products already carried elsewhere
 * come first; new ones from the starter list, a CSV or by hand.
 */
export default function ProductsByLocation({ businessId, locations, initialId, renderNav }: Props) {
  const [currentId, setCurrentId] = useState(initialId && locations.some((l) => l.id === initialId) ? initialId : locations[0]?.id ?? '')
  const owner = useOwnerProducts(businessId)
  const current = locations.find((l) => l.id === currentId) ?? locations[0]
  if (!current) return <p className="text-sm text-slate-600">Add a location first.</p>
  const [here] = importLocations([current])
  const count = (id: string) => owner.carriedAt(id).length
  const elsewhere = owner.notCarriedAt(current.id)
  const next = nextLocation(locations, current.id, (id) => count(id) > 0)

  return (
    <div className="space-y-6">
      <section className="space-y-3">
        <h2 className="text-lg font-semibold">1. Which location are you stocking?</h2>
        {locations.length > 1 && <p className="text-sm text-slate-600">Do one location at a time. When it’s done, move on to the next.</p>}
        <LocationCards label="Location to stock" locations={locations} selectedId={current.id} onSelect={setCurrentId}
          status={(l) => ({ text: count(l.id) ? `${count(l.id)} product${count(l.id) === 1 ? '' : 's'}` : 'Not started', done: count(l.id) > 0 })} />
      </section>

      <section className="space-y-5 rounded-2xl border border-slate-200 bg-white p-5 sm:p-6">
        <h2 className="text-lg font-semibold">2. Add products to {current.name}</h2>
        {owner.query.error && <p role="alert" className="text-sm text-red-600">Couldn’t load your products. Please refresh.</p>}
        {elsewhere.length > 0 && <YourProducts key={`carry-${current.id}`} businessId={businessId} location={here} products={elsewhere} />}
        <div className="space-y-3">
          {elsewhere.length > 0 && (
            <div className="border-t border-slate-100 pt-5">
              <h3 className="text-base font-semibold text-slate-900">Add new products</h3>
              <p className="text-sm text-slate-600">Products you already have don’t show in the starter list.</p>
            </div>
          )}
          <AddProductsPanel key={`add-${current.id}`} target={{ businessId, locations: [here] }} hideNames={owner.names} />
        </div>
      </section>

      {renderNav?.(current, next, setCurrentId)}
    </div>
  )
}
