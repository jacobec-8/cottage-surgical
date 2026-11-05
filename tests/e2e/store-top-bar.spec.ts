import { expect, test, type Page } from '@playwright/test'
import { mockCatalogReads, openPublicRoute } from './publicFixture'

const WHEELCHAIR = 'Playwright Wheelchair'
const BED = 'Playwright Hospital Bed'

const bar = (page: Page) => page.getByRole('banner')
const topSearch = (page: Page) => bar(page).getByRole('search').filter({ visible: true })
const grid = (page: Page) => page.locator('#favorites')
const card = (page: Page, name: string) => grid(page).getByRole('link', { name, exact: true })
const chip = (page: Page, name: string) =>
  grid(page).getByRole('group', { name: 'Filter by category' }).getByRole('button', { name: new RegExp(`^${name}$`, 'i') })

/** Search from the top bar, retrying until hydration lets the submit reach the app. */
async function searchFromBar(page: Page, words: string, cat?: string, expectUrl?: RegExp) {
  await expect(async () => {
    if (cat) await topSearch(page).getByRole('combobox', { name: 'Search in' }).selectOption(cat)
    await topSearch(page).getByRole('textbox', { name: 'Search equipment' }).fill(words)
    await topSearch(page).getByRole('button', { name: 'Search' }).click()
    if (expectUrl) await expect(page).toHaveURL(expectUrl, { timeout: 1500 })
  }).toPass()
}

test('the top bar searches inside the picked category on the landing page', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/')
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(topSearch(page).getByRole('option', { name: 'beds' })).toBeAttached()

  await searchFromBar(page, 'Playwright', 'beds', /[?&]cat=beds/)
  await expect(page).toHaveURL(/[?&]q=Playwright/)
  await expect(card(page, BED)).toBeVisible()
  await expect(card(page, WHEELCHAIR)).toBeHidden()
  await expect(chip(page, 'beds')).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByRole('textbox', { name: 'Filter equipment…' })).toHaveValue('Playwright')
})

test('the top bar search from another page opens the matching equipment', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/faq')
  await searchFromBar(page, 'wheelchair', undefined, /\/\?q=wheelchair$/)
  await expect(card(page, WHEELCHAIR)).toBeVisible()
  await expect(card(page, BED)).toBeHidden()
})

test('the second row links the quick categories and the info pages', async ({ page }) => {
  await mockCatalogReads(page)
  await openPublicRoute(page, '/faq')
  const shopNav = page.getByRole('navigation', { name: 'Shop' })
  await shopNav.getByRole('link', { name: 'Hospital Beds' }).click()
  await expect(page).toHaveURL(/\/\?q=bed$/)
  await expect(card(page, BED)).toBeVisible()
  await expect(card(page, WHEELCHAIR)).toBeHidden()
  await expect(shopNav.getByRole('link', { name: 'Return Policy' })).toHaveAttribute('href', '/return-policy')
})

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('the menu opens with every link and closes with Escape', async ({ page }) => {
    await mockCatalogReads(page)
    await openPublicRoute(page, '/faq')
    const menu = page.getByRole('dialog', { name: 'Menu' })
    await expect(async () => {
      await bar(page).getByRole('button', { name: 'Menu' }).click()
      await expect(menu.getByRole('link', { name: 'How It Works' })).toBeVisible({ timeout: 1000 })
    }).toPass()
    await expect(menu.getByRole('link', { name: 'Oxygen' })).toBeVisible()
    await expect(menu.getByRole('link', { name: 'Staff' })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(menu.getByRole('link', { name: 'How It Works' })).toBeHidden()
  })

  test('search sits on its own row and still works', async ({ page }) => {
    await mockCatalogReads(page)
    await openPublicRoute(page, '/faq')
    await searchFromBar(page, 'bed', undefined, /\/\?q=bed$/)
    await expect(card(page, BED)).toBeVisible()
  })
})
