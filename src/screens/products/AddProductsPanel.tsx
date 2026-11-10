'use client'

import { useState } from 'react'
import { FileSpreadsheet, List, PencilLine } from 'lucide-react'
import QuickProductForm from '../setup/QuickProductForm'
import CsvImport from './CsvImport'
import StarterPicker from './StarterPicker'
import type { AddTarget } from './useAddProducts'

type Mode = 'list' | 'csv' | 'hand'
const MODES: { key: Mode; label: string; icon: typeof List }[] = [
  { key: 'list', label: 'Choose from list', icon: List },
  { key: 'csv', label: 'Upload a CSV', icon: FileSpreadsheet },
  { key: 'hand', label: 'Add one by hand', icon: PencilLine },
]

/** The three ways to add products (149): the starter list, a CSV, or one by hand. Setup guide and Inventory. */
export default function AddProductsPanel({ target, onAdded, hideNames }: { target: AddTarget; onAdded?: () => void; hideNames?: ReadonlySet<string> }) {
  const [mode, setMode] = useState<Mode>('list')
  return (
    <div>
      <div role="tablist" aria-label="How to add products" className="mb-4 flex flex-wrap gap-2">
        {MODES.map(({ key, label, icon: Icon }) => (
          <button key={key} type="button" role="tab" aria-selected={mode === key} onClick={() => setMode(key)}
            className={`inline-flex min-h-11 items-center gap-2 rounded-lg border px-4 text-sm font-medium ${mode === key ? 'border-blue-600 bg-blue-50 text-blue-700' : 'border-slate-300 bg-white text-slate-700 hover:bg-slate-50'}`}>
            <Icon size={16} /> {label}
          </button>
        ))}
      </div>
      {mode === 'list' && <StarterPicker target={target} onAdded={onAdded} hideNames={hideNames} />}
      {mode === 'csv' && <CsvImport target={target} onAdded={onAdded} />}
      {mode === 'hand' && <QuickProductForm target={target} />}
    </div>
  )
}
