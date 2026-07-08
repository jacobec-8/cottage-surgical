import { Link } from 'react-router-dom'
import { Zap, Search, FileText, Truck, Phone } from 'lucide-react'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'

const STEPS = [
  { n: '01', icon: Search, title: 'Choose & Order', desc: 'Browse, select, and place your request in minutes. Our team confirms availability immediately. Most items are in stock and ready for same-day dispatch.' },
  { n: '02', icon: FileText, title: 'Quick Intake', desc: 'Provide your delivery address and contact details. Payment is collected at checkout — card or ACH. We handle everything else.' },
  { n: '03', icon: Truck, title: 'Delivered & Ready to Use', desc: 'A licensed technician arrives, sets everything up, and walks you through operation. No tools, no assembly — equipment is functional before we leave.' },
]

export default function HowItWorks() {
  return (
    <div className="font-poppins bg-navy min-h-screen text-white">
      <ShopHeader />
      <section className="max-w-6xl mx-auto px-4 py-20">
        <div className="text-center">
          <span className="inline-flex items-center gap-2 text-sm font-semibold text-white bg-terracotta rounded-full px-4 py-1.5">
            <Zap size={14} /> As Fast as Today
          </span>
          <h1 className="font-serif font-bold text-4xl sm:text-5xl mt-5">On-Demand — Order Now, Use Today</h1>
          <p className="text-blue-100/70 mt-4 max-w-2xl mx-auto">
            Most equipment is in stock and ready. Order before 2 PM for same-day delivery. No assembly — set up and demonstrated at your door.
          </p>
        </div>

        <div className="grid md:grid-cols-3 gap-10 mt-20">
          {STEPS.map((s) => {
            const I = s.icon
            return (
              <div key={s.n} className="relative">
                <div className="absolute -top-10 left-0 text-7xl font-serif font-bold text-white/[0.06] select-none">{s.n}</div>
                <div className="relative">
                  <span className="w-12 h-12 rounded-xl bg-terracotta/20 text-peach grid place-items-center mb-5"><I size={22} /></span>
                  <h3 className="text-xl font-bold mb-2">{s.title}</h3>
                  <p className="text-blue-100/70 text-sm leading-relaxed">{s.desc}</p>
                </div>
              </div>
            )
          })}
        </div>

        <div className="mt-16 bg-white/5 border border-white/10 rounded-2xl p-6 flex flex-col md:flex-row items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <Zap className="text-peach shrink-0" size={22} />
            <div>
              <div className="font-bold">Order before 2 PM — delivered today</div>
              <div className="text-sm text-blue-100/70">Same-day available on most items. No assembly. Ready to use on arrival.</div>
            </div>
          </div>
          <div className="flex gap-3 shrink-0">
            <Link to="/" className="bg-white/10 hover:bg-white/20 rounded-xl px-5 py-3 text-sm font-semibold">Browse Equipment</Link>
            <a href="tel:+15163679030" className="inline-flex items-center gap-2 bg-terracotta hover:opacity-90 rounded-xl px-5 py-3 text-sm font-semibold"><Phone size={15} /> Call Now</a>
          </div>
        </div>
      </section>
      <ShopFooter />
    </div>
  )
}
