'use client'

import { useState } from 'react'
import Link from 'next/link'
import { Menu, MapPin, Phone, ShoppingCart, Truck } from 'lucide-react'
import { useCart } from './CartContext'
import CartDrawer from './CartDrawer'
import HeaderSearch, { type HeaderSearchHandler } from './HeaderSearch'
import MobileMenu from './MobileMenu'
import { CATEGORY_LINKS, INFO_LINKS, type HeaderLink } from './headerNav'

const hit = 'rounded-md hover:bg-white/10 transition-colors'

// Public storefront top bar: a sticky navy row (logo, delivery area, search, call,
// cart) over a row of category and info links. The discreet "Staff" link is the
// only header way in to the admin app. On the landing page `onSearch` applies a
// category link at once and `onHeaderSearch` applies the search box, so both work
// even when the URL is already that search.
export default function ShopHeader({ onSearch, onHeaderSearch }: { onSearch?: (q: string) => void; onHeaderSearch?: HeaderSearchHandler } = {}) {
  const { count, setOpen } = useCart()
  const [menuOpen, setMenuOpen] = useState(false)
  const follow = (l: HeaderLink) => { if (l.q && onSearch) onSearch(l.q) }

  return (
    <>
      <header className="bg-navy text-white sticky top-0 z-30 font-sans">
        <div className="max-w-[1600px] mx-auto px-2 sm:px-4 h-[60px] lg:h-[72px] flex items-center gap-1 sm:gap-3">
          <button type="button" onClick={() => setMenuOpen(true)} aria-label="Menu" className={`md:hidden w-11 h-11 grid place-items-center ${hit}`}>
            <Menu size={24} />
          </button>
          <Link href="/" className={`flex items-center shrink-0 px-1.5 py-1 ${hit}`} aria-label="Cottage Pharmacy & Surgical — home">
            <img src="/cottage-logo.png" alt="Cottage Pharmacy & Surgical" className="h-10 lg:h-12 w-auto" />
          </Link>
          <div className="hidden lg:flex items-end gap-1.5 shrink-0 px-2 py-1.5">
            <MapPin size={20} className="mb-0.5" />
            <span className="leading-tight">
              <span className="block text-[13px] text-blue-100/80">Delivering to</span>
              <span className="block font-bold">Nassau &amp; Suffolk</span>
            </span>
          </div>

          <HeaderSearch onSearch={onHeaderSearch} className="hidden md:flex flex-1" />

          <a href="tel:+15163679030" aria-label="Call (516) 367-9030" className={`ml-auto md:ml-0 shrink-0 ${hit}`}>
            <span className="md:hidden w-11 h-11 grid place-items-center"><Phone size={22} /></span>
            <span className="hidden md:block leading-tight px-2 py-1.5">
              <span className="block text-[13px] text-blue-100/80">Questions? Call us</span>
              <span className="block font-bold whitespace-nowrap">(516) 367-9030</span>
            </span>
          </a>
          <Link href="/how-it-works" className={`hidden xl:block leading-tight shrink-0 px-2 py-1.5 ${hit}`}>
            <span className="block text-[13px] text-blue-100/80">Rentals</span>
            <span className="block font-bold">How It Works</span>
          </Link>
          <button type="button" onClick={() => setOpen(true)} title="Cart" aria-label="Cart" className={`flex items-end gap-1 shrink-0 px-2 py-1.5 ${hit}`}>
            <span className="relative">
              <ShoppingCart size={32} strokeWidth={1.75} />
              <span aria-hidden="true" className="absolute -top-2 left-1/2 -translate-x-1/3 text-[15px] font-extrabold text-peach">{count}</span>
            </span>
            <span className="hidden sm:block font-bold mb-0.5">Cart</span>
          </button>
        </div>
        <div className="md:hidden px-3 pb-3">
          <HeaderSearch onSearch={onHeaderSearch} />
        </div>
      </header>

      <nav aria-label="Shop" className="bg-navy-700 text-white font-sans">
        <div className="hidden md:flex max-w-[1600px] mx-auto px-2 sm:px-4 h-[42px] items-center gap-0.5 text-[15px] font-semibold">
          {[...CATEGORY_LINKS, ...INFO_LINKS].map((l) => (
            <Link key={l.href} href={l.href} onClick={() => follow(l)} className={`px-2.5 py-1.5 whitespace-nowrap ${hit}`}>{l.label}</Link>
          ))}
          <span className="hidden xl:inline-flex items-center gap-1.5 ml-auto pr-2 text-peach font-bold whitespace-nowrap">
            <Truck size={18} /> Order by 2 PM for same-day delivery
          </span>
          <Link href="/admin-login" className="ml-auto xl:ml-0 px-2 py-1.5 text-xs font-normal text-blue-100/60 hover:text-white">Staff</Link>
        </div>
        <div className="md:hidden flex h-11 items-center gap-5 px-4 overflow-x-auto whitespace-nowrap text-[15px] font-semibold [scrollbar-width:none]">
          {CATEGORY_LINKS.map((l) => (
            <Link key={l.href} href={l.href} onClick={() => follow(l)}>{l.label}</Link>
          ))}
        </div>
      </nav>
      <div className="md:hidden bg-navy-800 text-blue-100 text-sm h-10 px-4 flex items-center gap-2 font-sans">
        <MapPin size={16} className="shrink-0" />
        <span className="truncate">Delivering to <strong className="text-white">Nassau &amp; Suffolk</strong> · order by 2 PM</span>
      </div>

      <MobileMenu open={menuOpen} onClose={() => setMenuOpen(false)} onSearch={onSearch} />
      <CartDrawer />
    </>
  )
}
