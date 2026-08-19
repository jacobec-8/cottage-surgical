import { Suspense } from 'react'
import Billing from '../../../../screens/Billing'

// useSearchParams (selected-order deep link) needs a Suspense boundary.
export default function BillingPage() {
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Billing />
    </Suspense>
  )
}
