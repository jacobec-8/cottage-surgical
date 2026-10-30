'use client'

import { useEffect, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { cartItemPrice, quoteProblem, type Fulfillment, type RentalQuote } from '../../lib/checkoutPlan'
import { publicSupabase } from '../../lib/publicSupabase'
import { shopPrice } from '../../lib/shopPrice'
import { refusalStands } from '../../lib/stockMessage'
import type { CartItem } from './CartContext'

// While the cart is open, recheck stock so it follows staff changes both ways.
const STOCK_RECHECK_MS = 15_000

type Args = { items: CartItem[]; fulfillment: Fulfillment; pickupLocationId: string; deliveryZip: string | null; enabled: boolean }

/**
 * The server charges the chosen store's rental price; quote it with the same
 * store selection checkout uses (066). Catalog prices show until it loads.
 */
export function useCartQuote({ items, fulfillment, pickupLocationId, deliveryZip, enabled }: Args) {
  const rentItems = items.filter((i) => i.mode === 'rent')
  const quoteItems = rentItems.map((i) => ({ item_id: i.id, quantity: i.qty }))
  const quote = useQuery({
    queryKey: ['storefront_rental_quote', fulfillment, pickupLocationId, deliveryZip, quoteItems],
    enabled: enabled && quoteItems.length > 0 && (fulfillment === 'delivery' || Boolean(pickupLocationId)),
    refetchInterval: STOCK_RECHECK_MS,
    queryFn: async () => {
      const { data, error } = await publicSupabase.rpc('quote_storefront_rentals', {
        p_items: quoteItems,
        p_fulfillment: { method: fulfillment, pickup_location_id: fulfillment === 'pickup' ? pickupLocationId : null, delivery_zip: deliveryZip },
      })
      if (error) throw error
      return data as RentalQuote
    },
  })

  // A shortage reply carries no prices; keep this store's last quote rather than fall back to list price.
  const quoteKey = `${fulfillment}|${pickupLocationId}|${deliveryZip ?? ''}`
  const [lastQuote, setLastQuote] = useState<{ key: string; prices: Record<string, number | null> } | null>(null)
  useEffect(() => {
    if (quote.data?.ok) setLastQuote({ key: quoteKey, prices: quote.data.prices ?? {} })
  }, [quote.data, quoteKey])
  const quotedPrices = quote.data?.ok
    ? quote.data.prices ?? {}
    : quote.data?.reason === 'out_of_stock' && lastQuote?.key === quoteKey ? lastQuote.prices : {}
  const priceOf = (item: CartItem) => cartItemPrice(item, quotedPrices, fulfillment)

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
  const lastPrices = useRef<Record<string, number | null> | null>(null)
  const [priceNotice, setPriceNotice] = useState('')
  useEffect(() => {
    const prices = quote.data?.ok ? quote.data.prices ?? null : null
    if (!prices) return
    const before = lastPrices.current
    lastPrices.current = prices
    if (!before) return
    const changed = rentItems.filter((i) => before[i.id] != null && prices[i.id] != null && Number(before[i.id]) !== Number(prices[i.id]))
    if (changed.length) {
      setPriceNotice(changed.map((i) => `${i.name}: now ${shopPrice(Number(prices[i.id]))}/mo (was ${shopPrice(Number(before[i.id]))})`).join('; '))
    }
    // Only a new reply can change a price.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quote.data])

  return {
    priceOf,
    rentTotal: rentItems.reduce((s, i) => s + priceOf(i) * i.qty, 0),
    buyTotal: items.filter((i) => i.mode === 'purchase').reduce((s, i) => s + priceOf(i) * i.qty, 0),
    problem: quoteProblem(quote.data, fulfillment) ?? refused,
    priceNotice,
    refuseForStock,
    clearRefusal: () => setStockRefusal(null),
  }
}
