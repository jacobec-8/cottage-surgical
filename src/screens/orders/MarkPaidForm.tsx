'use client'

import { useState } from 'react'
import { parseTaken } from './paymentDue'

const INPUT = 'w-28 rounded-md border border-slate-300 px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

/**
 * Before an order is marked paid, staff confirm what they actually took. It's
 * saved as a money record with their name and the time, and can't be edited.
 */
export default function MarkPaidForm({ method, due, deposit, pending, onConfirm, onCancel }: {
  method: string; due: number; deposit: number; pending: boolean
  onConfirm: (amount: number, deposit: number | null) => void; onCancel: () => void
}) {
  const [amount, setAmount] = useState(due.toFixed(2))
  const [depositTaken, setDepositTaken] = useState(deposit ? deposit.toFixed(2) : '')
  const [problem, setProblem] = useState<string | null>(null)

  const confirm = () => {
    const taken = parseTaken(amount)
    if (typeof taken === 'string') { setProblem(taken); return }
    let dep: number | null = null
    if (deposit > 0) {
      const parsed = depositTaken.trim() === '' ? 0 : parseTaken(depositTaken)
      if (typeof parsed === 'string') { setProblem(`Deposit: ${parsed}`); return }
      dep = parsed
    }
    setProblem(null)
    onConfirm(taken, dep)
  }

  return (
    <div className="mt-2 rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm" role="group" aria-label="Confirm payment taken">
      <div className="mb-2 font-medium text-slate-800">{method}: how much did you take?</div>
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-1.5 text-slate-600">Payment $
          <input autoFocus inputMode="decimal" aria-label="Amount taken" value={amount} onChange={(e) => setAmount(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') confirm(); if (e.key === 'Escape') { e.stopPropagation(); onCancel() } }} className={INPUT} />
        </label>
        {deposit > 0 && (
          <label className="flex items-center gap-1.5 text-slate-600">Deposit $
            <input inputMode="decimal" aria-label="Deposit taken" value={depositTaken} onChange={(e) => setDepositTaken(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') confirm(); if (e.key === 'Escape') { e.stopPropagation(); onCancel() } }} className={INPUT} />
          </label>
        )}
      </div>
      <div className="mt-1 text-xs text-slate-500">
        Due: ${due.toFixed(2)}{deposit > 0 ? ` plus a $${deposit.toFixed(2)} deposit` : ''}. Change it if you took something different.
      </div>
      {problem && <div role="alert" className="mt-1 text-xs text-red-600">{problem}</div>}
      <div className="mt-2 flex gap-2">
        <button type="button" onClick={confirm} disabled={pending} className="rounded-md bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          {pending ? 'Saving…' : 'Confirm paid'}
        </button>
        <button type="button" onClick={onCancel} disabled={pending} className="rounded-md px-2 py-1 text-xs text-slate-600 hover:bg-white">Cancel</button>
      </div>
    </div>
  )
}
