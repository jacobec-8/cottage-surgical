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
