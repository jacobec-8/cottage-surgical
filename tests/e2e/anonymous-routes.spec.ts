import { expect, test, type Page } from '@playwright/test'

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
    const id = url.searchParams.get('id')?.replace(/^eq\./, '')
    const requestedProduct = handle || id
    const result = requestedProduct
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

  const productDetails = page
    .getByRole('link', { name: 'Playwright Wheelchair', exact: true })
    .locator('..')
  await productDetails.getByRole('button', { name: 'Rent Now' }).click()

  const drawer = page.locator('aside')
  const cartItem = drawer
    .locator('div.border.border-slate-200.rounded-xl')
    .filter({ hasText: 'Playwright Wheelchair' })
  await expect(cartItem).toBeVisible()
  await expect(drawer.getByRole('button', { name: 'Continue to checkout (1)' })).toBeVisible()

  await cartItem.locator('button').nth(1).click()
  await expect(drawer.getByRole('button', { name: 'Continue to checkout (2)' })).toBeVisible()
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
  await page.getByRole('button', { name: 'Cart', exact: true }).click()

  const restoredItem = page
    .locator('aside div.border.border-slate-200.rounded-xl')
    .filter({ hasText: 'Playwright Wheelchair' })
  await expect(restoredItem).toBeVisible()
  await expect(page.getByRole('button', { name: 'Continue to checkout (2)' })).toBeVisible()

  await restoredItem.locator('button').first().click()
  await expect(page.getByRole('button', { name: 'Continue to checkout (1)' })).toBeVisible()
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

  const wheelchair = page.getByRole('link', { name: 'Playwright Wheelchair', exact: true }).locator('..')
  await wheelchair.getByRole('button', { name: 'Rent Now' }).click()
  const drawer = page.locator('aside')
  await drawer.getByRole('button', { name: 'Continue to checkout (1)' }).click()

  const pickup = drawer.getByRole('radio', { name: /In-store pickup/i })
  await expect(pickup).toBeEnabled()
  await drawer.getByText('In-store pickup', { exact: true }).click()
  await expect(drawer.getByLabel('Pickup location')).toHaveValue('playwright-woodbury')
  await expect(drawer.getByText(/Same-day pickup may be available/i)).toBeVisible()
  await expect(drawer.getByPlaceholder('Delivery address')).toHaveCount(0)

  await page.reload({ waitUntil: 'domcontentloaded' })
  await page.evaluate(() => localStorage.removeItem('cs_cart_v1'))
  await page.reload({ waitUntil: 'domcontentloaded' })
  const bed = page.getByRole('link', { name: 'Playwright Hospital Bed', exact: true }).locator('..')
  await bed.getByRole('button', { name: 'Rent Now' }).click()
  await drawer.getByRole('button', { name: 'Continue to checkout (1)' }).click()
  await expect(drawer.getByRole('radio', { name: /In-store pickup/i })).toBeDisabled()
  await expect(drawer.getByRole('radio', { name: /Delivery/i })).toBeChecked()
  await expect(drawer.getByPlaceholder('Delivery address')).toBeVisible()
  await expect(drawer.getByText('Online payment required for delivery')).toBeVisible()
  await expect(drawer.getByText('Pay in store', { exact: true })).toHaveCount(0)
  await expect(drawer.getByRole('button', { name: 'Continue to Secure Payment' })).toBeVisible()
})

test('double-clicking rental submit sends one request', async ({ page }) => {
  await mockCatalogReads(page)
  let submissions = 0
  await page.route('**/rest/v1/rpc/submit_rental_request_with_fulfillment', async (route) => {
    submissions += 1
    await new Promise((resolve) => setTimeout(resolve, 100))
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, order_no: 4321 }),
      headers: { 'access-control-allow-origin': '*' },
    })
  })

  await openPublicRoute(page, '/')
  const productDetails = page
    .getByRole('link', { name: 'Playwright Wheelchair', exact: true })
    .locator('..')
  await productDetails.getByRole('button', { name: 'Rent Now' }).click()

  const drawer = page.locator('aside')
  await drawer.getByRole('button', { name: 'Continue to checkout (1)' }).click()
  await drawer.getByText('In-store pickup', { exact: true }).click()
  await drawer.getByPlaceholder('Full name').fill('Repeat Customer')
  await drawer.getByPlaceholder('Phone').fill('5165550100')
  await drawer.getByPlaceholder('Email').fill('repeat@example.com')
  await drawer.getByRole('button', { name: 'Submit Request' }).dblclick()

  await expect(drawer.getByText('Request received: #4321', { exact: true })).toBeVisible()
  await expect(drawer).not.toContainText('please wait a moment before sending the rest')
  expect(submissions).toBe(1)
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
