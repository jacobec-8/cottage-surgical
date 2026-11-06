import { expect, test, type Page } from '@playwright/test'
import { rentNow } from './publicFixture'

const runtimeFailures = new WeakMap<Page, string[]>()
const clientExceptionPattern =
  /hydrat(?:e|ed|ing|ion)|client-side exception|application error|uncaught|react has detected|minified react error/i

test.beforeEach(({ page }) => {
  const failures: string[] = []
  runtimeFailures.set(page, failures)

  page.on('pageerror', (error) => {
    failures.push(`Uncaught page error: ${error.stack || error.message}`)
  })
  page.on('console', (message) => {
    if (message.type() === 'error' && clientExceptionPattern.test(message.text())) {
      failures.push(`Client console error: ${message.text()}`)
    }
  })
})

test.afterEach(async ({ page }) => {
  await page.waitForTimeout(25)
  const failures = runtimeFailures.get(page) || []
  runtimeFailures.delete(page)
  expect(failures, 'the page should not emit uncaught, hydration, or client exceptions').toEqual([])
})

const catalog = [
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

async function mockCatalogReads(page: Page, products = catalog) {
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

async function openPublicRoute(page: Page, path: string) {
  const response = await page.goto(path, { waitUntil: 'domcontentloaded' })

  expect(response, `${path} should return a document response`).not.toBeNull()
  expect(response!.status(), `${path} should not return a server error`).toBeLessThan(500)
  await expect(page.getByRole('banner')).toBeVisible()
  await expect(page.getByRole('contentinfo')).toBeVisible()
  await expect(page.locator('body')).not.toContainText(
    'Application error: a client-side exception has occurred',
  )
}

test.describe('anonymous public route smoke tests', () => {
  test('renders the storefront when the catalog is unavailable', async ({ page }) => {
    await page.route('**/rest/v1/equipment_items**', (route) => route.abort('failed'))
    await openPublicRoute(page, '/')
    await expect(
      page.getByRole('heading', {
        level: 1,
        name: /Home medical equipment.*delivered the same day/i,
      }),
    ).toBeVisible()
  })

  test('renders a product route from a read-only catalog fixture', async ({ page }) => {
    await mockCatalogReads(page)
    await openPublicRoute(page, '/product/playwright-wheelchair')
    await expect(
      page.getByRole('heading', { level: 1, name: 'Playwright Wheelchair' }),
    ).toBeVisible()
  })

  test('renders how it works', async ({ page }) => {
    await openPublicRoute(page, '/how-it-works')
    await expect(
      page.getByRole('heading', { level: 1, name: /On-Demand.*Order Now.*Use Today/i }),
    ).toBeVisible()
  })

  test('renders frequently asked questions', async ({ page }) => {
    await openPublicRoute(page, '/faq')
    await expect(
      page.getByRole('heading', { level: 1, name: 'Frequently Asked Questions' }),
    ).toBeVisible()
  })

  test('renders the return policy', async ({ page }) => {
    await openPublicRoute(page, '/return-policy')
    await expect(
      page.getByRole('heading', { level: 1, name: 'Return & Refund Policy' }),
    ).toBeVisible()
  })

  test('renders checkout success safely without contacting Stripe', async ({ page }) => {
    await openPublicRoute(page, '/checkout/success')
    await expect(
      page.getByRole('heading', { level: 1, name: 'Something went wrong' }),
    ).toBeVisible()
  })
})

test('a missing product renders a not-found state', async ({ page }) => {
  await mockCatalogReads(page, [])
  const response = await page.goto('/product/playwright-missing-product', {
    waitUntil: 'domcontentloaded',
  })

  expect(response, 'the missing-product route should return a document response').not.toBeNull()
  expect(response!.status()).toBeLessThan(500)
  await expect(
    page.getByText(/Product not found|Page not found|This page could not be found/i).first(),
  ).toBeVisible()
})

test('the q query initializes and filters storefront search', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/?q=wheelchair')

  expect(new URL(page.url()).searchParams.get('q')).toBe('wheelchair')
  await expect(page.getByRole('textbox', { name: 'Filter equipment…' })).toHaveValue(
    'wheelchair',
  )

  const matchingProduct = page.getByRole('link', {
    name: 'Playwright Wheelchair',
    exact: true,
  })
  const catalogError = page.getByText(/Could.?t load equipment\. Please try again\./i)

  // The loopback fixture serves the initial server catalog read, while the
  // browser route covers the post-hydration refetch. Keep the intentional
  // catalog error state valid so query behavior remains testable during an
  // unavailable-backend build.
  await expect(matchingProduct.or(catalogError).first()).toBeVisible()
  if (await matchingProduct.isVisible()) {
    await expect(
      page.getByRole('link', { name: 'Playwright Hospital Bed', exact: true }),
    ).toHaveCount(0)
  }
})

test('cart quantity persists across reload and items can be removed', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')

  await rentNow(page, 'Playwright Wheelchair')

  const drawer = page.getByRole('complementary')
  const cartItem = drawer
    .locator('div.border.border-slate-200.rounded-xl')
    .filter({ hasText: 'Playwright Wheelchair' })
  await expect(cartItem).toBeVisible()
  await expect(drawer.getByRole('link', { name: 'Continue to checkout (1)' })).toBeVisible()

  await cartItem.locator('button').nth(1).click()
  await expect(drawer.getByRole('link', { name: 'Continue to checkout (2)' })).toBeVisible()
  await expect(drawer.getByText('$250/mo', { exact: true })).toBeVisible()
  await expect
    .poll(() =>
      page.evaluate(() => {
        const items = JSON.parse(localStorage.getItem('cs_cart_v1') || '[]') as Array<{
          qty?: number
        }>
        return items[0]?.qty
      }),
    )
    .toBe(2)

  await page.reload({ waitUntil: 'domcontentloaded' })
  await openCart(page)

  const restoredItem = page
    .locator('aside div.border.border-slate-200.rounded-xl')
    .filter({ hasText: 'Playwright Wheelchair' })
  await expect(restoredItem).toBeVisible()
  await expect(page.getByRole('link', { name: 'Continue to checkout (2)' })).toBeVisible()

  await restoredItem.locator('button').first().click()
  await expect(page.getByRole('link', { name: 'Continue to checkout (1)' })).toBeVisible()
  await expect(drawer.getByText('$125/mo', { exact: true }).last()).toBeVisible()

  await restoredItem.locator('button').nth(2).click()
  await expect(page.getByText('Your cart is empty', { exact: true })).toBeVisible()
  await expect
    .poll(() =>
      page.evaluate(() => JSON.parse(localStorage.getItem('cs_cart_v1') || '[]').length),
    )
    .toBe(0)
})

