'use client'

import { useEffect, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { cartItemPrice, quoteProblem, type CartQuote, type Fulfillment } from '../../lib/checkoutPlan'
import { publicSupabase } from '../../lib/publicSupabase'
import { shopPrice } from '../../lib/shopPrice'
import { refusalStands } from '../../lib/stockMessage'
import type { CartItem } from './CartContext'

// While the cart is open, recheck stock so it follows staff changes both ways.
const STOCK_RECHECK_MS = 15_000

type Args = { items: CartItem[]; fulfillment: Fulfillment; pickupLocationId: string; deliveryZip: string | null; enabled: boolean }

/**
 * What the cart costs and whether it can be filled, by the store checkout would use (118).
 * Catalog prices show until the quote loads.
 */
export function useCartQuote({ items, fulfillment, pickupLocationId, deliveryZip, enabled }: Args) {
  const lines = (mode: CartItem['mode']) => items.filter((i) => i.mode === mode).map((i) => ({ item_id: i.id, quantity: i.qty }))
  const rentals = lines('rent')
  const purchases = lines('purchase')
  const quote = useQuery({
    queryKey: ['storefront_cart_quote', fulfillment, pickupLocationId, deliveryZip, rentals, purchases],
    enabled: enabled && items.length > 0 && (fulfillment === 'delivery' || Boolean(pickupLocationId)),
    refetchInterval: STOCK_RECHECK_MS,
    queryFn: async () => {
      const { data, error } = await publicSupabase.rpc('quote_storefront_cart', {
        p_rentals: rentals,
        p_purchases: purchases,
        p_fulfillment: { method: fulfillment, pickup_location_id: fulfillment === 'pickup' ? pickupLocationId : null, delivery_zip: deliveryZip },
      })
      if (error) throw error
      return data as CartQuote
    },
  })

  // A shortage reply carries no prices; keep this store's last quote rather than fall back to list price.
  const quoteKey = `${fulfillment}|${pickupLocationId}|${deliveryZip ?? ''}`
  const [lastQuote, setLastQuote] = useState<{ key: string; quote: CartQuote } | null>(null)
  useEffect(() => {
    if (quote.data?.ok) setLastQuote({ key: quoteKey, quote: quote.data })
  }, [quote.data, quoteKey])
  const priced: CartQuote = quote.data?.ok
    ? quote.data
    : quote.data?.reason === 'out_of_stock' && lastQuote?.key === quoteKey ? lastQuote.quote : { ok: false }
  const priceOf = (item: CartItem) => cartItemPrice(item, priced, fulfillment)

  // A refused submit clears itself once a newer check finds the stock again (e.g. staff restocked).
  const [stockRefusal, setStockRefusal] = useState<{ message: string; at: number } | null>(null)
  const refused = stockRefusal && refusalStands(stockRefusal.at, { ok: quote.data?.ok, updatedAt: quote.dataUpdatedAt })
    ? stockRefusal.message
    : null
  const refuseForStock = (message: string) => {
    setStockRefusal({ message, at: quote.dataUpdatedAt })
    void quote.refetch()
  }

  // Tell the customer when an open cart's price changes (store restocked, price updated) — never silently (100).
  const lastPrices = useRef<{ key: string; of: (item: CartItem) => number } | null>(null)
  const [priceNotice, setPriceNotice] = useState('')
  useEffect(() => {
    const fresh = quote.data
    if (!fresh?.ok) return
    const now = (item: CartItem) => cartItemPrice(item, fresh, fulfillment)
    const before = lastPrices.current
    lastPrices.current = { key: quoteKey, of: now }
    // Choosing another store or ZIP is the customer's own change, not a surprise.
    if (!before || before.key !== quoteKey) return
    const changed = items.filter((i) => before.of(i) !== now(i))
    if (changed.length) {
      setPriceNotice(changed.map((i) => `${i.name}: now ${shopPrice(now(i))}${i.mode === 'rent' ? '/mo' : ''} (was ${shopPrice(before.of(i))})`).join('; '))
    }
    // Only a new reply can change a price.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quote.data])

  return {
    priceOf,
    rentTotal: items.filter((i) => i.mode === 'rent').reduce((s, i) => s + priceOf(i) * i.qty, 0),
    buyTotal: items.filter((i) => i.mode === 'purchase').reduce((s, i) => s + priceOf(i) * i.qty, 0),
    problem: quoteProblem(quote.data, fulfillment) ?? refused,
    priceNotice,
    refuseForStock,
    clearRefusal: () => setStockRefusal(null),
  }
}
