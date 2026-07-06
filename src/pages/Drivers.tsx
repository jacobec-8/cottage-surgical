import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Truck } from 'lucide-react'
import { supabase } from '../lib/supabase'

type Driver = { id: string; first_name: string; last_name: string; phone: string | null; status: string }

export default function Drivers() {
  const qc = useQueryClient()
  const [adding, setAdding] = useState(false)
  const [f, setF] = useState({ first_name: '', last_name: '', phone: '' })
  const [err, setErr] = useState('')

  const { data, isLoading } = useQuery({
    // Distinct key from the dispatch pickers (['drivers','active']) so this
    // full-roster query doesn't share their cache and leak inactive drivers /
    // blank columns between pages. invalidate(['drivers']) still refreshes both.
    queryKey: ['drivers', 'all'],
    queryFn: async () => {
      const { data, error } = await supabase.from('drivers').select('id,first_name,last_name,phone,status').order('first_name')
      if (error) throw error
      return data as Driver[]
    },
  })

  const add = useMutation({
    mutationFn: async () => {
      if (!f.first_name.trim() || !f.last_name.trim()) throw new Error('First and last name are required.')
      const { error } = await supabase.from('drivers').insert({
        first_name: f.first_name.trim(), last_name: f.last_name.trim(), phone: f.phone.trim() || null, status: 'active',
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['drivers'] })
      setAdding(false); setF({ first_name: '', last_name: '', phone: '' }); setErr('')
    },
    onError: (e) => setErr((e as Error).message),
  })

  const inp = 'border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className="max-w-2xl">
      <div className="flex items-start justify-between mb-1">
        <h1 className="text-2xl font-semibold">Drivers</h1>
        <button onClick={() => setAdding((v) => !v)} className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-3 py-2 text-sm">
          <Plus size={16} /> Add Driver
        </button>
      </div>
      <p className="text-slate-500 text-sm mb-5">Delivery drivers available for dispatch.</p>

      {adding && (
        <div className="bg-white border border-slate-200 rounded-xl p-4 mb-4 grid grid-cols-3 gap-3">
          <input placeholder="First name" value={f.first_name} onChange={(e) => setF({ ...f, first_name: e.target.value })} className={inp} />
          <input placeholder="Last name" value={f.last_name} onChange={(e) => setF({ ...f, last_name: e.target.value })} className={inp} />
          <input placeholder="Phone" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} className={inp} />
          {err && <div className="col-span-3 text-sm text-red-600">{err}</div>}
          <div className="col-span-3 flex justify-end gap-2">
            <button onClick={() => setAdding(false)} className="px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-100 rounded-lg">Cancel</button>
            <button onClick={() => add.mutate()} disabled={add.isPending} className="px-3 py-1.5 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg disabled:opacity-50">
              {add.isPending ? 'Saving…' : 'Save'}
            </button>
          </div>
        </div>
      )}

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {data && data.length === 0 && <div className="text-slate-500 text-sm">No drivers yet — add one to start dispatching deliveries.</div>}
      <div className="space-y-2">
        {data?.map((d) => (
          <div key={d.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center gap-3">
            <div className="w-9 h-9 rounded-lg bg-slate-100 grid place-items-center text-slate-500"><Truck size={18} /></div>
            <div className="flex-1">
              <div className="font-medium">{d.first_name} {d.last_name}</div>
              <div className="text-sm text-slate-500">{d.phone || 'no phone'}</div>
            </div>
            <span className="text-xs px-2 py-1 rounded-full bg-emerald-100 text-emerald-700 capitalize">{d.status}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
