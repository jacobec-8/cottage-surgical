import type { Metadata } from 'next'
import { Suspense } from 'react'
import CheckoutSuccess from '../../../../screens/shop/CheckoutSuccess'

export const metadata: Metadata = {
  title: 'Confirming Your Order | Cottage Surgical',
  robots: { index: false, follow: false },
}

export default function CheckoutSuccessPage() {
  return (
    <Suspense fallback={<CheckoutSuccessFallback />}>
      <CheckoutSuccess />
    </Suspense>
  )
}

function CheckoutSuccessFallback() {
  return (
    <main className="min-h-screen bg-cream grid place-items-center px-4 text-slate-500">
      Confirming your payment…
    </main>
  )
}
