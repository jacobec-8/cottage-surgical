import 'server-only'

import { createClient as createSupabaseClient } from '@supabase/supabase-js'
import { cache } from 'react'
import { PRODUCT_FIELDS, type Product } from './shop'

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const PUBLIC_CATALOG_REVALIDATE_SECONDS = 60

function createPublicCatalogClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!url || !anonKey) return null

  return createSupabaseClient(url, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      fetch: (input, init) =>
        fetch(input, {
          ...init,
          next: { revalidate: PUBLIC_CATALOG_REVALIDATE_SECONDS },
        }),
    },
  })
}

export type PublicProductLookup =
  | { status: 'found'; product: Product }
  | { status: 'not-found' }
  | { status: 'unavailable' }

function unavailableProduct(error: { message?: string }): PublicProductLookup {
  console.error(
    'Server product load failed:',
    error.message || 'The public catalog backend is unavailable.',
  )
  return { status: 'unavailable' }
}

// React cache deduplicates reads within a render/request. The route pages set
// the same persistent freshness window; this anonymous client's fetch policy
// ensures public data is never cached with a visitor's auth cookies.
export const getPublicCatalog = cache(async (): Promise<Product[]> => {
  const supabase = createPublicCatalogClient()
  if (!supabase) return []

  const { data, error } = await supabase
    .from('equipment_items')
    .select(PRODUCT_FIELDS)
    .eq('is_active', true)
    .order('category')
    .order('name')

  if (error) {
    throw new Error('Unable to load the public equipment catalog.', { cause: error })
  }

  return (data ?? []) as unknown as Product[]
})

export const getPublicProduct = cache(async (handle: string): Promise<PublicProductLookup> => {
  const supabase = createPublicCatalogClient()
  if (!supabase) return { status: 'unavailable' }

  const normalizedHandle = handle.trim()
  if (!normalizedHandle) return { status: 'not-found' }

  const byHandle = await supabase
    .from('equipment_items')
    .select(PRODUCT_FIELDS)
    .eq('shopify_handle', normalizedHandle)
    .eq('is_active', true)
    .maybeSingle()

  if (byHandle.error) {
    return unavailableProduct(byHandle.error)
  }
  if (byHandle.data) return { status: 'found', product: byHandle.data as unknown as Product }

  // equipment_items.id is UUID-backed. Avoid sending an invalid UUID literal
  // to Postgres for an ordinary, missing Shopify handle.
  if (!UUID_PATTERN.test(normalizedHandle)) return { status: 'not-found' }

  const byId = await supabase
    .from('equipment_items')
    .select(PRODUCT_FIELDS)
    .eq('id', normalizedHandle)
    .eq('is_active', true)
    .maybeSingle()

  if (byId.error) {
    return unavailableProduct(byId.error)
  }

  return byId.data
    ? { status: 'found', product: byId.data as unknown as Product }
    : { status: 'not-found' }
})
