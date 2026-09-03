'use client'

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { SHOP_PURCHASES_ENABLED } from '../../lib/shopFlags'
import type { PickupLocation } from '../../lib/shop'

export type CartMode = 'rent' | 'purchase'
export type CartItem = {
  id: string
  name: string
  image_url: string | null
  category: string
  mode: CartMode
  price: number
  pickup_price: number | null
  delivery_price: number | null
  qty: number
  pickup_enabled: boolean
  delivery_enabled: boolean
  same_day_pickup: boolean
  pickup_locations: PickupLocation[]
}

type Ctx = {
  items: CartItem[]
  open: boolean
  setOpen: (o: boolean) => void
  add: (i: Omit<CartItem, 'qty'>) => void
  setQty: (id: string, mode: CartMode, qty: number) => void
  remove: (id: string, mode: CartMode) => void
  clear: () => void
  count: number
}

const CartContext = createContext<Ctx | null>(null)
const KEY = 'cs_cart_v1'

function sanitizeCart(raw: unknown): CartItem[] {
  if (!Array.isArray(raw)) return []

  return raw
    .filter((item): item is CartItem => {
      if (!item || typeof item !== 'object') return false
      const cartItem = item as Partial<CartItem>
      return (
        typeof cartItem.id === 'string' &&
        typeof cartItem.name === 'string' &&
        typeof cartItem.category === 'string' &&
        typeof cartItem.price === 'number' &&
        Number.isFinite(cartItem.price) &&
        (cartItem.mode === 'rent' || (SHOP_PURCHASES_ENABLED && cartItem.mode === 'purchase'))
      )
    })
    .map((item) => ({
      ...item,
      image_url: typeof item.image_url === 'string' ? item.image_url : null,
      qty: Math.min(Math.max(1, Number(item.qty) || 1), 20),
      pickup_enabled: item.pickup_enabled === true,
      delivery_enabled: item.delivery_enabled !== false,
      same_day_pickup: item.same_day_pickup === true,
      pickup_locations: Array.isArray(item.pickup_locations) ? item.pickup_locations : [],
      pickup_price: typeof item.pickup_price === 'number' ? item.pickup_price : item.price,
      delivery_price: typeof item.delivery_price === 'number' ? item.delivery_price : item.price,
    }))
}

export function CartProvider({ children }: { children: ReactNode }) {
  // Always render the same initial cart on the server and the browser. Reading
  // localStorage in a state initializer creates a hydration mismatch and can
  // let the first persistence effect erase a visitor's saved cart.
  const [items, setItems] = useState<CartItem[]>([])
  const [hydrated, setHydrated] = useState(false)
  const [open, setOpen] = useState(false)

  useEffect(() => {
    try {
      setItems(sanitizeCart(JSON.parse(window.localStorage.getItem(KEY) || '[]')))
    } catch {
      setItems([])
    }
    setHydrated(true)
  }, [])

  useEffect(() => {
    if (!hydrated) return
    try {
      window.localStorage.setItem(KEY, JSON.stringify(items))
    } catch {
      /* ignore */
    }
  }, [hydrated, items])

  const add: Ctx['add'] = (i) => {
    if (i.mode === 'purchase' && !SHOP_PURCHASES_ENABLED) return
    setItems((cur) => {
      const ex = cur.find((c) => c.id === i.id && c.mode === i.mode)
      if (ex) {
        return cur.map((c) =>
          c.id === i.id && c.mode === i.mode ? { ...c, qty: Math.min(c.qty + 1, 20) } : c,
        )
      }
      return [...cur, { ...i, qty: 1 }]
    })
    setOpen(true)
  }
  const setQty: Ctx['setQty'] = (id, mode, qty) =>
    setItems((cur) =>
      cur.map((c) => (c.id === id && c.mode === mode ? { ...c, qty: Math.min(Math.max(1, qty), 20) } : c)),
    )
  const remove: Ctx['remove'] = (id, mode) => setItems((cur) => cur.filter((c) => !(c.id === id && c.mode === mode)))
  const clear = () => setItems([])
  const count = items.reduce((n, c) => n + c.qty, 0)

  return (
    <CartContext.Provider value={{ items, open, setOpen, add, setQty, remove, clear, count }}>
      {children}
    </CartContext.Provider>
  )
}

export function useCart() {
  const c = useContext(CartContext)
  if (!c) throw new Error('useCart must be used within CartProvider')
  return c
}
