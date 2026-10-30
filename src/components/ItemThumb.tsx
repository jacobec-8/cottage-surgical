'use client'

import { useState } from 'react'
import { Package } from 'lucide-react'

const SIZES = { xs: 'h-6 w-6', sm: 'h-7 w-7', md: 'h-9 w-9' } as const
const ICON = { xs: 12, sm: 14, md: 16 } as const

/**
 * The product's picture, small and square, shown next to its name on list
 * screens. A product with no picture (or one that fails to load) gets a plain
 * box icon so rows still line up. Decorative: the name beside it carries meaning.
 */
export default function ItemThumb({ src, size = 'sm' }: { src: string | null | undefined; size?: keyof typeof SIZES }) {
  const [broken, setBroken] = useState(false)
  const box = `${SIZES[size]} shrink-0 rounded-md border border-slate-200 bg-white`
  if (!src || broken) {
    return <span aria-hidden="true" className={`${box} grid place-items-center text-slate-300`}><Package size={ICON[size]} /></span>
  }
  return <img src={src} alt="" loading="lazy" decoding="async" onError={() => setBroken(true)} className={`${box} object-cover`} />
}
