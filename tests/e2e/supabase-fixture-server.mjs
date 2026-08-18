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
    sale_price: null,
    image_url: null,
    shopify_handle: 'playwright-hospital-bed',
    is_rentable: true,
    is_purchasable: false,
  },
]

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
    sendJson(response, 401, { message: 'No anonymous E2E session.' })
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
