import { CalendarDays, Check, ShieldCheck, Truck, Wrench, type LucideIcon } from 'lucide-react'
import type { Product } from '../../../lib/shop'
import { productBadges, servicePoints, splitDescription, type Badge } from '../productDetails'

const BADGE_ICONS: Record<Badge['key'], LucideIcon> = { speed: Truck, setup: Wrench, repairs: ShieldCheck, term: CalendarDays }

/** Promise badges, "About this item" points and any "Label: value" details. */
export default function ProductDetails({ p, rentable }: { p: Product; rentable: boolean }) {
  const { points, specs } = splitDescription(p.description)
  const about = points.length > 0 ? points : servicePoints(p, rentable)
  return (
    <div>
      <ul className="grid grid-cols-2 gap-3">
        {productBadges(p, rentable).map((b) => {
          const Icon = BADGE_ICONS[b.key]
          return (
            <li key={b.key} className="flex items-center gap-3 rounded-xl bg-brand-50/60 px-3 py-2.5">
              <span className="w-10 h-10 shrink-0 rounded-full bg-white text-brand-600 grid place-items-center"><Icon size={20} /></span>
              <span className="text-[13px] leading-tight text-slate-600"><strong className="block text-[14px] text-slate-900">{b.title}</strong>{b.sub}</span>
            </li>
          )
        })}
      </ul>

      {about.length > 0 && (
        <section className="mt-7">
          <h2 className="text-lg font-bold text-slate-900">About this item</h2>
          <ul className="mt-2.5 space-y-2 text-[15px] leading-relaxed text-slate-700">
            {about.map((point) => (
              <li key={point} className="flex gap-2.5"><Check size={17} strokeWidth={2.5} className="text-brand-600 shrink-0 mt-1" />{point}</li>
            ))}
          </ul>
        </section>
      )}

      {specs.length > 0 && (
        <section className="mt-6">
          <h2 className="text-lg font-bold text-slate-900">Product details</h2>
          <dl className="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-6 gap-y-1.5 text-[15px]">
            {specs.map((s) => (
              <div key={s.label} className="contents"><dt className="text-slate-500">{s.label}</dt><dd className="text-slate-800">{s.value}</dd></div>
            ))}
          </dl>
        </section>
      )}
    </div>
  )
}
