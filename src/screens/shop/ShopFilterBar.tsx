'use client'

import type { ReactNode } from 'react'
import { X } from 'lucide-react'
import { ALL_CATEGORIES, activeFilterCount, noMatchMessage, type ShopFilter } from './shopFilter'

type Pick = (cat: string) => void

function Chip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button type="button" onClick={onClick} aria-pressed={active}
      className={`text-sm rounded-full px-4 py-1.5 border capitalize ${active ? 'bg-brand-600 border-brand-600 text-white' : 'bg-white border-slate-200 text-slate-600 hover:border-brand-300'}`}>
      {children}
    </button>
  )
}

/** Category chips plus the active search words, side by side so a combination is never hidden. */
export function CategoryChips({ categories, filter, onPick, onClearSearch }: {
  categories: readonly string[]; filter: ShopFilter; onPick: Pick; onClearSearch: () => void
}) {
  const words = filter.query.trim()
  if (categories.length === 0 && !words) return null
  return (
    <div role="group" aria-label="Filter by category" className="flex flex-wrap items-center gap-2 mb-8">
      {categories.length > 0 && (
        <>
          <Chip active={filter.cat === ALL_CATEGORIES} onClick={() => onPick(ALL_CATEGORIES)}>All</Chip>
          {categories.map((c) => <Chip key={c} active={filter.cat === c} onClick={() => onPick(c)}>{c}</Chip>)}
        </>
      )}
      {words && (
        <button type="button" onClick={onClearSearch} aria-label={`Clear search “${words}”`}
          className="inline-flex items-center gap-1.5 text-sm rounded-full px-3 py-1.5 border border-brand-200 bg-brand-50 text-brand-700 hover:bg-brand-100">
          <span>Search: <span className="font-semibold">{words}</span></span>
          <X size={14} aria-hidden="true" />
        </button>
      )}
    </div>
  )
}

function Action({ onClick, primary, children }: { onClick: () => void; primary?: boolean; children: ReactNode }) {
  return (
    <button type="button" onClick={onClick}
      className={`text-sm font-semibold rounded-lg px-4 py-2 ${primary ? 'bg-brand-600 hover:bg-brand-700 text-white' : 'border border-slate-300 text-slate-700 hover:border-brand-300'}`}>
      {children}
    </button>
  )
}

/** Nothing matched: say which narrowings did it and offer one click out of each. */
export function NoMatches({ filter, onPick, onClearSearch, onShowAll }: {
  filter: ShopFilter; onPick: Pick; onClearSearch: () => void; onShowAll: () => void
}) {
  const active = activeFilterCount(filter)
  return (
    <div role="status" className="rounded-xl border border-slate-200 bg-white px-5 py-6 text-center">
      <p className="text-slate-700 font-medium">{noMatchMessage(filter)}</p>
      {active > 0 && (
        <div className="mt-3 flex flex-wrap justify-center gap-2">
          {filter.query.trim() && <Action onClick={onClearSearch}>Clear search</Action>}
          {filter.cat !== ALL_CATEGORIES && <Action onClick={() => onPick(ALL_CATEGORIES)}>All categories</Action>}
          {active > 1 && <Action onClick={onShowAll} primary>Show all equipment</Action>}
        </div>
      )}
    </div>
  )
}
