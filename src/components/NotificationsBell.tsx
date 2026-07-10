import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Bell, Check } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../contexts/AuthContext'

export default function NotificationsBell() {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)

  const { data } = useQuery({
    queryKey: ['notifications'],
    enabled: !!profile?.id,
    refetchInterval: 20_000, // pick up new delivery assignments on their own
    queryFn: async () => {
      const { data } = await supabase
        .from('notifications')
        .select('id,title,message,read,created_at')
        .eq('user_id', profile!.id)
        .order('created_at', { ascending: false })
        .limit(20)
      return (data ?? []) as any[]
    },
  })
  const items = data ?? []
  const unread = items.filter((n) => !n.read).length

  const markAll = useMutation({
    mutationFn: async () => {
      await supabase.from('notifications').update({ read: true }).eq('user_id', profile!.id).eq('read', false)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notifications'] }),
  })

  return (
    <div className="relative">
      <button onClick={() => setOpen((o) => !o)} className="relative p-2 rounded-full hover:bg-slate-100 text-slate-500" aria-label="Notifications">
        <Bell size={18} />
        {unread > 0 && (
          <span className="absolute -top-0.5 -right-0.5 bg-red-500 text-white text-[10px] font-bold rounded-full w-4 h-4 grid place-items-center">{unread}</span>
        )}
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setOpen(false)} />
          <div className="absolute right-0 mt-2 w-80 bg-white border border-slate-200 rounded-xl shadow-xl z-20 max-h-[70vh] overflow-auto">
            <div className="flex items-center justify-between px-4 py-2.5 border-b border-slate-100">
              <span className="font-semibold text-sm text-slate-800">Notifications</span>
              {unread > 0 && (
                <button onClick={() => markAll.mutate()} className="text-xs text-blue-600 hover:text-blue-700 flex items-center gap-1"><Check size={13} /> Mark all read</button>
              )}
            </div>
            {items.length === 0 ? (
              <div className="px-4 py-8 text-center text-slate-400 text-sm">No notifications yet</div>
            ) : items.map((n) => (
              <div key={n.id} className={`px-4 py-3 border-b border-slate-50 ${!n.read ? 'bg-blue-50/50' : ''}`}>
                <div className="flex items-start gap-2">
                  {!n.read && <span className="w-2 h-2 rounded-full bg-blue-600 mt-1.5 shrink-0" />}
                  <div className="min-w-0">
                    <div className="text-sm font-medium text-slate-800">{n.title}</div>
                    <div className="text-xs text-slate-500 whitespace-pre-line mt-0.5">{n.message}</div>
                    <div className="text-[11px] text-slate-400 mt-1">{new Date(n.created_at).toLocaleString()}</div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}
