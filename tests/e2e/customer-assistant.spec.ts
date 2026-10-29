import { expect, test, type BrowserContext, type Page } from '@playwright/test'

async function signInFixture(context: BrowserContext, role: string) {
  const now = Math.floor(Date.now() / 1000)
  const claims = { sub: '00000000-0000-4000-8000-000000000099', aud: 'authenticated', role: 'authenticated', fixture_role: role, exp: now + 3600, iat: now }
  const jwt = `${Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url')}.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.fixture-signature`
  const session = { access_token: jwt, refresh_token: 'fixture-refresh', expires_at: claims.exp, expires_in: 3600, token_type: 'bearer',
    user: { id: claims.sub, aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {} } }
  await context.addCookies([{ name: 'sb-127-auth-token', value: `base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`, domain: '127.0.0.1', path: '/', sameSite: 'Lax' }])
}

async function openAssistant(page: Page) {
  await page.goto('/')
  await page.getByRole('button', { name: 'Ask Cottage', exact: true }).click()
  return page.getByRole('dialog', { name: 'Ask Cottage' })
}

test('guest finds live rental and purchase links, follows up and navigates without losing chat', async ({ page }, testInfo) => {
  const failures: string[] = []
  page.on('pageerror', error => failures.push(error.message))
  const chat = await openAssistant(page)
  await chat.getByRole('button', { name: 'Wheelchair rental options', exact: true }).click()
  await expect(chat.getByRole('link', { name: 'Playwright Wheelchair', exact: true })).toBeVisible()
  await expect(chat.getByText('In stock', { exact: true })).toBeVisible()
  await expect(chat.getByRole('link', { name: 'Rental options', exact: true })).toHaveAttribute('href', '/product/playwright-wheelchair#rent-equipment')
  await chat.getByRole('link', { name: 'Rental options', exact: true }).click()
  await expect(page).toHaveURL(/\/product\/playwright-wheelchair#rent-equipment$/)
  await expect(page.locator('#rent-equipment')).toBeVisible()
  await expect(chat).toBeVisible()
  await chat.getByLabel('Ask about equipment').fill('What can I buy online?')
  await chat.getByRole('button', { name: 'Send equipment question' }).click()
  await expect(chat.getByRole('link', { name: 'Playwright Shower Chair', exact: true })).toBeVisible()
  await expect(chat.getByText('$49.99 to buy')).toBeVisible()
  await expect(chat.getByRole('link', { name: 'Purchase', exact: true })).toHaveAttribute('href', '/product/playwright-shower-chair#buy-equipment')
  await page.screenshot({ path: testInfo.outputPath('customer-assistant-desktop.png') })
  await chat.getByRole('link', { name: 'Purchase', exact: true }).click()
  await expect(page).toHaveURL(/\/product\/playwright-shower-chair#buy-equipment$/)
  await expect(page.locator('#buy-equipment')).toBeVisible()
  expect(failures).toEqual([])
})

test('stock is refreshed on every question and an outage never becomes an invented stock answer', async ({ page }) => {
  const chat = await openAssistant(page)
  await chat.getByLabel('Ask about equipment').fill('patient lift')
  await chat.getByLabel('Ask about equipment').press('Enter')
  await expect(chat.getByText('Out of stock', { exact: true })).toBeVisible()
  await expect(chat.getByRole('link', { name: 'Rental options', exact: true })).toHaveCount(0)
  await chat.getByLabel('Ask about equipment').fill('Is it still in stock?')
  await chat.getByLabel('Ask about equipment').press('Enter')
  await expect(chat.getByText('Out of stock', { exact: true })).toHaveCount(2)
  await page.route('**/rest/v1/equipment_items**', route => route.abort('failed'))
  await chat.getByLabel('Ask about equipment').fill('Is it available?')
  await chat.getByRole('button', { name: 'Send equipment question' }).click()
  await expect(chat.getByRole('alert')).toContainText('couldn’t check the catalog')
  await expect(chat.getByLabel('Ask about equipment')).toHaveValue('Is it available?')
})

for (const role of ['admin', 'owner', 'staff', 'driver', 'unknown-internal']) {
  test(`assistant stays hidden on public pages for ${role}`, async ({ page, context }) => {
    await signInFixture(context, role)
    const profileRead = page.waitForResponse(r => r.url().includes('/rest/v1/profiles'))
    await page.goto('/')
    await profileRead
    await expect(page.getByRole('button', { name: 'Ask Cottage' })).toHaveCount(0)
    await page.goto('/faq')
    await expect(page.getByRole('button', { name: 'Ask Cottage' })).toHaveCount(0)
  })
}

test('signed-in customers can use the assistant', async ({ page, context }) => {
  await signInFixture(context, 'customer')
  await openAssistant(page)
  await expect(page.getByRole('dialog', { name: 'Ask Cottage' })).toBeVisible()
})

test('mobile panel fits, closes with Escape and gives the cart its space', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 375, height: 667 })
  const chat = await openAssistant(page)
  await expect(chat).toBeVisible()
  const box = await chat.boundingBox()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(375)
  expect(box!.y + box!.height).toBeLessThanOrEqual(667)
  await chat.getByRole('button', { name: 'Wheelchair rental options', exact: true }).click()
  await expect(chat.getByRole('link', { name: 'Rental options', exact: true })).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('customer-assistant-mobile.png') })
  await chat.getByLabel('Ask about equipment').press('Escape')
  await expect(chat).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Ask Cottage', exact: true })).toBeFocused()
  await page.getByRole('button', { name: 'Cart', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Ask Cottage' })).toHaveCount(0)
  await expect(page.getByRole('dialog', { name: 'Ask Cottage' })).toHaveCount(0)
})

test('an unresolved signed-in profile stays hidden instead of becoming a guest', async ({ page, context }) => {
  await signInFixture(context, 'staff')
  await page.route('**/rest/v1/profiles**', route => route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ message: 'Fixture profile unavailable' }), headers: { 'access-control-allow-origin': '*' } }))
  const profileRead = page.waitForResponse(r => r.url().includes('/rest/v1/profiles'))
  await page.goto('/')
  await profileRead
  await expect(page.getByRole('button', { name: 'Ask Cottage' })).toHaveCount(0)
})

test('no assistant is mounted in the login/internal route group', async ({ page }) => {
  await page.goto('/admin-login')
  await expect(page.getByRole('heading', { name: 'Sign In' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Ask Cottage' })).toHaveCount(0)
})