test('checkout offers assigned pickup locations and keeps hospital beds delivery-only', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')

  await rentNow(page, 'Playwright Wheelchair')
  const drawer = page.getByRole('complementary')
  await drawer.getByRole('link', { name: 'Continue to checkout (1)' }).click()
  await expect(page).toHaveURL(/\/checkout$/)

  const pickup = page.getByRole('radio', { name: /In-store pickup/i })
  await expect(pickup).toBeEnabled()
  await page.getByText('In-store pickup', { exact: true }).click()
  await expect(page.getByLabel('Pickup location')).toHaveValue('playwright-woodbury')
  await expect(page.getByText(/Same-day pickup may be available/i)).toBeVisible()
  await expect(page.getByPlaceholder('Delivery address')).toHaveCount(0)
  await expect(page.getByText('Pay In Store', { exact: true })).toBeVisible()
  await expect(page.getByText('Pay Online', { exact: true })).toBeVisible()

  await page.evaluate(() => localStorage.removeItem('cs_cart_v1'))
  await page.goto('/', { waitUntil: 'domcontentloaded' })
  await rentNow(page, 'Playwright Hospital Bed')
  await drawer.getByRole('link', { name: 'Continue to checkout (1)' }).click()
  await expect(page).toHaveURL(/\/checkout$/)
  await expect(page.getByRole('radio', { name: /In-store pickup/i })).toBeDisabled()
  await expect(page.getByRole('radio', { name: /^Delivery\b/i })).toBeChecked()
  await expect(page.getByPlaceholder('Delivery address')).toBeVisible()
  await expect(page.getByText('Pay Delivery Person', { exact: true })).toBeVisible()
  await expect(page.getByText('Pay Online', { exact: true })).toBeVisible()
  await expect(page.getByText('Pay In Store', { exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Submit Request' })).toBeVisible()
})

test('checkout refreshes pickup settings in a saved cart', async ({ page }) => {
  await mockCatalogReads(page)
  await page.addInitScript((savedItem) => {
    localStorage.setItem('cs_cart_v1', JSON.stringify([savedItem]))
  }, {
    id: catalog[0].id,
    name: catalog[0].name,
    image_url: null,
    category: catalog[0].category,
    mode: 'rent',
    price: catalog[0].delivery_rental_price,
    pickup_price: catalog[0].pickup_rental_price,
    delivery_price: catalog[0].delivery_rental_price,
    qty: 1,
    pickup_enabled: true,
    delivery_enabled: true,
    same_day_pickup: false,
    pickup_locations: [],
  })

  await openPublicRoute(page, '/')
  await openCart(page)
  const drawer = page.getByRole('complementary')
  await drawer.getByRole('link', { name: 'Continue to checkout (1)' }).click()
  await expect(page).toHaveURL(/\/checkout$/)

  await expect(page.getByRole('radio', { name: /In-store pickup/i })).toBeEnabled()
  await page.getByText('In-store pickup', { exact: true }).click()
  await expect(page.getByLabel('Pickup location')).toHaveValue('playwright-woodbury')
})

test('double-clicking rental submit sends one request, with its save key and request ID', async ({ page }) => {
  await mockCatalogReads(page)
  let submissions = 0
  let sent: { key?: string; requestId?: string | null } = {}
  await page.route('**/rest/v1/rpc/submit_rental_request_once', async (route) => {
    submissions += 1
    sent = { key: route.request().postDataJSON()?.p_request_key, requestId: route.request().headers()['x-request-id'] }
    await new Promise((resolve) => setTimeout(resolve, 100))
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, order_no: 4321 }),
      headers: { 'access-control-allow-origin': '*' },
    })
  })

  await openPublicRoute(page, '/')
  await rentNow(page, 'Playwright Wheelchair')

  const drawer = page.getByRole('complementary')
  await drawer.getByRole('link', { name: 'Continue to checkout (1)' }).click()
  await expect(page).toHaveURL(/\/checkout$/)
  await page.getByText('In-store pickup', { exact: true }).click()
  await page.getByPlaceholder('Full name').fill('Repeat Customer')
  await page.getByPlaceholder('Phone').fill('5165550100')
  await page.getByPlaceholder('Email').fill('repeat@example.com')
  await page.getByRole('button', { name: 'Submit Request' }).dblclick()

  await expect(page.getByText('Request received: #4321', { exact: true })).toBeVisible()
  await expect(page.locator('main')).not.toContainText('please wait a moment before sending the rest')
  expect(submissions).toBe(1)
  // Migration 118: a key so a retry can't create a second order, and an ID that traces any failure.
  expect(sent.key).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  expect(sent.requestId).toMatch(/^[0-9a-f]{32}$/)
})

