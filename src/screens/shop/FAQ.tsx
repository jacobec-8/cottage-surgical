'use client'

import { useState } from 'react'
import { ChevronDown, MessageCircle } from 'lucide-react'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import { FAQS } from './faqs'

// NOTE: answer copy below is a sensible first draft — please review/edit to
// match Cottage Surgical's actual policies before real customers see it.

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
