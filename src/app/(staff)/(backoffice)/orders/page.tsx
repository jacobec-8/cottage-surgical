import { Suspense } from 'react'
import Orders from '../../../../screens/Orders'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

// useSearchParams (selected-order deep link) needs a Suspense boundary.
export default async function OrdersPage() {
  await requireStaffModule('orders')
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Orders />
    </Suspense>
  )
}