function savedCartItem(mode: 'rent' | 'purchase') {
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

/** A click before the page has hydrated does nothing, so retry until the cart has actually slid in. */
async function openCart(page: Page) {
  await expect(async () => {
    await page.getByRole('button', { name: 'Cart', exact: true }).click()
    await expect(page.getByRole('complementary')).toBeInViewport({ ratio: 1, timeout: 1000 })
  }).toPass()
}

test('the cart is narrow on a desktop and full width on a phone', async ({ page }) => {
  await mockCatalogReads(page)
  await page.setViewportSize({ width: 1440, height: 900 })
  await openPublicRoute(page, '/')
  await openCart(page)
  await expect.poll(async () => (await page.getByRole('complementary').boundingBox())?.width).toBe(380)
  await page.setViewportSize({ width: 390, height: 800 })
  await expect.poll(async () => (await page.getByRole('complementary').boundingBox())?.width).toBe(390)
})

test('checkout shows the items beside the form', async ({ page }) => {
  await mockCatalogReads(page)
  await page.addInitScript((item) => localStorage.setItem('cs_cart_v1', JSON.stringify([item])), savedCartItem('rent'))
  await openPublicRoute(page, '/checkout')
  const summary = page.getByRole('region', { name: 'Your order' })
  await expect(summary.getByText(catalog[0].name, { exact: true })).toBeVisible()
  await expect(summary.getByText('Due today', { exact: true })).toBeVisible()
  await expect(page.getByPlaceholder('Full name')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Checkout', exact: true })).toBeVisible()
})

// ── One payment for a rental and a purchase; Stripe cancel keeps the cart (128) ──
const ORDER = '4bd8b3c4-6012-4eac-8c42-49cc2d7edb28'
const PURCHASE_ORDER = '9a1f0c55-3e0b-4f7e-8d2a-6b1c2d3e4f50'
const FAKE_STRIPE = 'https://stripe.test/pay/cs_fake_1'
const CHECKOUT_RPCS = ['create_stripe_cart_checkout_once', 'create_stripe_rental_checkout_once', 'create_stripe_checkout_once', 'submit_rental_request_once'] as const

type RpcLog = { calls: () => number; bodies: () => Array<Record<string, unknown>> }

/** Answer one RPC with a reply (a function may change it between calls) and record what the page sent. */
async function mockRpc(page: Page, name: string, reply: unknown): Promise<RpcLog> {
  const bodies: Array<Record<string, unknown>> = []
  await page.route(`**/rest/v1/rpc/${name}`, async (route) => {
    if (route.request().method() === 'POST') bodies.push(route.request().postDataJSON() ?? {})
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(typeof reply === 'function' ? reply() : reply),
      headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' },
    })
  })
  return { calls: () => bodies.length, bodies: () => bodies }
}

