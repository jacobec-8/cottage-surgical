import { Suspense } from 'react'
import Delivery from '../../../screens/Delivery'
import { requireStaffModule } from '../../../lib/staffAccessServer'

// useSearchParams (selected-order deep link) needs a Suspense boundary.
export default async function DeliveryPage() {
  await requireStaffModule('delivery', true)
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Delivery />
    </Suspense>
  )
}
