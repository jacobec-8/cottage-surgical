import { expect, test, type Page } from '@playwright/test'
import { mockCatalogReads, openPublicRoute, savedCartItem } from './publicFixture'

// A phone: the order summary sits above the form, so most of checkout starts below the screen.
test.use({ viewport: { width: 390, height: 700 } })

async function phoneCheckout(page: Page) {
  await mockCatalogReads(page)
  await page.addInitScript((item) => {
    if (sessionStorage.getItem('seeded')) return
    sessionStorage.setItem('seeded', '1')
    localStorage.setItem('cs_cart_v1', JSON.stringify([item]))
  }, savedCartItem('rent'))
  await openPublicRoute(page, '/checkout')
  await expect(page.getByRole('heading', { name: 'Checkout', exact: true })).toBeVisible()
}

/** Scrolls so the choice cards sit at the very bottom of the screen, with what they open below it. */
async function choicesAtBottom(page: Page) {
  await page.getByText('How would you like to receive your order?').evaluate((legend) => {
    const cards = legend.parentElement!.getBoundingClientRect()
    window.scrollBy(0, cards.bottom - window.innerHeight + 4)
  })
}

test('choosing pickup brings the store choice into view', async ({ page }) => {
  await phoneCheckout(page)
  await choicesAtBottom(page)
  await expect(page.getByPlaceholder('Delivery address')).not.toBeInViewport()

  // A tap before hydration does nothing; retry until pickup is chosen.
  await expect(async () => {
    await page.getByText('In-store pickup', { exact: true }).click()
    await expect(page.getByLabel('Pickup location')).toBeAttached({ timeout: 1000 })
  }).toPass()
  await expect(page.getByLabel('Pickup location')).toBeInViewport({ ratio: 1 })
})

test('choosing delivery brings the address fields into view', async ({ page }) => {
  await phoneCheckout(page)
  await expect(async () => {
    await page.getByText('In-store pickup', { exact: true }).click()
    await expect(page.getByLabel('Pickup location')).toBeAttached({ timeout: 1000 })
  }).toPass()
  await choicesAtBottom(page)
  await expect(page.getByLabel('Pickup location')).not.toBeInViewport()

  await page.getByText('Delivered to your address.', { exact: true }).click()
  await expect(page.getByPlaceholder('ZIP')).toBeInViewport({ ratio: 1 })
})

test('a sent request opens at the top, not on the footer', async ({ page }) => {
  await page.route('**/rest/v1/rpc/submit_rental_request_once', (route) => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({ ok: true, order_no: 4330 }),
    headers: { 'access-control-allow-origin': '*' },
  }))
  await phoneCheckout(page)
  await expect(async () => {
    await page.getByText('In-store pickup', { exact: true }).click()
    await expect(page.getByLabel('Pickup location')).toBeAttached({ timeout: 1000 })
  }).toPass()
  await page.getByPlaceholder('Full name').fill('Scroll Customer')
  await page.getByPlaceholder('Phone').fill('5165550100')
  await page.getByPlaceholder('Email').fill('scroll@example.com')
  await page.getByRole('button', { name: 'Submit Request' }).click()

  await expect(page.getByRole('heading', { name: 'Request received: #4330' })).toBeInViewport({ ratio: 1 })
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0)
})

test('with motion turned off, it jumps straight there', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await phoneCheckout(page)
  await choicesAtBottom(page)
  await expect(async () => {
    await page.getByText('In-store pickup', { exact: true }).click()
    await expect(page.getByLabel('Pickup location')).toBeAttached({ timeout: 1000 })
  }).toPass()
  // No glide to wait for: two frames after the tap it's already in place.
  await expect(page.getByLabel('Pickup location')).toBeInViewport({ ratio: 1, timeout: 500 })
})
