import { useState } from 'react'

const STEPS = [
  { n: 1, title: 'Patient Intake', desc: 'Name, DOB, insurance, address' },
  { n: 2, title: 'Equipment Cart', desc: 'Select rental items' },
  { n: 3, title: 'Payment Authorization', desc: 'Card or ACH on file' },
  { n: 4, title: 'Schedule Delivery', desc: 'Date, window, driver assignment' },
]

export default function NewOrder() {
  const [mode, setMode] = useState<'order' | 'pickup'>('order')
  const [type, setType] = useState<'rental' | 'purchase'>('rental')

  return (
    <div className="max-w-2xl">
      <h1 className="text-xl font-semibold mb-1">New Order</h1>
      <p className="text-slate-500 text-sm mb-6">Start a new order or schedule a pickup.</p>

      <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1 mb-4">
        {(['order', 'pickup'] as const).map((m) => (
          <button
            key={m}
            onClick={() => setMode(m)}
            className={`px-4 py-1.5 text-sm rounded-md ${mode === m ? 'bg-slate-900 text-white' : 'text-slate-600'}`}
          >
            {m === 'order' ? 'New Order' : 'Schedule Pickup'}
          </button>
        ))}
      </div>

      {mode === 'order' && (
        <>
          <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1 mb-6 ml-3">
            {(['rental', 'purchase'] as const).map((t) => (
              <button
                key={t}
                onClick={() => setType(t)}
                className={`px-4 py-1.5 text-sm rounded-md capitalize ${type === t ? 'bg-slate-900 text-white' : 'text-slate-600'}`}
              >
                {t}
              </button>
            ))}
          </div>

          <div className="bg-white border border-slate-200 rounded-xl p-6">
            <p className="text-sm text-slate-600 mb-5">
              {type === 'rental'
                ? 'Begin the intake process for a new DME rental. Monthly billing starts on delivery and continues until pickup is complete.'
                : 'Begin the intake process for a new DME purchase. A one-time charge is collected at checkout — no recurring billing.'}
            </p>
            <ol className="space-y-3 mb-6">
              {STEPS.map((s) => (
                <li key={s.n} className="flex items-start gap-3">
                  <span className="w-6 h-6 rounded-full bg-slate-900 text-white text-xs grid place-items-center shrink-0">
                    {s.n}
                  </span>
                  <div>
                    <div className="text-sm font-medium">{s.title}</div>
                    <div className="text-xs text-slate-500">{s.desc}</div>
                  </div>
                </li>
              ))}
            </ol>
            <button className="bg-slate-900 text-white rounded-lg px-4 py-2 text-sm">
              Start {type === 'rental' ? 'Rental' : 'Purchase'} Intake
            </button>
            <p className="text-xs text-slate-400 mt-3">Intake wizard wiring comes next.</p>
          </div>
        </>
      )}

      {mode === 'pickup' && (
        <div className="bg-white border border-slate-200 rounded-xl p-6 text-sm text-slate-600">
          Select an active rental and schedule its pickup (date, window, driver). Coming next.
        </div>
      )}
    </div>
  )
}
