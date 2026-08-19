import { Suspense } from 'react'
import Requests from '../../../../screens/Requests'

// useSearchParams (selected-request deep link) needs a Suspense boundary.
export default function RequestsPage() {
  return (
    <Suspense fallback={<div className="text-slate-500">Loading…</div>}>
      <Requests />
    </Suspense>
  )
}
