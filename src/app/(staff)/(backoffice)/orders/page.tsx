import { Suspense } from 'react'
import Orders from '../../../../screens/Orders'

// useSearchParams (selected-order deep link) needs a Suspense boundary.
export default function OrdersPage() {
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Orders />
    </Suspense>
  )
}
