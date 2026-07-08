import { useState } from 'react'
import { RotateCcw, ChevronDown } from 'lucide-react'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'

// NOTE: policy copy below is a first draft — please review/edit to match
// Cottage Surgical's actual return & refund terms before going live.
const SECTIONS = [
  { t: 'Rental Returns', b: 'When your rental ends, just call us and we’ll schedule a pickup — often same or next day. Nothing to pack or ship; our technician collects and inspects the equipment at your door.' },
  { t: 'Purchase Returns', b: 'Unopened, unused purchases may be returned within 14 days for a refund, less any delivery fee. Items must be in original, resalable condition.' },
  { t: 'Refundable Security Deposit', b: 'Rentals include a refundable security deposit, returned in full after pickup once the equipment is inspected for normal condition. Refunds go back to your original payment method.' },
  { t: 'Damaged Equipment', b: 'Normal wear is on us. Damage beyond normal use (neglect or misuse) may be deducted from the deposit — we’ll always review it with you first.' },
  { t: 'Hygiene Items', b: 'For health and safety, certain personal-care and hygiene items are non-returnable once opened. These are clearly marked at checkout.' },
]

export default function ReturnPolicy() {
  const [open, setOpen] = useState<number | null>(0)
  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />
      <section className="max-w-3xl mx-auto px-4 py-16">
        <div className="text-center mb-10">
          <div className="text-sm font-semibold tracking-wider text-terracotta uppercase">Transparent Policies</div>
          <h1 className="font-serif font-bold text-navy text-4xl sm:text-5xl mt-2">Return &amp; Refund Policy</h1>
          <p className="text-slate-500 mt-3">We make returns simple and hassle-free. No surprises.</p>
        </div>
        <div className="space-y-3">
          {SECTIONS.map((s, i) => (
            <div key={i} className="bg-white border border-slate-200 rounded-2xl overflow-hidden">
              <button onClick={() => setOpen(open === i ? null : i)} className="w-full flex items-center gap-3 px-5 py-4 text-left">
                <span className="w-9 h-9 rounded-lg bg-slate-100 text-slate-500 grid place-items-center shrink-0"><RotateCcw size={16} /></span>
                <span className="font-semibold text-navy flex-1">{s.t}</span>
                <ChevronDown size={18} className={`text-slate-400 transition shrink-0 ${open === i ? 'rotate-180' : ''}`} />
              </button>
              {open === i && <div className="px-5 pb-5 pl-[68px] text-slate-600 text-sm leading-relaxed">{s.b}</div>}
            </div>
          ))}
        </div>
      </section>
      <ShopFooter />
    </div>
  )
}
