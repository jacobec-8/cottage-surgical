import Link from 'next/link'
import { ChevronDown } from 'lucide-react'
import { FAQS } from '../faqs'

const STEPS = [
  { title: 'Order online or call.', body: 'Before 2 PM for same-day delivery.' },
  { title: 'We deliver and set it up.', body: 'A technician assembles it and shows you how it works.' },
  { title: 'Keep it as long as you need.', body: 'It renews monthly, and repairs are free.' },
  { title: 'Call when you’re done.', body: 'We pick it up.' },
]
/** The FAQ answers that matter while looking at one rental. */
const PRODUCT_QUESTIONS = [
  'How quickly can equipment be delivered?',
  'What is the minimum rental period?',
  'What happens if equipment breaks down?',
  'Do you service my area?',
]
const PRODUCT_FAQS = FAQS.filter((f) => PRODUCT_QUESTIONS.includes(f.q))

/** "How renting works" and a few store FAQs, under a rentable product. */
export default function RentingInfo() {
  return (
    <section className="mt-12 border-t border-slate-200 pt-10 grid gap-10 lg:grid-cols-2 lg:gap-14">
      <div>
        <h2 className="font-heading font-extrabold text-navy text-2xl">How renting works</h2>
        <ol className="mt-5 space-y-4">
          {STEPS.map((s, i) => (
            <li key={s.title} className="flex gap-3.5">
              <span className="w-8 h-8 shrink-0 rounded-full bg-navy text-white font-bold grid place-items-center">{i + 1}</span>
              <span className="text-slate-700 pt-1"><strong className="text-slate-900">{s.title}</strong> {s.body}</span>
            </li>
          ))}
        </ol>
      </div>
      <div>
        <h2 className="font-heading font-extrabold text-navy text-2xl">Questions people ask</h2>
        <div className="mt-4 border-t border-slate-200">
          {PRODUCT_FAQS.map((f, i) => (
            <details key={f.q} open={i === 0} className="group border-b border-slate-200">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 py-4 font-bold text-slate-900 [&::-webkit-details-marker]:hidden">
                {f.q}<ChevronDown size={18} className="shrink-0 text-slate-400 transition-transform group-open:rotate-180" />
              </summary>
              <p className="pb-4 -mt-1 text-slate-600 leading-relaxed">{f.a}</p>
            </details>
          ))}
        </div>
        <Link href="/faq" className="inline-block mt-4 text-sm font-semibold text-brand-600 hover:underline">All questions</Link>
      </div>
    </section>
  )
}
