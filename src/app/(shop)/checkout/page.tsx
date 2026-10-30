import type { Metadata } from 'next'
import { Suspense } from 'react'
import Checkout from '../../../screens/shop/Checkout'

export const metadata: Metadata = {
  title: 'Checkout | Cottage Surgical',
  robots: { index: false, follow: false },
}

export default function CheckoutPage() {
  return (
    <Suspense fallback={<main className="min-h-screen bg-cream grid place-items-center px-4 text-slate-500">Loading checkout…</main>}>
      <Checkout />
    </Suspense>
  )
}
