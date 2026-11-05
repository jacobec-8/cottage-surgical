import { expect, test, type Page } from '@playwright/test'
import { mockCatalogReads, openPublicRoute } from './publicFixture'

const WHEELCHAIR = 'Playwright Wheelchair'
const BED = 'Playwright Hospital Bed'

const grid = (page: Page) => page.locator('#favorites')
const card = (page: Page, name: string) => grid(page).getByRole('link', { name, exact: true })
const chip = (page: Page, name: string) =>
  grid(page).getByRole('group', { name: 'Filter by category' }).getByRole('button', { name: new RegExp(`^${name}$`, 'i') })
const filterBox = (page: Page) => page.getByRole('textbox', { name: 'Filter equipment…' })
const noMatch = (page: Page) => grid(page).getByText(/^No equipment matches/)

/** Bring a category tile to the middle of the carousel (only that one is a link), then open it. */
async function openTile(page: Page, label: string) {
  const carousel = page.getByRole('region', { name: 'Shop by category' })
  await carousel.getByRole('button', { name: `Show ${label}` }).click()
  await carousel.getByRole('link', { name: new RegExp(label) }).click()
}

/** A click before hydration does nothing; retry until a chip visibly takes effect. */
async function openHydratedShop(page: Page) {
  await page.emulateMedia({ reducedMotion: 'reduce' }) // keeps the category ring still
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(async () => {
    await chip(page, 'mobility').click()
    await expect(chip(page, 'mobility')).toHaveAttribute('aria-pressed', 'true', { timeout: 1000 })
  }).toPass()
  await chip(page, 'All').click()
  await expect(card(page, BED)).toBeVisible()
}

test('a category tile and then a category chip shows that category, not an empty grid', async ({ page }) => {
  await openHydratedShop(page)

  await openTile(page, 'Hospital Beds')
  await expect(filterBox(page)).toHaveValue('bed')
  await expect(card(page, BED)).toBeVisible()
  await expect(card(page, WHEELCHAIR)).toBeHidden()
  await expect.poll(() => new URL(page.url()).searchParams.get('q')).toBe('bed')

  await chip(page, 'mobility').click()
  await expect(chip(page, 'mobility')).toHaveAttribute('aria-pressed', 'true')
  await expect(filterBox(page)).toHaveValue('')
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(card(page, BED)).toBeHidden()
  await expect(noMatch(page)).toBeHidden()
})

test('a category chip and then a tile shows the tile’s equipment', async ({ page }) => {
  await openHydratedShop(page)

  await chip(page, 'beds').click()
  await expect(card(page, BED)).toBeVisible()
  await expect(card(page, WHEELCHAIR)).toBeHidden()

  await openTile(page, 'Wheelchairs')
  await expect(filterBox(page)).toHaveValue('wheelchair')
  await expect(chip(page, 'All')).toHaveAttribute('aria-pressed', 'true')
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(card(page, BED)).toBeHidden()
  await expect(noMatch(page)).toBeHidden()
})

test('the same tile works again after the search box was cleared', async ({ page }) => {
  await openHydratedShop(page)

  await openTile(page, 'Wheelchairs')
  await expect(filterBox(page)).toHaveValue('wheelchair')
  await filterBox(page).fill('')
  await expect(card(page, BED)).toBeVisible()

  await openTile(page, 'Wheelchairs')
  await expect(filterBox(page)).toHaveValue('wheelchair')
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(card(page, BED)).toBeHidden()
})

test('typed words stay visible beside the chips, and the empty state offers a way out', async ({ page }) => {
  await openHydratedShop(page)

  await filterBox(page).fill('wheelchair')
  await chip(page, 'beds').click()
  await expect(filterBox(page)).toHaveValue('wheelchair')
  await expect(grid(page).getByRole('button', { name: 'Clear search “wheelchair”' })).toBeVisible()
  await expect(noMatch(page)).toHaveText('No equipment matches “wheelchair” in beds.')

  await grid(page).getByRole('button', { name: 'Show all equipment' }).click()
  await expect(filterBox(page)).toHaveValue('')
  await expect(chip(page, 'All')).toHaveAttribute('aria-pressed', 'true')
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(card(page, BED)).toBeVisible()

  await filterBox(page).fill('wheelchair')
  await chip(page, 'beds').click()
  await grid(page).getByRole('button', { name: 'Clear search' , exact: true }).click()
  await expect(filterBox(page)).toHaveValue('')
  await expect(card(page, BED)).toBeVisible()
  await expect(chip(page, 'beds')).toHaveAttribute('aria-pressed', 'true')
})
