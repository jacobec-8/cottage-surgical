import type { Metadata } from 'next'
import ProductPage from '../../../../screens/shop/ProductPage'
import { getPublicProduct } from '../../../../lib/shopServer'

// Product detail HTML and metadata use the same public one-minute freshness
// window as the catalog. Browser React Query still refreshes after hydration.
export const dynamic = 'force-static'
export const revalidate = 60

type ProductRouteProps = {
  params: Promise<{ handle: string }>
}

export async function generateMetadata({ params }: ProductRouteProps): Promise<Metadata> {
  const { handle } = await params
  const result = await getPublicProduct(handle)

  // A product can become listed between the one-minute rebuilds (retail sales
  // switched on, priced, restocked), so an unlisted product is not cached as a
  // 404: the page checks live in the browser instead. Keep it out of search.
  if (result.status === 'not-found') return { title: 'Cottage Surgical', robots: { index: false } }
  if (result.status === 'unavailable') {
    return {
      title: 'Medical Equipment Rental | Cottage Surgical',
      description:
        'View rental pricing and request home medical equipment delivery from Cottage Surgical.',
    }
  }

  const product = result.product
  const description = product.description?.replace(/\s+/g, ' ').trim()
  return {
    title: `${product.name} Rental | Cottage Surgical`,
    description:
      description?.slice(0, 160) ||
      `Rent ${product.name} from Cottage Surgical with delivery and professional setup across Long Island.`,
    alternates: {
      canonical: `/product/${encodeURIComponent(product.shopify_handle ?? product.id)}`,
    },
    openGraph: product.image_url ? { images: [{ url: product.image_url, alt: product.name }] } : undefined,
  }
}

export default async function ProductRoute({ params }: ProductRouteProps) {
  const { handle } = await params
  const result = await getPublicProduct(handle)

  return (
    <ProductPage
      handle={handle}
      initialProduct={result.status === 'found' ? result.product : undefined}
    />
  )
}
