'use client'

import { useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { MoreHorizontal } from 'lucide-react'

/** Room the menu needs below its button before it opens upward instead. */
const MENU_ROOM_PX = 140

export type StopMenuItem = { label: string; onSelect: () => void; disabled?: boolean }

/** Rarely-needed stop actions, kept out of the way behind "⋯". */
export default function StopMenu({ items }: { items: StopMenuItem[] }) {
  const [open, setOpen] = useState(false)
  const [up, setUp] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const menuItems = () => Array.from(ref.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)') ?? [])

  const close = (refocus: boolean) => {
    setOpen(false)
    if (refocus) trigger.current?.focus()
  }

  useEffect(() => {
    if (!open) return
    menuItems()[0]?.focus()
    const onDown = (e: globalThis.MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false) }
    const onFocus = (e: FocusEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false) }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('focusin', onFocus)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('focusin', onFocus)
    }
  }, [open])

  const toggle = () => {
    const rect = trigger.current?.getBoundingClientRect()
    setUp(Boolean(rect && window.innerHeight - rect.bottom < MENU_ROOM_PX))
    setOpen(!open)
  }

  const onMenuKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const list = menuItems()
    const at = list.indexOf(document.activeElement as HTMLButtonElement)
    const move = (i: number) => { e.preventDefault(); list[(i + list.length) % list.length]?.focus() }
    if (e.key === 'Escape') { e.preventDefault(); close(true) }
    else if (e.key === 'ArrowDown') move(at + 1)
    else if (e.key === 'ArrowUp') move(at - 1)
    else if (e.key === 'Home') move(0)
    else if (e.key === 'End') move(list.length - 1)
  }

  if (items.length === 0) return null
  return (
    <div ref={ref} className="relative">
      <button ref={trigger} type="button" aria-label="More actions" aria-haspopup="menu" aria-expanded={open} onClick={toggle}
        className="grid h-9 w-9 place-items-center rounded-lg border border-slate-300 bg-white text-slate-600 hover:bg-slate-50">
        <MoreHorizontal size={16} />
      </button>
      {open && (
        <div role="menu" onKeyDown={onMenuKey} className={`absolute right-0 z-20 w-60 ${up ? 'bottom-full mb-1' : 'top-full mt-1'} rounded-lg border border-slate-200 bg-white py-1 shadow-lg`}>
          {items.map((item) => (
            <button key={item.label} type="button" role="menuitem" tabIndex={-1} disabled={item.disabled}
              onClick={() => { close(true); item.onSelect() }}
              className="block w-full px-3 py-2 text-left text-sm text-slate-700 hover:bg-slate-50 focus:bg-slate-100 focus:outline-none disabled:opacity-50">
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
