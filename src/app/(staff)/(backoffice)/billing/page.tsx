import { Suspense } from 'react'
import Billing from '../../../../screens/Billing'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

// useSearchParams (selected-order deep link) needs a Suspense boundary.
export default async function BillingPage() {
  await requireStaffModule('billing')
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Billing />
    </Suspense>
  )
}
