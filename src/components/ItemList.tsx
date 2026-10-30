'use client'

import ItemThumb from './ItemThumb'

export type ListedItem = { quantity: number; equipment: { name: string; image_url?: string | null } | null }

/** An order's items as "picture · 2× name", wrapping onto more lines when needed. */
export default function ItemList({ items, className = '' }: { items: readonly ListedItem[]; className?: string }) {
  if (items.length === 0) return null
  return (
    <ul className={`flex flex-wrap gap-x-4 gap-y-1.5 text-sm text-slate-700 ${className}`}>
      {items.map((li, i) => (
        <li key={i} className="flex min-w-0 items-center gap-2">
          <ItemThumb src={li.equipment?.image_url} />
          <span className="min-w-0">
            {li.quantity > 1 && <span className="text-slate-500">{li.quantity}× </span>}
            {li.equipment?.name ?? 'Item'}
          </span>
        </li>
      ))}
    </ul>
  )
}
