import { useState } from 'react'
import { ChevronDown, MessageCircle } from 'lucide-react'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'

// NOTE: answer copy below is a sensible first draft — please review/edit to
// match Cottage Surgical's actual policies before real customers see it.
const FAQS = [
  { q: 'How does renting work?', a: 'Choose your equipment, place a request, and we deliver it set up and ready to use. Rentals are month-to-month with a refundable security deposit — keep it as long as you need and we pick it up when you’re done.' },
  { q: 'What payment methods do you accept?', a: 'All major credit/debit cards and ACH bank transfers. We’re private-pay and can provide itemized receipts you can submit to insurance or an HSA/FSA.' },
  { q: 'How quickly can equipment be delivered?', a: 'Most in-stock items ordered before 2 PM are delivered the same day across Nassau and Suffolk County. Otherwise, next-day is standard.' },
  { q: 'What is the minimum rental period?', a: 'One month. After that, rentals continue month-to-month with no long-term commitment — cancel any time with a pickup.' },
  { q: 'Can I purchase instead of rent?', a: 'We’re rental-only right now. If you’d like to buy a piece of equipment outright, give us a call and we’ll help you directly.' },
  { q: 'What happens if equipment breaks down?', a: 'Call us and we’ll repair or swap the item at no charge for normal wear. Service is included for the life of the rental.' },
  { q: 'Is setup included in the rental?', a: 'Always. A licensed technician delivers, assembles, and demonstrates every item — nothing arrives in a box for you to build.' },
  { q: 'Do you service my area?', a: 'We deliver throughout Nassau and Suffolk County, NY. Not sure about your town? Call us and we’ll confirm.' },
  { q: 'Can I extend my rental?', a: 'Absolutely — rentals renew automatically each month. Keep it as long as you need; there’s no paperwork to extend.' },
]

export default function FAQ() {
  const [open, setOpen] = useState<number | null>(0)
  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />
      <section className="max-w-3xl mx-auto px-4 py-16">
        <div className="text-center mb-10">
          <div className="text-sm font-semibold tracking-wider text-terracotta uppercase">Common Questions</div>
          <h1 className="font-serif font-bold text-navy text-4xl sm:text-5xl mt-2">Frequently Asked Questions</h1>
        </div>
        <div className="space-y-3">
          {FAQS.map((f, i) => (
            <div key={i} className="bg-white border border-slate-200 rounded-2xl overflow-hidden">
              <button onClick={() => setOpen(open === i ? null : i)} className="w-full flex items-center justify-between gap-4 px-5 py-4 text-left">
                <span className="font-semibold text-navy">{f.q}</span>
                <ChevronDown size={18} className={`text-slate-400 transition shrink-0 ${open === i ? 'rotate-180' : ''}`} />
              </button>
              {open === i && <div className="px-5 pb-5 text-slate-600 text-sm leading-relaxed">{f.a}</div>}
            </div>
          ))}
        </div>
        <div className="text-center mt-10">
          <button title="AI assistant — coming soon"
            className="inline-flex items-center gap-2 bg-navy text-white rounded-full px-6 py-3 font-semibold">
            <MessageCircle size={18} /> Chat with AI Assistant
          </button>
        </div>
      </section>
      <ShopFooter />
    </div>
  )
}