/** Every order-placing RPC, answered with `reply` for the one expected and counted for all. */
async function mockCheckoutRpcs(page: Page, expected: (typeof CHECKOUT_RPCS)[number], reply: unknown) {
  const logs = {} as Record<(typeof CHECKOUT_RPCS)[number], RpcLog>
  for (const name of CHECKOUT_RPCS) {
    logs[name] = await mockRpc(page, name, name === expected ? reply : { ok: false, reason: 'unexpected_call' })
  }
  return logs
}

/** Stripe's page, without leaving the machine. */
async function mockStripePage(page: Page) {
  await page.route('https://stripe.test/**', (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>Fake Stripe</title><h1>Fake Stripe</h1>' }))
}

/** A cart of one kind is emptied at the redirect, exactly as before 128, and nothing is left pending. */
async function expectClearedLikeToday(page: Page) {
  await page.goto('/', { waitUntil: 'domcontentloaded' })
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('cs_cart_v1') || '[]').length)).toBe(0)
  expect(await page.evaluate(() => localStorage.getItem('cs_checkout_pending'))).toBeNull()
}

async function fillDelivery(page: Page) {
  await page.getByPlaceholder('Full name').fill('Pat Buyer')
  await page.getByPlaceholder('Phone').fill('5165550100')
  await page.getByPlaceholder('Email').fill('pat@example.com')
  await page.getByPlaceholder('Delivery address').fill('2 Oak St')
  await page.getByPlaceholder('City').fill('Melville')
  await page.getByPlaceholder('ZIP').fill('11747')
}

