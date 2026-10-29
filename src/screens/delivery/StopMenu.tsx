'use client'

import { useEffect, useRef, useState } from 'react'
import { MoreHorizontal } from 'lucide-react'

export type StopMenuItem = { label: string; onSelect: () => void; disabled?: boolean }

/** Rarely-needed stop actions, kept out of the way behind "⋯". */
export default function StopMenu({ items }: { items: StopMenuItem[] }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onDown = (e: globalThis.MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false) }
    const onKey = (e: globalThis.KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  if (items.length === 0) return null
  return (
    <div ref={ref} className="relative">
      <button type="button" aria-label="More actions" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}
        className="grid h-9 w-9 place-items-center rounded-lg border border-slate-300 bg-white text-slate-600 hover:bg-slate-50">
        <MoreHorizontal size={16} />
      </button>
      {open && (
        <div role="menu" className="absolute right-0 z-20 mt-1 w-60 rounded-lg border border-slate-200 bg-white py-1 shadow-lg">
          {items.map((item) => (
            <button key={item.label} type="button" role="menuitem" disabled={item.disabled}
              onClick={() => { setOpen(false); item.onSelect() }}
              className="block w-full px-3 py-2 text-left text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50">
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
