'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useEffect, useId, useRef, useState } from 'react'
import { ArrowUpRight, Loader2, MessageCircle, Send, Sparkles, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { publicSupabase } from '../../lib/publicSupabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import { answerCatalogQuestion, customerAssistantAllowed, type CatalogContext, type CatalogReply } from '../../lib/catalogAssistant'
import { useCart } from './CartContext'

/** Resolve the session first, including on public pages opened by an internal user. */
export default function CustomerAssistant() {
  const [session, setSession] = useState<{ ready: boolean; userId: string | null }>({ ready: false, userId: null })
  const [profile, setProfile] = useState<{ userId: string; role: string | null; active: boolean } | null>(null)
  useEffect(() => {
    let alive = true, authEventReceived = false
    const { data } = supabase.auth.onAuthStateChange((_event, next) => {
      authEventReceived = true
      if (alive) {
        setProfile(null)
        setSession({ ready: true, userId: next?.user.id ?? null })
      }
    })
    void supabase.auth.getSession().then(({ data, error }) => {
      if (alive && !authEventReceived && !error) setSession({ ready: true, userId: data.session?.user.id ?? null })
    }).catch(() => { /* Unknown session stays hidden. */ })
    return () => { alive = false; data.subscription.unsubscribe() }
  }, [])
  useEffect(() => {
    if (!session.userId) return
    let alive = true
    const id = session.userId
    void supabase.from('profiles').select('role,is_active').eq('id', id).maybeSingle().then(({ data, error }) => {
      if (alive) setProfile({ userId: id, role: error ? null : data?.role ?? null, active: !error && data?.is_active === true })
    }, () => {
      if (alive) setProfile({ userId: id, role: null, active: false })
    })
    return () => { alive = false }
  }, [session])
  if (!session.ready || (session.userId && profile?.userId !== session.userId)) return null
  if (!customerAssistantAllowed(session.userId, profile?.role ?? null, profile?.active)) return null
  return <CatalogChat />
}

type Turn = { id: number; role: 'user'; text: string } | { id: number; role: 'assistant'; reply: CatalogReply }
const STARTERS = ['Show me the equipment list', 'Wheelchair rental options', 'What can I buy online?', 'What is in stock?']

function CatalogChat() {
  const { open: cartOpen } = useCart()
  const pathname = usePathname(), panelId = useId()
  const [open, setOpen] = useState(false), [input, setInput] = useState('')
  const [turns, setTurns] = useState<Turn[]>([]), [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null)
  const context = useRef<CatalogContext | undefined>(undefined), request = useRef<AbortController | null>(null)
  const textInput = useRef<HTMLTextAreaElement>(null), launcher = useRef<HTMLButtonElement>(null), scrollArea = useRef<HTMLDivElement>(null)
  const shouldFollow = useRef(true), ids = useRef(0)
  useEffect(() => () => { request.current?.abort(); request.current = null }, [])
  useEffect(() => { if (open && !cartOpen) textInput.current?.focus() }, [open, cartOpen])
  useEffect(() => { const area = scrollArea.current; if (area && shouldFollow.current) area.scrollTop = area.scrollHeight }, [turns, busy, error])
  const close = () => { setOpen(false); requestAnimationFrame(() => launcher.current?.focus()) }

  async function send(text = input) {
    const message = text.trim().slice(0, 500)
    if (!message || request.current) return
    const controller = new AbortController(); request.current = controller
    setInput(''); setError(null); setBusy(true); shouldFollow.current = true
    setTurns(previous => [...previous.slice(-19), { id: ++ids.current, role: 'user', text: message }])
    const timeout = window.setTimeout(() => controller.abort(), 15_000)
    try {
      // Anonymous catalog reads never inherit staff access or request private stock counts.
      const products: Product[] = []
      for (let page = 0; ; page++) {
        const { data, error } = await publicSupabase.from('equipment_items').select(PRODUCT_FIELDS)
          .eq('is_active', true).eq('storefront_listed', true).order('name').order('id')
          .range(page * 500, (page + 1) * 500 - 1).abortSignal(controller.signal)
        if (error) throw error
        products.push(...((data ?? []) as unknown as Product[]))
        if ((data?.length ?? 0) < 500) break
        if (page >= 19) throw new Error('Catalog too large')
      }
      if (controller.signal.aborted) throw new Error('Aborted')
      const handle = pathname.startsWith('/product/') ? decodeURIComponent(pathname.slice('/product/'.length)) : undefined
      const reply = answerCatalogQuestion(message, products, context.current, handle); context.current = reply.context
      setTurns(previous => [...previous, { id: ++ids.current, role: 'assistant', reply }])
    } catch {
      if (request.current === controller) { setInput(message); setError('I couldn’t check the catalog just now. Please try again, or call (516) 367-9030.') }
    } finally {
      window.clearTimeout(timeout)
      if (request.current === controller) { request.current = null; setBusy(false) }
    }
  }

  if (cartOpen) return null
  return <>
    <button ref={launcher} type="button" onClick={() => setOpen(true)} aria-expanded={open} aria-controls={panelId}
      className={`${open ? 'hidden' : 'inline-flex'} fixed bottom-5 right-4 z-40 items-center gap-2 rounded-full bg-brand-600 px-5 py-3.5 text-sm font-semibold text-white shadow-lg transition hover:bg-brand-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-brand-600 sm:bottom-6 sm:right-6`}>
      <Sparkles size={18} aria-hidden="true" /> Ask Cottage
    </button>
    {open && <section id={panelId} role="dialog" aria-modal="false" aria-labelledby={`${panelId}-title`}
      onKeyDown={event => { if (event.key === 'Escape') { event.stopPropagation(); close() } }}
      className="fixed bottom-3 left-3 right-3 z-40 flex h-[min(600px,80dvh)] max-h-[calc(100dvh-1.5rem)] flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-2xl sm:bottom-6 sm:left-auto sm:right-6 sm:h-[min(600px,75dvh)] sm:w-[400px]">
      <header className="flex shrink-0 items-center justify-between gap-3 border-b border-slate-100 bg-brand-50 px-4 py-3">
        <div className="flex items-center gap-3"><span className="grid h-10 w-10 place-items-center rounded-full bg-brand-600 text-white"><MessageCircle size={20} aria-hidden="true" /></span><div><h2 id={`${panelId}-title`} className="font-heading text-sm font-bold text-navy">Ask Cottage</h2><p className="text-xs text-slate-600">Your equipment shopping assistant</p></div></div>
        <button type="button" aria-label="Close equipment assistant" onClick={close} className="rounded-lg p-2 text-slate-500 hover:bg-white hover:text-navy focus-visible:outline focus-visible:outline-brand-600"><X size={19} /></button>
      </header>
      <div ref={scrollArea} role="log" aria-label="Equipment conversation" aria-live="polite" aria-relevant="additions text"
        onScroll={() => { const el = scrollArea.current; if (el) shouldFollow.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80 }}
        className="min-h-0 flex-1 space-y-4 overflow-y-auto overscroll-contain bg-slate-50/50 p-4">
        <div className="rounded-2xl rounded-tl-sm border border-slate-100 bg-white p-3 text-sm leading-relaxed text-slate-700">Hi! I can help you find equipment, check availability and explore rental or purchase options. What are you looking for?</div>
        {turns.length === 0 && <div className="flex flex-wrap gap-2">{STARTERS.map(text => <button key={text} type="button" onClick={() => void send(text)} className="rounded-full border border-brand-200 bg-white px-3 py-2 text-left text-xs font-medium text-brand-700 hover:bg-brand-50">{text}</button>)}</div>}
        {turns.map(turn => turn.role === 'user'
          ? <div key={turn.id} className="ml-8 whitespace-pre-wrap break-words rounded-2xl rounded-tr-sm bg-brand-600 px-3 py-2.5 text-sm text-white">{turn.text}</div>
          : <div key={turn.id} className="space-y-2"><p className="rounded-2xl rounded-tl-sm border border-slate-100 bg-white p-3 text-sm leading-relaxed text-slate-700">{turn.reply.text}</p>
            {turn.reply.items.map(p => <article key={p.id} className="rounded-xl border border-slate-200 bg-white p-3">
              <Link href={p.href} className="text-sm font-semibold text-navy hover:underline">{p.name}</Link>
              <p className={`mt-1 text-xs font-semibold ${p.stock === 'in-stock' ? 'text-emerald-700' : p.stock === 'out-of-stock' ? 'text-red-700' : 'text-slate-600'}`}>{p.stock === 'in-stock' ? 'In stock' : p.stock === 'out-of-stock' ? 'Out of stock' : 'Call to confirm availability'}</p>
              <div className="mt-1 space-y-0.5 text-xs leading-relaxed text-slate-600">{p.prices.map(price => <p key={price}>{price}</p>)}</div>
              <div className="mt-2 flex flex-wrap gap-2">{p.rentHref && <Link href={p.rentHref} className="inline-flex items-center gap-1 rounded-lg bg-navy px-3 py-2 text-xs font-semibold text-white">Rental options <ArrowUpRight size={13} /></Link>}{p.buyHref && <Link href={p.buyHref} className="inline-flex items-center gap-1 rounded-lg border border-brand-200 px-3 py-2 text-xs font-semibold text-brand-700">Purchase <ArrowUpRight size={13} /></Link>}{!p.rentHref && !p.buyHref && <Link href={p.href} className="text-xs font-semibold text-brand-700 underline">View details</Link>}</div>
            </article>)}
            <Link href={turn.reply.browseHref} className="inline-flex items-center gap-1 px-1 py-1 text-xs font-semibold text-brand-700 hover:underline">Browse equipment <ArrowUpRight size={13} /></Link>
          </div>)}
        {busy && <p role="status" className="flex items-center gap-2 text-xs text-slate-500"><Loader2 size={15} className="animate-spin" /> Checking the live catalog…</p>}
        {error && <p role="alert" className="rounded-lg bg-red-50 p-3 text-sm text-red-800">{error} <a className="underline" href="tel:+15163679030">Call us</a></p>}
      </div>
      <form onSubmit={event => { event.preventDefault(); void send() }} className="shrink-0 border-t border-slate-100 bg-white p-3">
        <div className="flex items-end gap-2"><label htmlFor={`${panelId}-input`} className="sr-only">Ask about equipment</label>
          <textarea id={`${panelId}-input`} ref={textInput} rows={2} maxLength={500} value={input} onChange={event => setInput(event.target.value)}
            onKeyDown={event => { if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void send() } }}
            placeholder="Ask about an item, price or availability…" className="max-h-28 min-h-11 flex-1 resize-none rounded-xl border border-slate-200 px-3 py-2 text-base leading-5 text-slate-800 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 sm:text-sm" />
          <button type="submit" disabled={busy || !input.trim()} aria-label="Send equipment question" className="rounded-xl bg-brand-600 p-3 text-white hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-40"><Send size={18} /></button>
        </div><p className="mt-2 px-1 text-[10px] text-slate-400">Live catalog availability · Final options confirmed at checkout</p>
      </form>
    </section>}
  </>
}