test('a rental and a purchase pay once through the combined call, and a Stripe cancel keeps the cart', async ({ page }) => {
  await mockCatalogReads(page)
  await mockStripePage(page)
  await mockRpc(page, 'quote_storefront_cart', { ok: true, method: 'delivery', prices: { [catalog[0].id]: 125 }, sale_prices: { [catalog[0].id]: 300 } })
  await mockRpc(page, 'verify_stripe_payment', { ok: true, paid: false, state: 'unpaid', order_ids: [ORDER, PURCHASE_ORDER] })
  const cancels = await mockRpc(page, 'cancel_stripe_checkout', { ok: true, paid: false, released: true })
  const rpcs = await mockCheckoutRpcs(page, 'create_stripe_cart_checkout_once', {
    ok: true, order_id: ORDER, order_no: 101, purchase_order_id: PURCHASE_ORDER, purchase_order_no: 102,
    order_ids: [ORDER, PURCHASE_ORDER], checkout_url: FAKE_STRIPE,
  })
  await page.addInitScript((items) => {
    if (sessionStorage.getItem('seeded')) return
    sessionStorage.setItem('seeded', '1')
    localStorage.setItem('cs_cart_v1', JSON.stringify(items))
  }, [savedCartItem('rent'), savedCartItem('purchase')])

  await openPublicRoute(page, '/checkout')
  await expect(page.getByText(/everything is paid online together/)).toBeVisible()
  await expect(page.getByText('Pay Delivery Person', { exact: true })).toHaveCount(0)
  const summary = page.getByRole('region', { name: 'Your order' })
  await expect(summary.getByText('$425', { exact: true })).toBeVisible()
  await fillDelivery(page)
  await page.getByRole('button', { name: 'Continue to Secure Payment' }).dblclick()
  await expect(page).toHaveURL(FAKE_STRIPE)

  expect(rpcs.create_stripe_cart_checkout_once.calls()).toBe(1)
  for (const name of ['create_stripe_rental_checkout_once', 'create_stripe_checkout_once', 'submit_rental_request_once'] as const) {
    expect(rpcs[name].calls(), `${name} is not used for a mixed cart`).toBe(0)
  }
  const sent = rpcs.create_stripe_cart_checkout_once.bodies()[0]
  expect(sent.p_rentals).toEqual([{ item_id: catalog[0].id, quantity: 1 }])
  expect(sent.p_purchases).toEqual([{ item_id: catalog[0].id, quantity: 1 }])
  expect(sent.p_notes).toBeNull()
  expect(sent.p_request_key).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  expect((sent.p_fulfillment as { payment_method?: string }).payment_method).toBe('online')

  // The cart is kept until Stripe confirms payment.
  await page.goto('/', { waitUntil: 'domcontentloaded' })
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('cs_cart_v1') || '[]').length)).toBe(2)
  expect(await page.evaluate(() => localStorage.getItem('cs_checkout_pending'))).toBe(ORDER)

  // Stripe's cancel link brings the customer back to checkout with everything intact.
  await openPublicRoute(page, `/checkout?cancelled=${ORDER}`)
  await expect(page.getByRole('status').filter({ hasText: 'Payment cancelled' })).toBeVisible()
  await expect(page).toHaveURL(/\/checkout$/)
  await expect(summary.getByText(catalog[0].name, { exact: true }).first()).toBeVisible()
  await expect(page.getByPlaceholder('Full name')).toHaveValue('Pat Buyer')
  await expect(page.getByPlaceholder('ZIP')).toHaveValue('11747')
  expect(cancels.calls()).toBe(1)
  expect(cancels.bodies()[0]).toEqual({ p_order_id: ORDER })
  await expect.poll(() => page.evaluate(() => localStorage.getItem('cs_checkout_pending'))).toBeNull()
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('cs_cart_v1') || '[]').length)).toBe(2)
})

