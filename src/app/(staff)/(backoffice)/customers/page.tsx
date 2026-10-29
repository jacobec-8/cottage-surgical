import { Suspense } from 'react'
import Customers from '../../../../screens/Customers'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

// useSearchParams (selected-customer deep link) needs a Suspense boundary.
export default async function CustomersPage() {
  await requireStaffModule('customers')
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Customers />
    </Suspense>
  )
}
