import { expect, test, type Page } from '@playwright/test'
import { mockCatalogReads, openPublicRoute } from './publicFixture'

const buyBox = (page: Page) => page.getByRole('complementary', { name: 'Rent or buy' })

/** A click before hydration does nothing; retry until the cart drawer shows the item. */
async function addToCartHydrated(page: Page, name: string) {
  await expect(async () => {
    await buyBox(page).getByRole('button', { name: 'Add to cart' }).click()
    await expect(page.getByRole('link', { name: /Continue to checkout/ })).toBeVisible({ timeout: 1000 })
  }).toPass()
  await expect(page.getByText(name, { exact: true }).last()).toBeVisible()
}

test('a delivery-only rental shows its promises, details and how renting works', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/product/playwright-hospital-bed')
  await expect(page.getByRole('heading', { level: 1, name: 'Playwright Hospital Bed' })).toBeVisible()
  await expect(page.getByText('Includes delivery, setup and return pickup')).toBeVisible()
  for (const badge of ['Same-day delivery', 'Set up for you', 'Free repairs', 'Month-to-month']) {
    await expect(page.getByText(badge, { exact: true })).toBeVisible()
  }
  await expect(page.getByRole('heading', { name: 'About this item' })).toBeVisible()
  await expect(page.getByText('Read-only browser-test fixture.')).toBeVisible()
  await expect(buyBox(page).getByText('$275', { exact: true })).toBeVisible() // desktop: the box repeats the price
  await expect(buyBox(page).getByRole('status')).toHaveText('In stock')
  await expect(buyBox(page).getByText('Our technicians')).toBeVisible()
  await expect(buyBox(page).getByText('Pick up at')).toHaveCount(0)

  await expect(page.getByRole('heading', { name: 'How renting works' })).toBeVisible()
  await expect(page.getByText(/delivered the same day across Nassau and Suffolk/)).toBeVisible()
  await page.getByText('What is the minimum rental period?').click()
  await expect(page.getByText(/One month\. After that, rentals continue month-to-month/)).toBeVisible()
})

test('a pickup-and-delivery rental shows both prices and its store', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/product/playwright-wheelchair')
  await expect(page.getByText('Same price if you pick it up in store')).toBeVisible()
  await expect(page.getByText('Rented by the month, delivered to your home')).toBeVisible()
  await expect(buyBox(page).getByText('Woodbury Store')).toBeVisible()
  await expect(page.getByText('No assembly', { exact: true })).toBeVisible()
})

test('Add to cart opens the cart; Rent now goes straight to checkout', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/product/playwright-hospital-bed')
  await addToCartHydrated(page, 'Playwright Hospital Bed')
  await page.keyboard.press('Escape')
  await page.goto('/product/playwright-wheelchair')
  await expect(async () => {
    await buyBox(page).getByRole('button', { name: 'Rent now' }).click()
    await expect(page).toHaveURL(/\/checkout$/, { timeout: 1500 })
  }).toPass()
  await expect(page.getByText('Playwright Wheelchair').first()).toBeVisible()
})

test('the breadcrumb category opens the catalog filtered to it', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/product/playwright-hospital-bed')
  await page.getByRole('navigation', { name: 'Breadcrumb' }).getByRole('link', { name: 'beds' }).click()
  await expect(page).toHaveURL(/\/\?cat=beds$/)
  await expect(page.locator('#favorites').getByRole('link', { name: 'Playwright Hospital Bed', exact: true })).toBeVisible()
  await expect(page.locator('#favorites').getByRole('link', { name: 'Playwright Wheelchair', exact: true })).toBeHidden()
})

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('a link to the rent button lands on it, not the top', async ({ page }) => {
    await mockCatalogReads(page)
    await openPublicRoute(page, '/product/playwright-wheelchair#rent-equipment')
    await expect(page.locator('#rent-equipment')).toBeInViewport()
    expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(200)
  })
})
