import { expect, test, type Page } from '@playwright/test'
import { mockCatalogReads, openPublicRoute } from './publicFixture'

const carousel = (page: Page) => page.getByRole('region', { name: 'Shop by category' })
const middleLink = (page: Page) => carousel(page).getByRole('link')

async function openHydratedCarousel(page: Page) {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')
  await expect(middleLink(page)).toHaveCount(1)
  // A click before hydration does nothing; retry until the arrow visibly moves the ring.
  await expect(async () => {
    await carousel(page).getByRole('button', { name: 'Next category' }).click()
    await expect(middleLink(page)).toContainText('Hospital Beds', { timeout: 1000 })
  }).toPass()
}

test('the arrows loop the ring and only the middle tile is a link', async ({ page }) => {
  await openHydratedCarousel(page)
  await carousel(page).getByRole('button', { name: 'Previous category' }).click()
  await expect(middleLink(page)).toContainText('Wheelchairs')
  await carousel(page).getByRole('button', { name: 'Previous category' }).click()
  await expect(middleLink(page)).toContainText('Oxygen')
  await expect(middleLink(page)).toHaveCount(1)
  await expect(carousel(page).getByRole('button', { name: 'Show Oxygen' })).toHaveAttribute('aria-current', 'true')
})

test('clicking a side tile brings it to the middle instead of opening it', async ({ page }) => {
  await openHydratedCarousel(page)
  const box = await carousel(page).locator('a[aria-hidden="true"]', { hasText: 'Knee Walkers' }).boundingBox()
  expect(box).not.toBeNull()
  await page.mouse.click(box!.x + box!.width / 2, box!.y + box!.height / 2)
  await expect(middleLink(page)).toContainText('Knee Walkers')
  expect(new URL(page.url()).searchParams.get('q')).toBeNull()
})

test('the keyboard arrows move the ring', async ({ page }) => {
  await openHydratedCarousel(page)
  await middleLink(page).focus()
  await page.keyboard.press('ArrowRight')
  await expect(middleLink(page)).toContainText('Knee Walkers')
  await page.keyboard.press('ArrowLeft')
  await expect(middleLink(page)).toContainText('Hospital Beds')
})
