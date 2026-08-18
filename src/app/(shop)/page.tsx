import type { Metadata } from 'next'
import { Suspense } from 'react'
import Shop from '../../screens/shop/Shop'
import type { Product } from '../../lib/shop'
import { getPublicCatalog } from '../../lib/shopServer'

// Catalog HTML is shared publicly and refreshed at most one minute after a
// catalog change. The client query remains responsible for live catch-up.
export const dynamic = 'force-static'
export const revalidate = 60

export const metadata: Metadata = {
  title: 'Home Medical Equipment Rentals | Cottage Surgical',
  description:
    'Rent home medical equipment with same-day delivery and professional setup across Nassau and Suffolk County, NY.',
}

export default async function ShopPage() {
  let initialProducts: Product[] | undefined
  try {
    initialProducts = await getPublicCatalog()
  } catch (error) {
    // Keep the storefront usable if the server read has a transient failure;
    // the existing browser query will still load and retry the catalog.
    console.error(
      'Server catalog load failed:',
      error instanceof Error ? error.message : 'The public catalog backend is unavailable.',
    )
  }

  return (
    <Suspense fallback={<ShopPageFallback />}>
      <Shop initialProducts={initialProducts} />
    </Suspense>
  )
}

function ShopPageFallback() {
  return (
    <main className="min-h-screen bg-white grid place-items-center px-4 text-slate-500">
      Loading equipment…
    </main>
  )
}
