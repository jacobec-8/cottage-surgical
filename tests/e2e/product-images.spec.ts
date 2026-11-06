import { expect, test } from '@playwright/test'
import { catalog, mockCatalogReads, openPublicRoute } from './publicFixture'

// A tall product photo must not stretch its box: cards in a row line up whatever the photo's shape.
const svg = (w: number, h: number) => `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" fill="#888"/></svg>`)}`

test('catalog cards keep a 4:3 photo box for a tall photo and a wide one', async ({ page }) => {
  await mockCatalogReads(page, [{ ...catalog[0], image_url: svg(300, 1200) }, { ...catalog[1], image_url: svg(1200, 300) }])
  await openPublicRoute(page, '/')
  const box = async (name: string) => page.locator('#favorites').getByRole('img', { name, exact: true }).locator('xpath=ancestor::a[1]').boundingBox()
  const tall = await box('Playwright Wheelchair'), wide = await box('Playwright Hospital Bed')
  expect(Math.round(tall!.height)).toBe(Math.round(tall!.width * 3 / 4))
  expect(Math.round(wide!.height)).toBe(Math.round(tall!.height))
})
