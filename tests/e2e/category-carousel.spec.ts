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

test('each photo stays inside its box, above the tile’s name', async ({ page }) => {
  // A tall stand-in photo: an uncapped image would spill over the name.
  await page.route('https://cdn.shopify.com/**', (route) => route.fulfill({
    contentType: 'image/svg+xml',
    body: '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="600"><rect width="300" height="600" fill="#888"/></svg>',
  }))
  await openHydratedCarousel(page)
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 })
    const tile = middleLink(page)
    const photo = await tile.locator('img').boundingBox()
    const name = await tile.getByText('Hospital Beds', { exact: true }).boundingBox()
    expect(photo && name).toBeTruthy()
    expect(photo!.y + photo!.height).toBeLessThanOrEqual(name!.y)
  }
})
