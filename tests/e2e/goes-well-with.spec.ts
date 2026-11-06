import { expect, test, type Page } from '@playwright/test'
import { catalog, mockCatalogReads, mockPairings, openPublicRoute } from './publicFixture'

const showerChair = {
  ...catalog[1], id: 'playwright-retail-1', name: 'Playwright Shower Chair', category: 'seating',
  monthly_rental_price: null, pickup_rental_price: null, delivery_rental_price: null, sale_price: 49.99,
  shopify_handle: 'playwright-shower-chair', is_rentable: false, is_purchasable: true, can_buy: true, in_stock: true,
}
const soldOutLift = { ...catalog[1], id: 'playwright-lift-1', name: 'Playwright Patient Lift', shopify_handle: 'playwright-patient-lift', in_stock: false }
const products = [...catalog, showerChair, soldOutLift]
const bedPicks = [
  { equipment_item_id: 'playwright-bed-1', paired_item_id: 'playwright-lift-1', position: 1 },
  { equipment_item_id: 'playwright-bed-1', paired_item_id: 'playwright-wheelchair-1', position: 2 },
  { equipment_item_id: 'playwright-bed-1', paired_item_id: 'playwright-retail-1', position: 3 },
]

const pageSuggestions = (page: Page) => page.locator('main').getByRole('region', { name: 'Goes well with' })
const cart = (page: Page) => page.locator('aside').filter({ hasText: 'Your Cart' })

test('the product page shows what goes with it: in stock only, in the picked order, each with Add and a link', async ({ page }) => {
  await mockCatalogReads(page, products)
  await mockPairings(page, bedPicks)
  await openPublicRoute(page, '/product/playwright-hospital-bed')

  const section = pageSuggestions(page)
  await expect(section.getByRole('link', { name: 'Playwright Wheelchair', exact: true })).toBeVisible()
  await expect(section.getByRole('listitem')).toHaveCount(2)
  await expect(section.getByRole('listitem').first()).toContainText('Playwright Wheelchair')
  await expect(section).not.toContainText('Playwright Patient Lift')
  await expect(section.getByText('$49.99 to purchase')).toBeVisible()
  await expect(section.getByRole('link', { name: 'Playwright Shower Chair', exact: true })).toHaveAttribute('href', '/product/playwright-shower-chair')

  // A click before hydration does nothing; retry until the cart shows it.
  await expect(async () => {
    await section.getByRole('button', { name: 'Buy Playwright Shower Chair: add to cart' }).click()
    await expect(cart(page).getByText('Playwright Shower Chair', { exact: true }).first()).toBeVisible({ timeout: 1000 })
  }).toPass()
  await expect(cart(page).getByText('Buy', { exact: true }).first()).toBeVisible()
})

test('the cart suggests picks for what is in it, never what is already there', async ({ page }) => {
  await mockCatalogReads(page, products)
  await mockPairings(page, bedPicks)
  await openPublicRoute(page, '/product/playwright-hospital-bed')
  await expect(async () => {
    await page.getByRole('complementary', { name: 'Rent or buy' }).getByRole('button', { name: 'Add to cart' }).click()
    await expect(page.getByRole('link', { name: /Continue to checkout/ })).toBeVisible({ timeout: 1000 })
  }).toPass()

  const suggested = cart(page).getByRole('region', { name: 'Goes well with' })
  await expect(suggested.getByRole('listitem')).toHaveCount(2)
  await suggested.getByRole('button', { name: 'Rent Playwright Wheelchair: add to cart' }).click()
  await expect(suggested.getByRole('listitem')).toHaveCount(1)
  await expect(suggested).toContainText('Playwright Shower Chair')
  await expect(page.getByRole('link', { name: 'Continue to checkout (2)' })).toBeVisible()

  await suggested.getByRole('link', { name: 'Playwright Shower Chair' }).click()
  await expect(page).toHaveURL(/\/product\/playwright-shower-chair$/)
})

test('nothing picked, nothing shown', async ({ page }) => {
  await mockCatalogReads(page, products)
  await mockPairings(page, [])
  await openPublicRoute(page, '/product/playwright-hospital-bed')
  await expect(page.getByRole('heading', { level: 1, name: 'Playwright Hospital Bed' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Goes well with' })).toHaveCount(0)
})

const svg = (w: number, h: number) => `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" fill="#888"/></svg>`)}`

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('a tall photo and a wide photo get the same square box, so the cards line up', async ({ page }) => {
    const pictured = products.map((p) =>
      p.id === 'playwright-wheelchair-1' ? { ...p, image_url: svg(300, 1200) }
        : p.id === 'playwright-retail-1' ? { ...p, image_url: svg(1200, 300) } : p)
    await mockCatalogReads(page, pictured)
    await mockPairings(page, bedPicks)
    await openPublicRoute(page, '/product/playwright-hospital-bed')

    const boxes = pageSuggestions(page).getByRole('listitem').locator('a:has(img)')
    await expect(boxes).toHaveCount(2)
    const [tall, wide] = [await boxes.nth(0).boundingBox(), await boxes.nth(1).boundingBox()]
    expect(Math.round(tall!.height)).toBe(Math.round(tall!.width))
    expect(Math.round(wide!.height)).toBe(Math.round(tall!.height))
  })
})
