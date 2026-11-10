'use client'

import { useState } from 'react'
import { Download, FileUp } from 'lucide-react'
import { CSV_COLUMNS, CSV_TEMPLATE, csvToItems, type ImportItem } from '../../lib/productImport'
import { CATEGORIES } from '../../lib/categories'
import { SaveForm, SubmitButton } from '../../components/SaveForm'
import { addedMessage, useAddProducts, type AddTarget } from './useAddProducts'

const MAX_BYTES = 1024 * 1024

/** Upload products as a CSV (149): read, checked line by line, then added all at once. */
export default function CsvImport({ target, onAdded }: { target: AddTarget; onAdded?: () => void }) {
  const [fileName, setFileName] = useState('')
  const [items, setItems] = useState<ImportItem[]>([])
  const [problems, setProblems] = useState<{ line: number; message: string }[]>([])
  const send = useAddProducts(target, 'csv')
  const templateHref = `data:text/csv;charset=utf-8,${encodeURIComponent(CSV_TEMPLATE)}`

  const choose = async (file?: File) => {
    setItems([]); setProblems([])
    if (!file) return
    setFileName(file.name)
    if (file.size > MAX_BYTES) { setProblems([{ line: 0, message: 'That file is over 1 MB. Split it into smaller files.' }]); return }
    const read = csvToItems(await file.text(), target.location.delivers)
    setItems(read.items)
    setProblems(read.items.length === 0 && read.problems.length === 0 ? [{ line: 0, message: 'That file has no products in it.' }] : read.problems)
  }
  return (
    <SaveForm aria-label="Upload products" submitOnEnter={false} errorClassName="mt-3" savedMessage={addedMessage(target)}
      validate={() => (items.length === 0 ? [{ field: null, message: 'Choose a CSV file with your products.' }] : problems.length ? [{ field: null, message: 'Fix the lines listed above first.' }] : [])}
      onSave={() => send(items)} onSaved={() => { setItems([]); setFileName(''); onAdded?.() }}>
    <div className="space-y-4">
      <div className="rounded-xl border border-slate-200 bg-white p-4 text-sm text-slate-700">
        <p>One product per line. Columns: <span className="font-mono text-xs">{CSV_COLUMNS.join(', ')}</span>.</p>
        <ul className="mt-2 list-disc space-y-0.5 pl-5 text-slate-600">
          <li><strong>rent</strong> and <strong>sell</strong>: yes or no (one or both).</li>
          <li>Prices in dollars. A monthly price for pickup when you rent{target.location.delivers ? ', and for delivery' : ''}; a sale price when you sell.</li>
          <li><strong>stock</strong>: how many you have at {target.location.name}.</li>
          <li><strong>category</strong>: one of {CATEGORIES.join(', ')}.</li>
        </ul>
        <a href={templateHref} download="products-template.csv" className="mt-3 inline-flex min-h-10 items-center gap-1.5 rounded-lg border border-slate-300 px-3 font-medium text-slate-700 hover:bg-slate-50"><Download size={15} /> Download the template</a>
      </div>

      <label className="flex min-h-24 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-slate-300 bg-white p-4 text-center text-sm text-slate-600 hover:border-blue-400">
        <FileUp size={20} className="text-blue-600" />
        <span className="font-medium text-slate-800">{fileName || 'Choose a CSV file'}</span>
        <span className="text-xs">Saved from Excel or Google Sheets as .csv</span>
        <input type="file" accept=".csv,text/csv" className="sr-only" onChange={(e) => { void choose(e.target.files?.[0]); e.target.value = '' }} />
      </label>

      {problems.length > 0 && (
        <div role="alert" className="rounded-lg bg-red-50 p-3 text-sm text-red-700">
          <p className="font-medium">Fix these lines in your file, then choose it again:</p>
          <ul className="mt-1 space-y-0.5">{problems.slice(0, 20).map((p) => <li key={`${p.line}:${p.message}`}>{p.line ? `Line ${p.line}: ` : ''}{p.message}</li>)}</ul>
          {problems.length > 20 && <p className="mt-1">…and {problems.length - 20} more.</p>}
        </div>
      )}

      {items.length > 0 && problems.length === 0 && (
        <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white">
          <table className="w-full text-left text-sm">
            <thead className="bg-slate-50 text-xs text-slate-500"><tr><th className="px-3 py-2">Product</th><th className="px-3 py-2">Category</th><th className="px-3 py-2">Rent (pickup / delivered)</th><th className="px-3 py-2">Sale</th><th className="px-3 py-2">Stock</th></tr></thead>
            <tbody className="divide-y divide-slate-100">
              {items.slice(0, 50).map((it, i) => (
                <tr key={i}><td className="px-3 py-2 font-medium">{it.name}</td><td className="px-3 py-2 capitalize">{it.category}</td>
                  <td className="px-3 py-2">{it.rent ? `$${it.pickup_price}${target.location.delivers ? ` / $${it.delivery_price}` : ''}` : '—'}</td>
                  <td className="px-3 py-2">{it.sell ? `$${it.sale_price}` : '—'}</td><td className="px-3 py-2">{it.stock}</td></tr>
              ))}
            </tbody>
          </table>
          {items.length > 50 && <p className="px-3 py-2 text-xs text-slate-500">…and {items.length - 50} more.</p>}
        </div>
      )}

      <div className="flex justify-end">
        <SubmitButton disabled={items.length === 0 || problems.length > 0} className="min-h-11 rounded-lg bg-blue-600 px-5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          {(pending) => (pending ? 'Adding…' : `Add ${items.length || ''} product${items.length === 1 ? '' : 's'}`)}
        </SubmitButton>
      </div>
    </div>
    </SaveForm>
  )
}
