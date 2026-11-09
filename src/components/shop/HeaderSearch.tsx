'use client'

import { useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { ChevronDown, Search } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { WEBSITE_PRODUCTS } from '../../lib/shop'
import { distinctCategories, headerSearchHref } from './headerNav'

export type HeaderSearchHandler = (words: string, cat: string) => void

/**
 * The top bar search: a category picker, the words box and a search button.
 * On the landing page `onSearch` applies it at once; anywhere else it opens the
 * landing page with ?q= / ?cat=. If the categories can't load, the picker offers "All" only.
 */
export default function HeaderSearch({ onSearch, className = '' }: { onSearch?: HeaderSearchHandler; className?: string }) {
  const router = useRouter()
  const [words, setWords] = useState('')
  const [cat, setCat] = useState('')
  const { data: categories = [] } = useQuery({
    queryKey: ['shop_categories'],
    queryFn: async () => {
      const { data, error } = await supabase.from(WEBSITE_PRODUCTS).select('category')
      if (error) throw error
      return distinctCategories(data ?? [])
    },
    staleTime: 5 * 60_000,
  })

  const submit = (e: FormEvent) => {
    e.preventDefault()
    onSearch?.(words.trim(), cat)
    router.push(headerSearchHref(words, cat), { scroll: !onSearch })
  }

  return (
    <form role="search" noValidate onSubmit={submit}
      className={`flex h-11 lg:h-12 min-w-0 overflow-hidden rounded-lg bg-white focus-within:ring-[3px] focus-within:ring-peach ${className}`}>
      <label className="relative hidden sm:flex items-center shrink-0 bg-slate-100 hover:bg-slate-200 border-r border-slate-300 text-slate-700 text-sm">
        <span className="sr-only">Search in</span>
        <select value={cat} onChange={(e) => setCat(e.target.value)}
          className="appearance-none bg-transparent h-full pl-3.5 pr-8 max-w-[11rem] truncate cursor-pointer outline-none">
          <option value="">All</option>
          {categories.map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
        <ChevronDown size={14} className="pointer-events-none absolute right-3" />
      </label>
      <input value={words} onChange={(e) => setWords(e.target.value)} aria-label="Search equipment"
        placeholder="Search wheelchairs, hospital beds, walkers…"
        className="flex-1 min-w-0 px-4 text-[16px] lg:text-[17px] text-slate-900 placeholder:text-slate-400 outline-none" />
      <button type="submit" aria-label="Search" className="w-14 lg:w-[60px] shrink-0 grid place-items-center bg-peach hover:brightness-95 text-navy">
        <Search size={22} strokeWidth={2.5} />
      </button>
    </form>
  )
}
