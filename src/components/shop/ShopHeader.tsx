import { Link, NavLink } from 'react-router-dom'
import { MessageCircle, ShoppingCart, Phone } from 'lucide-react'
import { useCart } from './CartContext'
import CartDrawer from './CartDrawer'

const NAV = [
  { to: '/', label: 'Equipment', end: true },
  { to: '/how-it-works', label: 'How It Works' },
  { to: '/faq', label: 'FAQ' },
  { to: '/return-policy', label: 'Return Policy' },
]

// Public storefront header. The discreet "Staff" link is the only way in to the
// admin app — no other public pointer to it.
export default function ShopHeader() {
  const { count, setOpen } = useCart()
  return (
    <>
    <header className="bg-white border-b border-slate-200 sticky top-0 z-30 font-poppins">
      <div className="max-w-7xl mx-auto px-4 h-[68px] flex items-center justify-between gap-3">
        <Link to="/" className="flex items-center gap-2.5 shrink-0">
          <span className="w-10 h-10 rounded-xl bg-navy text-white grid place-items-center font-bold tracking-tight">CS</span>
          <span className="leading-tight hidden sm:block">
            <span className="block font-bold text-navy">Cottage Surgical</span>
            <span className="block text-[11px] font-medium text-terracotta">Same-Day Delivery</span>
          </span>
        </Link>

        <nav className="hidden lg:flex items-center gap-1 text-sm font-medium">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} end={n.end}
              className={({ isActive }) =>
                `px-4 py-2 rounded-full transition ${isActive ? 'bg-navy text-white' : 'text-navy/70 hover:text-navy hover:bg-slate-100'}`}>
              {n.label}
            </NavLink>
          ))}
        </nav>

        <div className="flex items-center gap-2 shrink-0">
          <button title="AI assistant — coming soon"
            className="hidden sm:inline-flex items-center gap-1.5 text-sm text-navy border border-slate-200 rounded-full px-3.5 py-2 hover:bg-slate-50">
            <MessageCircle size={16} /> Ask AI
          </button>
          <button onClick={() => setOpen(true)} title="Cart" aria-label="Cart" className="relative text-navy p-2 rounded-full hover:bg-slate-100">
            <ShoppingCart size={20} />
            {count > 0 && (
              <span className="absolute -top-0.5 -right-0.5 bg-terracotta text-white text-[10px] font-bold rounded-full w-4 h-4 grid place-items-center">{count}</span>
            )}
          </button>
          <a href="tel:+15163679030"
            className="inline-flex items-center gap-1.5 text-sm font-semibold text-white bg-terracotta hover:opacity-90 rounded-full px-4 py-2">
            <Phone size={15} /> <span className="hidden sm:inline">Call Us</span>
          </a>
          <Link to="/admin-login" className="text-xs text-slate-400 hover:text-navy ml-1">Staff</Link>
        </div>
      </div>
    </header>
    <CartDrawer />
    </>
  )
}
