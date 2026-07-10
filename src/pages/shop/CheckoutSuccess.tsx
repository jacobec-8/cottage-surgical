import { useEffect, useRef, useState } from 'react'
import { useSearchParams, Link } from 'react-router-dom'
import { CheckCircle, Loader2, AlertCircle, Phone } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useCart } from '../../components/shop/CartContext'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'

type State = 'checking' | 'paid' | 'unpaid' | 'error'

export default function CheckoutSuccess() {
  const [sp] = useSearchParams()
  const ref = sp.get('ref')
  const { clear } = useCart()
  const [state, setState] = useState<State>('checking')
  const ran = useRef(false)

  useEffect(() => {
    if (ran.current) return
    ran.current = true
    if (!ref) { setState('error'); return }
    ;(async () => {
      // Square can take a moment to settle the order after redirect — retry a few times.
      for (let attempt = 0; attempt < 4; attempt++) {
        const { data, error } = await supabase.rpc('verify_stripe_payment', { p_order_id: ref })
        if (!error && data?.ok && data.paid) { clear(); setState('paid'); return }
        if (error || !data?.ok) { setState('error'); return }
        await new Promise((r) => setTimeout(r, 2000))
      }
      setState('unpaid')
    })()
  }, [ref, clear])

  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />
      <section className="max-w-xl mx-auto px-4 py-20 text-center">
        {state === 'checking' && (
          <>
            <Loader2 className="mx-auto text-navy animate-spin mb-4" size={44} />
            <h1 className="font-serif font-bold text-navy text-3xl">Confirming your payment…</h1>
            <p className="text-slate-500 mt-2">One moment while we check with Square.</p>
          </>
        )}
        {state === 'paid' && (
          <>
            <CheckCircle className="mx-auto text-emerald-600 mb-4" size={48} />
            <h1 className="font-serif font-bold text-navy text-3xl">Payment received — thank you!</h1>
            <p className="text-slate-600 mt-3">Your purchase is confirmed. Our team will reach out to schedule your same-day delivery and setup.</p>
            <Link to="/" className="inline-block mt-6 bg-navy text-white rounded-lg px-6 py-3 font-semibold">Back to shop</Link>
          </>
        )}
        {state === 'unpaid' && (
          <>
            <AlertCircle className="mx-auto text-amber-500 mb-4" size={48} />
            <h1 className="font-serif font-bold text-navy text-3xl">We couldn’t confirm your payment yet</h1>
            <p className="text-slate-600 mt-3">If you just completed payment, give it a minute and refresh. If you didn’t finish, your card was not charged.</p>
            <div className="flex gap-3 justify-center mt-6">
              <button onClick={() => location.reload()} className="bg-navy text-white rounded-lg px-6 py-3 font-semibold">Refresh</button>
              <a href="tel:+15163679030" className="inline-flex items-center gap-2 border border-terracotta text-terracotta rounded-lg px-6 py-3 font-semibold"><Phone size={16} /> Call us</a>
            </div>
          </>
        )}
        {state === 'error' && (
          <>
            <AlertCircle className="mx-auto text-red-500 mb-4" size={48} />
            <h1 className="font-serif font-bold text-navy text-3xl">Something went wrong</h1>
            <p className="text-slate-600 mt-3">We couldn’t confirm this order. Please call us and we’ll sort it out right away.</p>
            <a href="tel:+15163679030" className="inline-flex items-center gap-2 mt-6 bg-terracotta text-white rounded-lg px-6 py-3 font-semibold"><Phone size={16} /> Call us</a>
          </>
        )}
      </section>
      <ShopFooter />
    </div>
  )
}