test('coming back to a combined payment that was paid goes to the confirmation, not a second order', async ({ page }) => {
  await mockCatalogReads(page)
  await mockRpc(page, 'cancel_stripe_checkout', { ok: true, paid: true, released: false })
  await mockRpc(page, 'verify_stripe_payment', { ok: true, paid: true, order_ids: [ORDER, PURCHASE_ORDER] })
  const emails = await mockRpc(page, 'dispatch_order_emails', { ok: true })
  await page.addInitScript(({ items, order }) => {
    if (sessionStorage.getItem('seeded')) return
    sessionStorage.setItem('seeded', '1')
    localStorage.setItem('cs_cart_v1', JSON.stringify(items))
    localStorage.setItem('cs_checkout_pending', order)
  }, { items: [savedCartItem('rent'), savedCartItem('purchase')], order: ORDER })
  await openPublicRoute(page, '/checkout')
  await expect(page).toHaveURL(new RegExp(`/checkout/success\\?ref=${ORDER}$`))
  await expect(page.getByRole('heading', { name: /Payment received/ })).toBeVisible()
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('cs_cart_v1') || '[]').length)).toBe(0)
  await expect.poll(() => page.evaluate(() => localStorage.getItem('cs_checkout_pending'))).toBeNull()
  // Each order on the payment gets its own mail.
  await expect.poll(() => emails.bodies().map((b) => b.p_order_id).sort()).toEqual([ORDER, PURCHASE_ORDER].sort())
})

test('a rental-only cart paid online still uses today’s rental call', async ({ page }) => {
  await mockCatalogReads(page)
  await mockStripePage(page)
  const rpcs = await mockCheckoutRpcs(page, 'create_stripe_rental_checkout_once', { ok: true, order_id: ORDER, order_no: 101, checkout_url: FAKE_STRIPE })
  await openPublicRoute(page, '/')
  await rentNow(page, 'Playwright Wheelchair')
  await page.getByRole('complementary').getByRole('link', { name: 'Continue to checkout (1)' }).click()
  await expect(page).toHaveURL(/\/checkout$/)
  await expect(page.getByText(/everything is paid online together/)).toHaveCount(0)
  await page.getByText('Pay Online', { exact: true }).click()
  await fillDelivery(page)
  await page.getByRole('button', { name: 'Continue to Secure Payment' }).click()
  await expect(page).toHaveURL(FAKE_STRIPE)
  expect(rpcs.create_stripe_rental_checkout_once.calls()).toBe(1)
  expect(rpcs.create_stripe_cart_checkout_once.calls()).toBe(0)
  expect(rpcs.create_stripe_checkout_once.calls()).toBe(0)
  expect(Object.keys(rpcs.create_stripe_rental_checkout_once.bodies()[0]).sort())
    .toEqual(['p_address', 'p_customer', 'p_fulfillment', 'p_items', 'p_notes', 'p_redirect_base', 'p_request_key'])
  await expectClearedLikeToday(page)
})

test('a purchase-only cart still uses today’s purchase call, with no pay-later choice', async ({ page }) => {
  await mockCatalogReads(page)
  await mockStripePage(page)
  const rpcs = await mockCheckoutRpcs(page, 'create_stripe_checkout_once', { ok: true, order_id: ORDER, order_no: 101, checkout_url: FAKE_STRIPE })
  await page.addInitScript((item) => {
    if (sessionStorage.getItem('seeded')) return
    sessionStorage.setItem('seeded', '1')
    localStorage.setItem('cs_cart_v1', JSON.stringify([item]))
  }, savedCartItem('purchase'))
  await openPublicRoute(page, '/checkout')
  await expect(page.getByText('Pay Delivery Person', { exact: true })).toHaveCount(0)
  await expect(page.getByText(/everything is paid online together/)).toHaveCount(0)
  await fillDelivery(page)
  await page.getByRole('button', { name: 'Continue to Secure Payment' }).click()
  await expect(page).toHaveURL(FAKE_STRIPE)
  expect(rpcs.create_stripe_checkout_once.calls()).toBe(1)
  expect(rpcs.create_stripe_cart_checkout_once.calls()).toBe(0)
  expect(rpcs.create_stripe_rental_checkout_once.calls()).toBe(0)
  expect(Object.keys(rpcs.create_stripe_checkout_once.bodies()[0]).sort())
    .toEqual(['p_address', 'p_customer', 'p_fulfillment', 'p_items', 'p_redirect_base', 'p_request_key'])
  await expectClearedLikeToday(page)
})

