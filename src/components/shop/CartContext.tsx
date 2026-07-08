import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'

export type CartMode = 'rent' | 'purchase'
export type CartItem = {
  id: string
  name: string
  image_url: string | null
  category: string
  mode: CartMode
  price: number
  qty: number
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

export function CartProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<CartItem[]>(() => {
    try { return JSON.parse(localStorage.getItem(KEY) || '[]') } catch { return [] }
  })
  const [open, setOpen] = useState(false)
  useEffect(() => { try { localStorage.setItem(KEY, JSON.stringify(items)) } catch { /* ignore */ } }, [items])

  const add: Ctx['add'] = (i) => {
    setItems((cur) => {
      const ex = cur.find((c) => c.id === i.id && c.mode === i.mode)
      if (ex) return cur.map((c) => (c.id === i.id && c.mode === i.mode ? { ...c, qty: c.qty + 1 } : c))
      return [...cur, { ...i, qty: 1 }]
    })
    setOpen(true)
  }
  const setQty: Ctx['setQty'] = (id, mode, qty) =>
    setItems((cur) => cur.map((c) => (c.id === id && c.mode === mode ? { ...c, qty: Math.max(1, qty) } : c)))
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
