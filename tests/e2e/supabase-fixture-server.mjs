import { createServer } from 'node:http'

const hostname = '127.0.0.1'
const port = 55439
const catalog = [
  {
    id: 'playwright-wheelchair-1',
    name: 'Playwright Wheelchair',
    description: 'Read-only browser-test fixture.',
    category: 'mobility',
    monthly_rental_price: 125,
    pickup_rental_price: 125,
    delivery_rental_price: 125,
    pickup_enabled: true,
    delivery_enabled: true,
    in_stock: true,
    can_buy: false,
    pickup_locations: [],
    sale_price: null,
    image_url: null,
    shopify_handle: 'playwright-wheelchair',
    is_rentable: true,
    is_purchasable: false,
  },
  {
    id: 'playwright-bed-1',
    name: 'Playwright Hospital Bed',
    description: 'Read-only browser-test fixture.',
    category: 'beds',
    monthly_rental_price: 275,
    pickup_rental_price: null,
    delivery_rental_price: 275,
    pickup_enabled: false,
    delivery_enabled: true,
    in_stock: true,
    can_buy: false,
    pickup_locations: [],
    sale_price: null,
    image_url: null,
    shopify_handle: 'playwright-hospital-bed',
    is_rentable: true,
    is_purchasable: false,
  },
  {
    id: 'playwright-retail-1', name: 'Playwright Shower Chair', description: 'Read-only retail fixture.',
    category: 'seating', monthly_rental_price: null, pickup_rental_price: null, delivery_rental_price: null,
    pickup_enabled: true, delivery_enabled: true, sale_price: 49.99, image_url: null,
    shopify_handle: 'playwright-shower-chair', is_rentable: false, is_purchasable: true,
    in_stock: true, can_buy: true, pickup_locations: [],
  },
  {
    id: 'playwright-lift-1', name: 'Playwright Patient Lift', description: 'Read-only out-of-stock fixture.',
    category: 'mobility', monthly_rental_price: 250, pickup_rental_price: null, delivery_rental_price: 250,
    pickup_enabled: false, delivery_enabled: true, sale_price: null, image_url: null,
    shopify_handle: 'playwright-patient-lift', is_rentable: true, is_purchasable: false,
    in_stock: false, can_buy: false, pickup_locations: [],
  },
]

// Synthetic auth for role-visibility browser tests, confined to this loopback server.
function fixtureUser(request) {
  try {
    const jwt = request.headers.authorization?.replace(/^Bearer /, '')
    const claims = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString())
    if (claims.sub !== '00000000-0000-4000-8000-000000000099' || !claims.fixture_role) return null
    return { id: claims.sub, role: 'authenticated', aud: 'authenticated', email: 'browser-fixture@example.invalid',
      app_metadata: { provider: 'email' }, user_metadata: {}, profile_role: claims.fixture_role,
      created_at: '2026-01-01T00:00:00Z' }
  } catch { return null }
}

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, OPTIONS',
  'access-control-allow-headers':
    'authorization, apikey, content-type, x-client-info, prefer, accept-profile',
}

function sendJson(response, status, body, headers = {}) {
  response.writeHead(status, {
    ...corsHeaders,
    ...headers,
    'content-type': 'application/json',
  })
  response.end(JSON.stringify(body))
}

const server = createServer((request, response) => {
  const url = new URL(request.url || '/', `http://${hostname}:${port}`)

  if (request.method === 'OPTIONS') {
    response.writeHead(204, corsHeaders)
    response.end()
    return
  }

  if (request.method !== 'GET') {
    sendJson(response, 405, { message: 'The E2E fixture server is read-only.' })
    return
  }

  if (url.pathname === '/health') {
    sendJson(response, 200, { ok: true })
    return
  }

  if (url.pathname === '/rest/v1/equipment_items') {
    const handle = url.searchParams.get('shopify_handle')?.replace(/^eq\./, '')
    const id = url.searchParams.get('id')?.replace(/^eq\./, '')
    const requestedProduct = handle || id
    const result = requestedProduct
      ? catalog.filter(
          (product) =>
            product.shopify_handle === requestedProduct || product.id === requestedProduct,
        )
      : catalog

    sendJson(response, 200, result, {
      'access-control-expose-headers': 'content-range',
      'content-range': result.length ? `0-${result.length - 1}/${result.length}` : '*/0',
    })
    return
  }

  if (url.pathname.startsWith('/auth/v1/')) {
    const user = fixtureUser(request)
    if (url.pathname === '/auth/v1/user' && user) {
      sendJson(response, 200, user)
      return
    }
    sendJson(response, 401, { message: 'No anonymous E2E session.' })
    return
  }

  if (url.pathname === '/rest/v1/profiles') {
    const user = fixtureUser(request)
    sendJson(response, 200, user ? [{ id: user.id, role: user.profile_role, is_active: true }] : [])
    return
  }

  sendJson(response, 404, { message: 'Fixture endpoint not found.' })
})

server.listen(port, hostname)

function close() {
  server.close(() => process.exit(0))
}

process.on('SIGINT', close)
process.on('SIGTERM', close)
