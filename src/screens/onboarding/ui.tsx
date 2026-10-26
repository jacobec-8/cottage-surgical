import type { InputHTMLAttributes, ReactNode } from 'react'

export const INPUT = 'w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 focus:outline-none focus:ring-2 focus:ring-blue-500'
export const PRIMARY = 'inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50'
export const SECONDARY = 'inline-flex min-h-11 items-center justify-center gap-2 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50'

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return <label className="block"><span className="mb-1.5 block text-xs font-medium text-slate-600">{label}</span>{children}</label>
}

type TextFieldProps = { label: string; value: string; onChange: (value: string) => void } & Omit<InputHTMLAttributes<HTMLInputElement>, 'onChange' | 'value'>
export function TextField({ label, value, onChange, required, ...props }: TextFieldProps) {
  return (
    <Field label={`${label}${required ? ' *' : ''}`}>
      <input {...props} onWheel={(e) => { if (props.type === 'number') e.currentTarget.blur() }} aria-label={label} required={required} className={INPUT} value={value} onChange={(e) => onChange(e.target.value)} />
    </Field>
  )
}

export function Note({ children }: { children: ReactNode }) {
  return <p className="rounded-xl bg-blue-50 p-4 text-sm leading-6 text-blue-800">{children}</p>
}

export function ReviewCard({ title, edit, children }: { title: string; edit: () => void; children: ReactNode }) {
  return (
    <section className="rounded-xl border border-slate-200 p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h3 className="font-medium text-slate-900">{title}</h3>
        <button type="button" onClick={edit} className="text-sm font-medium text-blue-600" aria-label={`Edit ${title}`}>Edit</button>
      </div>
      <div className="space-y-1 text-sm text-slate-600">{children}</div>
    </section>
  )
}

export function pricePlaceholder(value: number | null) { return value == null ? 'No catalog price' : `Catalog: $${Number(value).toFixed(2)}` }
export function priceText(override: string, fallback?: number | null) {
  const value = override === '' ? fallback : Number(override)
  return value == null ? 'price not set' : `$${Number(value).toFixed(2)}/mo${override === '' ? ' (catalog)' : ''}`
}
