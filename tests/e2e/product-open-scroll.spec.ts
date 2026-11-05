import { expect, test } from '@playwright/test'
import { mockCatalogReads, openPublicRoute } from './publicFixture'

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test('opening a product from the grid starts at the top of its page', async ({ page }) => {
    await mockCatalogReads(page)
    await openPublicRoute(page, '/')
    const card = page.locator('#favorites').getByRole('link', { name: 'Playwright Hospital Bed', exact: true })
    await card.scrollIntoViewIfNeeded()
    await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(800)
    await card.tap()
    await expect(page).toHaveURL(/\/product\//)
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
    await page.waitForTimeout(800)
    const where = await page.evaluate(() => ({ y: window.scrollY, max: document.documentElement.scrollHeight - window.innerHeight }))
    console.log('scroll after open', JSON.stringify(where))
    expect(where.y).toBeLessThan(50)
  })
})

test('a product page opens at its top even when the router keeps the old scroll', async ({ page }) => {
  // Some phone browsers keep the grid's scroll on the way in; this navigation does the same.
  await page.setViewportSize({ width: 390, height: 844 })
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')
  const href = await page.locator('#favorites a[href^="/product/"]').first().getAttribute('href')
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(800)
  await page.evaluate((to) => (window as unknown as { next: { router: { push: (h: string, o: { scroll: boolean }) => void } } }).next.router.push(to!, { scroll: false }), href)
  await expect(page).toHaveURL(/\/product\//)
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeLessThan(50)
})
