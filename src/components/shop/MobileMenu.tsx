'use client'

import { useEffect } from 'react'
import Link from 'next/link'
import { Phone, X } from 'lucide-react'
import { CATEGORY_LINKS, INFO_LINKS, type HeaderLink } from './headerNav'

/** The phone menu: every top bar link in a panel that slides in from the left. */
export default function MobileMenu({ open, onClose, onSearch }: { open: boolean; onClose: () => void; onSearch?: (q: string) => void }) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  const item = (l: HeaderLink) => (
    <li key={l.href}>
      <Link href={l.href} onClick={() => { if (l.q && onSearch) onSearch(l.q); onClose() }}
        className="block px-5 py-3 text-[16px] text-slate-800 hover:bg-slate-50">{l.label}</Link>
    </li>
  )

  return (
    <>
      {open && <div className="fixed inset-0 bg-black/40 z-40" onClick={onClose} />}
      <aside role="dialog" aria-modal="true" aria-label="Menu" inert={!open}
        className={`fixed top-0 left-0 h-full w-[85%] max-w-[340px] bg-white z-50 shadow-2xl flex flex-col transition-[transform,visibility] duration-300 motion-reduce:transition-none ${open ? 'visible translate-x-0' : 'invisible -translate-x-full'}`}>
        <div className="bg-navy text-white px-5 h-14 flex items-center justify-between shrink-0">
          <span className="font-heading font-bold">Shop equipment</span>
          <button onClick={onClose} aria-label="Close menu" className="w-11 h-11 -mr-3 grid place-items-center rounded hover:bg-white/10"><X size={22} /></button>
        </div>
        <nav className="flex-1 overflow-y-auto py-2">
          <div className="px-5 pt-3 pb-1 text-xs font-bold uppercase tracking-wide text-slate-500">Categories</div>
          <ul>{CATEGORY_LINKS.map(item)}</ul>
          <div className="mx-5 my-2 border-t border-slate-200" />
          <ul>{INFO_LINKS.map(item)}</ul>
        </nav>
        <div className="border-t border-slate-200 p-5 flex items-center justify-between shrink-0">
          <a href="tel:+15163679030" className="inline-flex items-center gap-2 font-semibold text-brand-600"><Phone size={16} /> (516) 367-9030</a>
          <Link href="/admin-login" onClick={onClose} className="text-xs text-slate-400 hover:text-slate-700">Staff</Link>
        </div>
      </aside>
    </>
  )
}