test('if a cancelled combined payment can’t be closed in Stripe, no second payment can start until it is', async ({ page }) => {
  await mockCatalogReads(page)
  await mockRpc(page, 'verify_stripe_payment', { ok: true, paid: false, state: 'unpaid', order_ids: [ORDER, PURCHASE_ORDER] })
  let stripeUp = false
  const cancels = await mockRpc(page, 'cancel_stripe_checkout', () => stripeUp ? { ok: true, paid: false, released: true } : { ok: false, reason: 'stripe_unreachable' })
  const rpcs = await mockCheckoutRpcs(page, 'create_stripe_cart_checkout_once', { ok: false, reason: 'unexpected_call' })
  await page.addInitScript(({ items, order }) => {
    if (sessionStorage.getItem('seeded')) return
    sessionStorage.setItem('seeded', '1')
    localStorage.setItem('cs_cart_v1', JSON.stringify(items))
    localStorage.setItem('cs_checkout_pending', order)
  }, { items: [savedCartItem('rent'), savedCartItem('purchase')], order: ORDER })
  await openPublicRoute(page, `/checkout?cancelled=${ORDER}`)
  const status = page.getByRole('status').filter({ hasText: 'couldn’t close your last payment attempt' })
  await expect(status).toBeVisible()
  await expect(page.getByRole('button', { name: 'Continue to Secure Payment' })).toBeDisabled()
  expect(await page.evaluate(() => localStorage.getItem('cs_checkout_pending'))).toBe(ORDER)

  stripeUp = true
  await status.getByRole('button', { name: 'Try again' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Payment cancelled' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Continue to Secure Payment' })).toBeEnabled()
  await expect.poll(() => page.evaluate(() => localStorage.getItem('cs_checkout_pending'))).toBeNull()
  expect(cancels.calls()).toBe(2)
  expect(rpcs.create_stripe_cart_checkout_once.calls()).toBe(0)
})

test('an empty cart at checkout says so', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/checkout')
  await expect(page.getByRole('heading', { name: 'Your cart is empty' })).toBeVisible()
})

test('public links use client navigation and support browser history', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')
  await page.evaluate(() => {
    ;(window as Window & { __playwrightNavigationMarker?: string }).__playwrightNavigationMarker =
      'preserved'
  })

  await page.locator('header').getByRole('link', { name: 'How It Works' }).click()
  await expect(page).toHaveURL(/\/how-it-works$/)
  await expect(
    page.getByRole('heading', { level: 1, name: /On-Demand.*Order Now.*Use Today/i }),
  ).toBeVisible()
  expect(
    await page.evaluate(
      () =>
        (window as Window & { __playwrightNavigationMarker?: string })
          .__playwrightNavigationMarker,
    ),
  ).toBe('preserved')

  await page.goBack()
  await expect(page).toHaveURL(/\/$/)
  await expect(
    page.getByRole('heading', {
      level: 1,
      name: /Home medical equipment.*delivered the same day/i,
    }),
  ).toBeVisible()

  await page.goForward()
  await expect(page).toHaveURL(/\/how-it-works$/)
  await expect(
    page.getByRole('heading', { level: 1, name: /On-Demand.*Order Now.*Use Today/i }),
  ).toBeVisible()
})

test('an anonymous visitor is redirected away from a protected route', async ({ page }) => {
  await page.goto('/admin', { waitUntil: 'domcontentloaded' })
  await page.waitForURL((url) => url.pathname === '/admin-login')

  await expect(page).toHaveURL(/\/admin-login(?:\?.*)?$/)
  await expect(page.getByRole('heading', { name: 'Sign In' })).toBeVisible()
})
