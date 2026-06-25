const STATUS: Record<string, string> = {
  active: 'bg-emerald-100 text-emerald-700',
  overdue: 'bg-red-100 text-red-700',
  scheduled: 'bg-blue-100 text-blue-700',
  delivered: 'bg-indigo-100 text-indigo-700',
  pickup_scheduled: 'bg-amber-100 text-amber-700',
  en_route: 'bg-blue-100 text-blue-700',
  completed: 'bg-emerald-100 text-emerald-700',
  closed: 'bg-slate-100 text-slate-600',
  open: 'bg-slate-100 text-slate-600',
  pending: 'bg-slate-100 text-slate-600',
  cancelled: 'bg-slate-100 text-slate-500',
}

export function statusClass(s: string): string {
  return STATUS[s] || 'bg-slate-100 text-slate-600'
}

export function statusLabel(s: string): string {
  return (s || '').replace(/_/g, ' ')
}
