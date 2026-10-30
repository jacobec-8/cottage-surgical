'use client'

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { PRODUCT_FIELDS, type PickupLocation, type Product } from '../../lib/shop'
import { publicSupabase } from '../../lib/publicSupabase'
import { withLatestProduct } from '../../lib/cartRefresh'
import { clearCheckoutDraft, forgetPendingCheckout, pendingCheckout } from '../../lib/checkoutSession'

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
  /** False until the saved cart is read, so an empty list isn't mistaken for an empty cart. */
  hydrated: boolean
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
        (cartItem.mode === 'rent' || cartItem.mode === 'purchase')
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

  // Availability can change while a cart sits open or saved: staff turn pickup
  // on or off, change prices or pickup stores. Re-read the storefront fields
  // after hydration, every time the cart opens, and when the tab regains focus.
  const itemsRef = useRef(items)
  useEffect(() => { itemsRef.current = items }, [items])
  const refreshFromStore = useCallback(() => {
    const itemIds = [...new Set(itemsRef.current.map((item) => item.id))]
    if (itemIds.length === 0) return
    void publicSupabase.from('equipment_items').select(PRODUCT_FIELDS)
      .in('id', itemIds).eq('is_active', true)
      .then(({ data, error }) => {
        if (error || !data) return
        const products = new Map((data as unknown as Product[]).map((product) => [product.id, product]))
        setItems((current) => current.map((item) => {
          const product = products.get(item.id)
          return product ? withLatestProduct(item, product) : item
        }))
      })
  }, [])
  useEffect(() => { if (hydrated) refreshFromStore() }, [hydrated, refreshFromStore])
  useEffect(() => { if (hydrated && open) refreshFromStore() }, [hydrated, open, refreshFromStore])
  useEffect(() => {
    const onVisible = () => { if (document.visibilityState === 'visible') refreshFromStore() }
    document.addEventListener('visibilitychange', onVisible)
    return () => document.removeEventListener('visibilitychange', onVisible)
  }, [refreshFromStore])

  // Paid, then closed the tab before coming back: don't let them order the same cart again.
  useEffect(() => {
    if (!hydrated) return
    const ref = pendingCheckout()
    if (!ref) return
    void publicSupabase.rpc('verify_stripe_payment', { p_order_id: ref }).then(({ data, error }) => {
      if (error || !data?.ok) return
      if (data.paid) {
        setItems([])
        clearCheckoutDraft()
      } else if (data.state) {
        return // Still open in Stripe; they may yet pay.
      }
      forgetPendingCheckout()
    })
  }, [hydrated])

  const add: Ctx['add'] = (i) => {
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
    <CartContext.Provider value={{ items, hydrated, open, setOpen, add, setQty, remove, clear, count }}>
      {children}
    </CartContext.Provider>
  )
}

export function useCart() {
  const c = useContext(CartContext)
  if (!c) throw new Error('useCart must be used within CartProvider')
  return c
}
