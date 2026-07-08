import { Link } from 'react-router-dom'
import { MapPin, Phone, Mail } from 'lucide-react'

// Labels match the boss's design; the query maps to a root term that actually
// substring-matches the catalog (e.g. "Wheelchairs" → filter "wheelchair").
const EQUIPMENT = [
  { label: 'Wheelchairs', q: 'wheelchair' },
  { label: 'Oxygen Concentrators', q: 'oxygen' },
  { label: 'Hospital Beds', q: 'bed' },
  { label: 'Patient Lifts', q: 'lift' },
  { label: 'Knee Scooters', q: 'scooter' },
  { label: 'Seat Lift Chairs', q: 'chair' },
]
const INFO = [
  { label: 'Equipment', to: '/' },
  { label: 'How It Works', to: '/how-it-works' },
  { label: 'FAQ', to: '/faq' },
  { label: 'Return Policy', to: '/return-policy' },
  { label: 'Staff Portal', to: '/admin-login' },
]

export default function ShopFooter() {
  return (
    <footer className="bg-navy text-white font-poppins border-t border-white/10">
      <div className="max-w-7xl mx-auto px-4 py-14">
        <div className="grid gap-10 md:grid-cols-3">
          <div className="md:pr-8">
            <div className="flex items-center gap-2.5 mb-4">
              <span className="w-10 h-10 rounded-xl bg-white/10 grid place-items-center font-bold">CS</span>
              <span className="leading-tight">
                <span className="block font-bold">Cottage Surgical</span>
                <span className="block text-[11px] text-blue-100/60">Medical Equipment Specialists</span>
              </span>
            </div>
            <p className="text-sm text-blue-100/70 max-w-xs leading-relaxed">
              Quality durable medical equipment delivered to your home. Licensed technicians, private pay, same-day available.
            </p>
            <div className="mt-5 space-y-2 text-sm text-blue-100/80">
              <div className="flex items-center gap-2.5"><MapPin size={15} className="text-terracotta shrink-0" /> 8285 Jericho Tpke, Woodbury, NY 11797</div>
              <a href="tel:+15163679030" className="flex items-center gap-2.5 hover:text-white"><Phone size={15} className="text-terracotta shrink-0" /> 516-367-9030 ext 4</a>
              <a href="mailto:info@cottagesurgical.com" className="flex items-center gap-2.5 hover:text-white"><Mail size={15} className="text-terracotta shrink-0" /> info@cottagesurgical.com</a>
            </div>
          </div>

          <div>
            <div className="font-semibold mb-4">Equipment</div>
            <ul className="space-y-2.5 text-sm text-blue-100/70">
              {EQUIPMENT.map((e) => (
                <li key={e.label}><Link to={`/?q=${encodeURIComponent(e.q)}`} className="hover:text-white">{e.label}</Link></li>
              ))}
            </ul>
          </div>

          <div>
            <div className="font-semibold mb-4">Information</div>
            <ul className="space-y-2.5 text-sm text-blue-100/70">
              {INFO.map((i) => (
                <li key={i.label}><Link to={i.to} className="hover:text-white">{i.label}</Link></li>
              ))}
            </ul>
          </div>
        </div>

        <div className="border-t border-white/10 mt-12 pt-6 flex flex-col sm:flex-row justify-between gap-2 text-sm text-blue-100/50">
          <span>© 2026 Cottage Surgical. All rights reserved.</span>
          <span>Licensed DME Provider · Nassau &amp; Suffolk Counties, NY</span>
        </div>
      </div>
    </footer>
  )
}
