// Adding products in bulk (owner, 2026-11-10; migration 149): pick from the
// shared starter list or upload a CSV. Both send the same rows to
// add_products, which checks them again and adds all or nothing.
import { CATEGORIES } from './categories.ts'

export type ImportItem = {
  starter_id?: string
  name?: string
  category?: string
  description?: string
  rent: boolean
  sell: boolean
  pickup_price: string
  delivery_price: string
  sale_price: string
  stock: string
}

export type RowError = { row: number; field: string; message: string }

export const CSV_COLUMNS = ['name', 'category', 'rent', 'sell', 'monthly_price_pickup', 'monthly_price_delivered', 'sale_price', 'stock', 'description'] as const

export const CSV_TEMPLATE = [
  CSV_COLUMNS.join(','),
  'Hospital bed,bedroom,yes,no,150,175,,3,"Full electric, with rails"',
  'Offset cane,mobility aids,no,yes,,,24.50,12,Adjustable height',
].join('\n') + '\n'

const PRICE = /^\d{1,6}(\.\d{1,2})?$/
const WHOLE = /^\d{1,5}$/
const YES = new Set(['yes', 'y', 'true', '1', 'x'])

/** RFC 4180-style CSV: quoted fields, doubled quotes, CRLF; blank lines dropped. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let quoted = false
  const src = text.replace(/^﻿/, '')
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]
    if (quoted) {
      if (ch === '"' && src[i + 1] === '"') { field += '"'; i++ }
      else if (ch === '"') quoted = false
      else field += ch
    } else if (ch === '"') quoted = true
    else if (ch === ',') { row.push(field); field = '' }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++
      row.push(field); field = ''
      if (row.some((cell) => cell.trim())) rows.push(row)
      row = []
    } else field += ch
  }
  row.push(field)
  if (row.some((cell) => cell.trim())) rows.push(row)
  return rows
}

/** The same checks add_products makes, so mistakes show before anything is sent. */
export function itemProblem(item: ImportItem, delivers: boolean): { field: string; message: string } | null {
  if (!item.starter_id && !(item.name ?? '').trim()) return { field: 'name', message: 'Enter the product name.' }
  if (!item.starter_id && !CATEGORIES.includes(item.category ?? '')) return { field: 'category', message: `Use one of the listed categories: ${CATEGORIES.join(', ')}.` }
  if (!item.rent && !item.sell) return { field: 'rent', message: 'Choose rent, sell, or both.' }
  if (item.rent && !PRICE.test(item.pickup_price)) return { field: 'pickup_price', message: 'Enter the monthly price for pickup, like 45 or 45.50.' }
  if (item.rent && delivers && !PRICE.test(item.delivery_price)) return { field: 'delivery_price', message: 'Enter the monthly price for delivery, like 45 or 45.50.' }
  if (item.sell && !PRICE.test(item.sale_price)) return { field: 'sale_price', message: 'Enter the sale price, like 45 or 45.50.' }
  if (!WHOLE.test(item.stock || '0')) return { field: 'stock', message: 'Enter stock as a whole number, like 12.' }
  return null
}

const norm = (header: string) => header.trim().toLowerCase().replace(/[^a-z]+/g, '_').replace(/^_|_$/g, '')
const ALIASES: Record<string, string> = { product: 'name', product_name: 'name', pickup_price: 'monthly_price_pickup', delivery_price: 'monthly_price_delivered', quantity: 'stock', qty: 'stock' }

/** Reads an uploaded CSV into items, with each bad line named by its line number in the file. */
export function csvToItems(text: string, delivers: boolean): { items: ImportItem[]; problems: { line: number; message: string }[] } {
  const [header, ...rows] = parseCsv(text)
  const columns = (header ?? []).map((h) => { const n = norm(h); return ALIASES[n] ?? n })
  if (!columns.includes('name')) return { items: [], problems: [{ line: 1, message: `The first line must name the columns, starting with name. Download the template to see them: ${CSV_COLUMNS.join(', ')}.` }] }
  const items: ImportItem[] = []
  const problems: { line: number; message: string }[] = []
  rows.forEach((cells, i) => {
    const get = (key: string) => (cells[columns.indexOf(key)] ?? '').trim()
    const item: ImportItem = {
      name: get('name'), category: get('category').toLowerCase(), description: get('description'),
      rent: YES.has(get('rent').toLowerCase()), sell: YES.has(get('sell').toLowerCase()),
      pickup_price: get('monthly_price_pickup').replace(/^\$/, ''), delivery_price: get('monthly_price_delivered').replace(/^\$/, ''),
      sale_price: get('sale_price').replace(/^\$/, ''), stock: get('stock') || '0',
    }
    const problem = itemProblem(item, delivers)
    if (problem) problems.push({ line: i + 2, message: problem.message })
    items.push(item)
  })
  return { items, problems }
}

/** A row refusal from add_products, worded for where the rows came from. */
export function rowMessage(e: RowError, from: 'csv' | 'list'): string {
  return from === 'csv' ? `Line ${e.row + 1}: ${e.message}` : `Item ${e.row}: ${e.message}`
}

export const ADD_PRODUCTS_REASONS: Record<string, string> = {
  forbidden: 'Only the owner can add products here.',
  location_not_found: 'Choose one of your locations first.',
  no_items: 'Choose at least one product.',
  too_many: 'Add up to 500 products at a time.',
}
