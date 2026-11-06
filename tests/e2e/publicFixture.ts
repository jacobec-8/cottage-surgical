import { expect, type Page } from '@playwright/test'

/** The read-only public catalog and page helpers shared by the storefront specs. */
export const catalog = [
  {
    id: 'playwright-wheelchair-1',
    name: 'Playwright Wheelchair',
    description: 'Read-only browser-test fixture.',
    category: 'mobility',
    monthly_rental_price: 125,
    pickup_rental_price: 125,
    delivery_rental_price: 125,
    sale_price: null,
    image_url: null,
    shopify_handle: 'playwright-wheelchair',
    is_rentable: true,
    is_purchasable: false,
    pickup_enabled: true,
    delivery_enabled: true,
    same_day_pickup: true,
    installation_required: false,
    pickup_locations: [{
      pickup_location: {
        id: 'playwright-woodbury', name: 'Woodbury Store', address_line1: '1 Test Lane',
        address_line2: null, address_city: 'Woodbury', address_state: 'NY', address_zip: '11797',
        phone: null, instructions: 'Bring photo ID.',
        fulfillment_mode: 'pickup_and_delivery', partner_type: 'owned',
      },
    }],
  },
  {
    id: 'playwright-bed-1',
    name: 'Playwright Hospital Bed',
    description: 'Read-only browser-test fixture.',
    category: 'beds',
    monthly_rental_price: 275,
    pickup_rental_price: null,
    delivery_rental_price: 275,
    sale_price: null,
    image_url: null,
    shopify_handle: 'playwright-hospital-bed',
    is_rentable: true,
    is_purchasable: false,
    pickup_enabled: false,
    delivery_enabled: true,
    same_day_pickup: false,
    installation_required: true,
    pickup_locations: [],
  },
]

export async function mockCatalogReads(page: Page, products = catalog) {
  await page.route('**/rest/v1/equipment_items**', async (route) => {
    const request = route.request()

    if (request.method() === 'OPTIONS') {
      await route.fulfill({
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, OPTIONS',
          'access-control-allow-headers':
            'authorization, apikey, content-type, x-client-info, prefer, accept-profile',
        },
      })
      return
    }

    if (request.method() !== 'GET') {
      await route.abort('blockedbyclient')
      return
    }

    const url = new URL(request.url())
    const handle = url.searchParams.get('shopify_handle')?.replace(/^eq\./, '')
    const rawId = url.searchParams.get('id')
    const ids = rawId?.startsWith('in.(')
      ? rawId.slice(4, -1).split(',')
      : null
    const id = rawId?.replace(/^eq\./, '')
    const requestedProduct = handle || id
    const result = ids
      ? products.filter((product) => ids.includes(product.id))
      : requestedProduct
      ? products.filter(
          (product) =>
            product.shopify_handle === requestedProduct || product.id === requestedProduct,
        )
      : products

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(result),
      headers: {
        'access-control-allow-origin': '*',
        'access-control-expose-headers': 'content-range',
        'content-range': result.length ? `0-${result.length - 1}/${result.length}` : '*/0',
      },
    })
  })
}

export type FixturePairing = { equipment_item_id: string; paired_item_id: string; position: number }

/** The "Goes well with" picks (127) the browser reads with the public key. */
export async function mockPairings(page: Page, pairings: FixturePairing[]) {
  await page.route('**/rest/v1/product_pairings**', async (route) => {
    if (route.request().method() === 'OPTIONS') {
      await route.fulfill({
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, OPTIONS',
          'access-control-allow-headers':
            'authorization, apikey, content-type, x-client-info, prefer, accept-profile',
        },
      })
      return
    }
    const raw = new URL(route.request().url()).searchParams.get('equipment_item_id') ?? ''
    const ids = raw.startsWith('in.(') ? raw.slice(4, -1).split(',') : []
    const result = pairings.filter((pairing) => ids.includes(pairing.equipment_item_id))
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(result),
      headers: { 'access-control-allow-origin': '*' },
    })
  })
}

export async function openPublicRoute(page: Page, path: string) {
  const response = await page.goto(path, { waitUntil: 'domcontentloaded' })

  expect(response, `${path} should return a document response`).not.toBeNull()
  expect(response!.status(), `${path} should not return a server error`).toBeLessThan(500)
  await expect(page.getByRole('banner')).toBeVisible()
  await expect(page.getByRole('contentinfo')).toBeVisible()
  await expect(page.locator('body')).not.toContainText(
    'Application error: a client-side exception has occurred',
  )
}

export function savedCartItem(mode: 'rent' | 'purchase') {
  return {
    id: catalog[0].id,
    name: catalog[0].name,
    image_url: null,
    category: catalog[0].category,
    mode,
    price: catalog[0].delivery_rental_price,
    pickup_price: catalog[0].pickup_rental_price,
    delivery_price: catalog[0].delivery_rental_price,
    qty: 1,
    pickup_enabled: true,
    delivery_enabled: true,
    same_day_pickup: false,
    pickup_locations: [],
  }
}

/** Rent Now before hydration does nothing; retry until the cart has actually slid in. */
export async function rentNow(page: Page, productName: string) {
  const card = page.getByRole('link', { name: productName, exact: true }).locator('..')
  await expect(async () => {
    await card.getByRole('button', { name: 'Rent Now' }).click()
    await expect(page.getByRole('complementary')).toBeInViewport({ ratio: 1, timeout: 1000 })
  }).toPass()
}

/** A click before hydration does nothing. Ignore hidden streaming fragments while retrying. */
export async function openCart(page: Page) {
  await expect(async () => {
    await page.getByRole('button', { name: 'Cart', exact: true }).click()
    await expect(page.getByRole('complementary')).toBeInViewport({ ratio: 1, timeout: 1000 })
  }).toPass()
}
