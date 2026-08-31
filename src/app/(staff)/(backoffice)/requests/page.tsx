import { Suspense } from 'react'
import Requests from '../../../../screens/Requests'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

// useSearchParams (selected-request deep link) needs a Suspense boundary.
export default async function RequestsPage() {
  await requireStaffModule('requests')
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Requests />
    </Suspense>
  )
}
