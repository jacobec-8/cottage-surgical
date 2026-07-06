import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useQueryClient } from '@tanstack/react-query'
import { Search, Plus, Minus, Trash2, CheckCircle } from 'lucide-react'
import { supabase } from '../lib/supabase'

type Item = { id: string; name: string; category: string; monthly_rental_price: number | null; sale_price: number | null; is_rentable: boolean; is_purchasable: boolean }
type CartLine = { item_id: string; name: string; qty: number; rate: number | null }

const orderErrorMessage = (reason?: string) => {
  switch (reason) {
    case 'missing_customer': return 'Choose or add a customer first.'
    case 'invalid_customer': return 'That customer no longer exists — pick another.'
    case 'invalid_item': return 'One of the items is no longer available for this order type. Remove it and try again.'
    case 'no_items': return 'Add at least one item.'
    case 'forbidden': return 'You don’t have permission to create orders.'
    default: return `Couldn’t create the order (${reason || 'unknown error'}).`
  }
}

export default function NewOrder() {
  const qc = useQueryClient()
  const [mode, setMode] = useState<'rental' | 'purchase'>('rental')

  // customer
  const [custMode, setCustMode] = useState<'existing' | 'new'>('existing')
  const [custSearch, setCustSearch] = useState('')
  const [cust, setCust] = useState<{ id: string; name: string } | null>(null)
  const [nc, setNc] = useState({ full_name: '', phone: '', email: '', dob: '', coverage: '', line1: '', city: '', state: 'NY', zip: '' })

  // cart + delivery
  const [cart, setCart] = useState<CartLine[]>([])
  const [itemSearch, setItemSearch] = useState('')
  const [deliv, setDeliv] = useState({ date: '', ws: '', we: '', driver: '', notes: '', deposit: '' })

  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [result, setResult] = useState<{ order_no: number; unallocated: number } | null>(null)

  const customers = useQuery({
    queryKey: ['cust_search', custSearch],
    enabled: custMode === 'existing' && custSearch.length >= 2,
    queryFn: async () => {
      const { data } = await supabase.from('customers').select('id,full_name,phone').ilike('full_name', `%${custSearch}%`).limit(8)
      return (data ?? []) as any[]
    },
  })
  const items = useQuery({
    queryKey: ['neworder_items'],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items')
        .select('id,name,category,monthly_rental_price,sale_price,is_rentable,is_purchasable').eq('is_active', true).order('name')
      if (error) throw error
      return data as Item[]
    },
  })
  const drivers = useQuery({
    queryKey: ['drivers'],
    queryFn: async () => {
      const { data } = await supabase.from('drivers').select('id,first_name,last_name').eq('status', 'active').order('first_name')
      return (data ?? []) as any[]
    },
  })

  const rateFor = (it: Item) => (mode === 'rental' ? it.monthly_rental_price : it.sale_price)
  const eligible = (it: Item) => (mode === 'rental' ? it.is_rentable && it.monthly_rental_price != null : it.is_purchasable && it.sale_price != null)
  const filteredItems = useMemo(
    () => (items.data ?? []).filter((it) => eligible(it) && it.name.toLowerCase().includes(itemSearch.toLowerCase())),
    [items.data, itemSearch, mode],
  )
  const total = cart.reduce((s, l) => s + (l.rate ?? 0) * l.qty, 0)

  const addItem = (it: Item) => {
    setCart((c) => {
      const ex = c.find((l) => l.item_id === it.id)
      if (ex) return c.map((l) => (l.item_id === it.id ? { ...l, qty: l.qty + 1 } : l))
      return [...c, { item_id: it.id, name: it.name, qty: 1, rate: rateFor(it) }]
    })
  }
  const setQty = (id: string, d: number) => setCart((c) => c.map((l) => (l.item_id === id ? { ...l, qty: Math.max(1, l.qty + d) } : l)))
  const removeItem = (id: string) => setCart((c) => c.filter((l) => l.item_id !== id))

  const create = async () => {
    setBusy(true); setErr(''); setResult(null)
    try {
      if (cart.length === 0) throw new Error('Add at least one item.')
      // Existing vs new customer — the new customer is created INSIDE the RPC
      // (one transaction), so a failed order can never leave an orphan customer
      // and a retry can't create a duplicate.
      let customerId: string | null = null
      let newCustomer: Record<string, string | null> | null = null
      if (custMode === 'existing') {
        if (!cust?.id) throw new Error('Choose a customer.')
        customerId = cust.id
      } else {
        if (!nc.full_name.trim()) throw new Error('Enter the customer’s name.')
        newCustomer = {
          full_name: nc.full_name.trim(), phone: nc.phone || null, email: nc.email || null,
          dob: nc.dob || null, coverage: nc.coverage || null,
          line1: nc.line1 || null, city: nc.city || null, state: nc.state || 'NY', zip: nc.zip || null,
        }
      }
      const { data, error } = await supabase.rpc('create_staff_order', {
        p_customer_id: customerId,
        p_order_type: mode,
        p_items: cart.map((l) => ({ item_id: l.item_id, quantity: l.qty })),
        p_delivery: { scheduled_date: deliv.date || null, window_start: deliv.ws || null, window_end: deliv.we || null, driver_id: deliv.driver || null, notes: deliv.notes || null },
        p_deposit: deliv.deposit ? Number(deliv.deposit) : null,
        p_new_customer: newCustomer,
      })
      if (error) throw error
      if (!data?.ok) throw new Error(orderErrorMessage(data?.reason))
      setResult({ order_no: data.order_no, unallocated: data.unallocated })
      setCart([]); setCust(null); setNc({ full_name: '', phone: '', email: '', dob: '', coverage: '', line1: '', city: '', state: 'NY', zip: '' })
      setDeliv({ date: '', ws: '', we: '', driver: '', notes: '', deposit: '' })
      qc.invalidateQueries({ queryKey: ['rentals'] })
      qc.invalidateQueries({ queryKey: ['deliveries'] })
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const inp = 'border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  const card = 'bg-white border border-slate-200 rounded-xl p-5'
  const label = 'text-sm font-semibold text-slate-700 mb-3'

  if (result) {
    return (
      <div className="max-w-lg">
        <div className="bg-emerald-50 border border-emerald-200 rounded-xl p-6">
          <div className="flex items-center gap-2 text-emerald-800 font-semibold text-lg"><CheckCircle size={20} /> Order #{result.order_no} created</div>
          <p className="text-sm text-emerald-700 mt-2">
            A delivery has been queued.
            {result.unallocated > 0
              ? ` ${result.unallocated} item(s) had no unit in stock — allocate them from the order once units are available.`
              : ' All items were reserved from inventory.'}
          </p>
          <button onClick={() => setResult(null)} className="mt-4 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm">
            New order
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="max-w-3xl space-y-4">
      <div>
        <h1 className="text-2xl font-semibold mb-1">New Order</h1>
        <p className="text-slate-500 text-sm">Build a rental or purchase, reserve equipment, and schedule delivery.</p>
      </div>

      <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1">
        {(['rental', 'purchase'] as const).map((m) => (
          <button key={m} onClick={() => { setMode(m); setCart([]) }}
            className={`px-4 py-1.5 text-sm rounded-md capitalize ${mode === m ? 'bg-slate-900 text-white' : 'text-slate-600'}`}>{m}</button>
        ))}
      </div>

      {/* Customer */}
      <div className={card}>
        <div className={label}>Customer</div>
        <div className="inline-flex rounded-lg border border-slate-200 p-1 mb-3">
          {(['existing', 'new'] as const).map((m) => (
            <button key={m} onClick={() => setCustMode(m)} className={`px-3 py-1 text-xs rounded-md capitalize ${custMode === m ? 'bg-blue-600 text-white' : 'text-slate-600'}`}>
              {m === 'existing' ? 'Existing' : 'New customer'}
            </button>
          ))}
        </div>
        {custMode === 'existing' ? (
          <div>
            {cust ? (
              <div className="flex items-center justify-between bg-slate-50 border border-slate-200 rounded-lg px-3 py-2">
                <span className="text-sm font-medium">{cust.name}</span>
                <button onClick={() => setCust(null)} className="text-xs text-blue-600">change</button>
              </div>
            ) : (
              <>
                <div className="relative">
                  <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
                  <input value={custSearch} onChange={(e) => setCustSearch(e.target.value)} placeholder="Search customers by name…" className={`w-full pl-9 ${inp}`} />
                </div>
                <div className="mt-2 space-y-1">
                  {customers.data?.map((c) => (
                    <button key={c.id} onClick={() => { setCust({ id: c.id, name: c.full_name }); setCustSearch('') }}
                      className="w-full text-left px-3 py-2 rounded-lg hover:bg-slate-50 text-sm flex justify-between">
                      <span>{c.full_name}</span><span className="text-slate-400">{c.phone}</span>
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-3">
            <input placeholder="Full name" value={nc.full_name} onChange={(e) => setNc({ ...nc, full_name: e.target.value })} className={`col-span-2 ${inp}`} />
            <input placeholder="Phone" value={nc.phone} onChange={(e) => setNc({ ...nc, phone: e.target.value })} className={inp} />
            <input type="email" placeholder="Email" value={nc.email} onChange={(e) => setNc({ ...nc, email: e.target.value })} className={inp} />
            <input type="date" placeholder="DOB" value={nc.dob} onChange={(e) => setNc({ ...nc, dob: e.target.value })} className={inp} />
            <select value={nc.coverage} onChange={(e) => setNc({ ...nc, coverage: e.target.value })} className={inp}>
              <option value="">Coverage…</option>
              <option value="medicare">Medicare</option>
              <option value="medicaid">Medicaid</option>
              <option value="private_pay">Private Pay</option>
              <option value="commercial_insurance">Commercial Insurance</option>
            </select>
            <input placeholder="Address" value={nc.line1} onChange={(e) => setNc({ ...nc, line1: e.target.value })} className={`col-span-2 ${inp}`} />
            <input placeholder="City" value={nc.city} onChange={(e) => setNc({ ...nc, city: e.target.value })} className={inp} />
            <input placeholder="ZIP" value={nc.zip} onChange={(e) => setNc({ ...nc, zip: e.target.value })} className={inp} />
          </div>
        )}
      </div>

      {/* Equipment */}
      <div className={card}>
        <div className={label}>Equipment</div>
        <div className="relative mb-2">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input value={itemSearch} onChange={(e) => setItemSearch(e.target.value)} placeholder="Search equipment…" className={`w-full pl-9 ${inp}`} />
        </div>
        {itemSearch && (
          <div className="border border-slate-200 rounded-lg divide-y divide-slate-100 mb-3 max-h-56 overflow-auto">
            {filteredItems.map((it) => (
              <button key={it.id} onClick={() => addItem(it)} className="w-full text-left px-3 py-2 hover:bg-slate-50 flex justify-between text-sm">
                <span>{it.name}</span>
                <span className="text-slate-500">${Number(rateFor(it) ?? 0).toFixed(0)}{mode === 'rental' ? '/mo' : ''}</span>
              </button>
            ))}
            {filteredItems.length === 0 && <div className="px-3 py-2 text-sm text-slate-400">No matching {mode} items.</div>}
          </div>
        )}
        {cart.length === 0 ? (
          <div className="text-sm text-slate-400">No items yet — search and add equipment.</div>
        ) : (
          <div className="space-y-2">
            {cart.map((l) => (
              <div key={l.item_id} className="flex items-center gap-3 bg-slate-50 rounded-lg px-3 py-2">
                <div className="flex-1 text-sm font-medium">{l.name}</div>
                <div className="flex items-center gap-1">
                  <button onClick={() => setQty(l.item_id, -1)} className="w-6 h-6 rounded border border-slate-300 grid place-items-center text-slate-500"><Minus size={13} /></button>
                  <span className="w-6 text-center text-sm">{l.qty}</span>
                  <button onClick={() => setQty(l.item_id, 1)} className="w-6 h-6 rounded border border-slate-300 grid place-items-center text-slate-500"><Plus size={13} /></button>
                </div>
                <div className="w-24 text-right text-sm font-medium">${((l.rate ?? 0) * l.qty).toFixed(0)}{mode === 'rental' ? '/mo' : ''}</div>
                <button onClick={() => removeItem(l.item_id)} className="text-slate-400 hover:text-red-600"><Trash2 size={15} /></button>
              </div>
            ))}
            <div className="flex justify-end text-sm font-semibold pt-1">Total: ${total.toFixed(0)}{mode === 'rental' ? '/mo' : ''}</div>
          </div>
        )}
      </div>

      {/* Delivery */}
      <div className={card}>
        <div className={label}>Schedule delivery</div>
        <div className="grid grid-cols-2 gap-3">
          <div><span className="text-xs text-slate-500">Date</span><input type="date" value={deliv.date} onChange={(e) => setDeliv({ ...deliv, date: e.target.value })} className={`w-full ${inp}`} /></div>
          <div><span className="text-xs text-slate-500">Driver</span>
            <select value={deliv.driver} onChange={(e) => setDeliv({ ...deliv, driver: e.target.value })} className={`w-full ${inp}`}>
              <option value="">Unassigned</option>
              {drivers.data?.map((d) => <option key={d.id} value={d.id}>{d.first_name} {d.last_name}</option>)}
            </select>
          </div>
          <div><span className="text-xs text-slate-500">Window start</span><input type="time" value={deliv.ws} onChange={(e) => setDeliv({ ...deliv, ws: e.target.value })} className={`w-full ${inp}`} /></div>
          <div><span className="text-xs text-slate-500">Window end</span><input type="time" value={deliv.we} onChange={(e) => setDeliv({ ...deliv, we: e.target.value })} className={`w-full ${inp}`} /></div>
          {mode === 'rental' && <div><span className="text-xs text-slate-500">Deposit ($)</span><input type="number" value={deliv.deposit} onChange={(e) => setDeliv({ ...deliv, deposit: e.target.value })} className={`w-full ${inp}`} /></div>}
          <div className={mode === 'rental' ? '' : 'col-span-2'}><span className="text-xs text-slate-500">Notes</span><input value={deliv.notes} onChange={(e) => setDeliv({ ...deliv, notes: e.target.value })} placeholder="Access, parking…" className={`w-full ${inp}`} /></div>
        </div>
      </div>

      {err && <div className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-lg px-3 py-2">{err}</div>}
      <div className="flex justify-end">
        <button onClick={create} disabled={busy} className="bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-6 py-2.5 text-sm font-medium disabled:opacity-50">
          {busy ? 'Creating…' : `Create ${mode} order`}
        </button>
      </div>
    </div>
  )
}
