import { Suspense } from 'react'
import Delivery from '../../../screens/Delivery'

// useSearchParams (selected-order deep link) needs a Suspense boundary.
export default function DeliveryPage() {
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Delivery />
    </Suspense>
  )
}
