import { Link, NavLink } from 'react-router-dom'
import { ShoppingCart, Phone, Search } from 'lucide-react'
import { useCart } from './CartContext'
import CartDrawer from './CartDrawer'

// Category-forward nav (JustWalkers style). Category links filter the catalog on
// the landing via ?q=; the last two are informational pages.
const NAV = [
  { to: '/?q=wheelchair', label: 'Wheelchairs' },
  { to: '/?q=bed', label: 'Hospital Beds' },
  { to: '/?q=knee', label: 'Knee Walkers' },
  { to: '/how-it-works', label: 'How It Works' },
  { to: '/faq', label: 'FAQ' },
]

// Public storefront header. The discreet "Staff" link is the only way in to the
// admin app — no other public pointer to it.
export default function ShopHeader() {
  const { count, setOpen } = useCart()
  return (
    <>
      {/* Announcement bar — JustWalkers "Free Shipping" analogue */}
      <div className="bg-brand-600 text-white text-xs sm:text-sm">
        <div className="max-w-7xl mx-auto px-4 h-9 flex items-center justify-center sm:justify-between gap-3">
          <span className="font-medium text-center">
            Same-Day Delivery across Nassau &amp; Suffolk County — no shipping fees, ever.
          </span>
          <a href="tel:+15163679030" className="hidden sm:inline-flex items-center gap-1.5 font-semibold whitespace-nowrap">
            <Phone size={13} /> (516) 367-9030
          </a>
        </div>
      </div>

      <header className="bg-white border-b border-slate-200 sticky top-0 z-30 font-poppins">
        <div className="max-w-7xl mx-auto px-4 h-[68px] flex items-center justify-between gap-3">
          <Link to="/" className="flex items-center gap-2.5 shrink-0">
            <span className="w-10 h-10 rounded-xl bg-brand-600 text-white grid place-items-center font-bold tracking-tight">CS</span>
            <span className="leading-tight hidden sm:block">
              <span className="block font-bold text-slate-900">Cottage Surgical</span>
              <span className="block text-[11px] font-semibold text-brand-600">Home Medical Equipment</span>
            </span>
          </Link>

          <nav className="hidden lg:flex items-center gap-0.5 text-sm font-medium">
            {NAV.map((n) => (
              <NavLink key={n.to} to={n.to}
                className={({ isActive }) =>
                  `px-3.5 py-2 rounded-md transition ${isActive ? 'text-brand-700' : 'text-slate-600 hover:text-brand-600 hover:bg-slate-50'}`}>
                {n.label}
              </NavLink>
            ))}
          </nav>

          <div className="flex items-center gap-2 shrink-0">
            <Link to="/?focus=search" aria-label="Search equipment" title="Search"
              className="hidden sm:inline-flex text-slate-500 p-2 rounded-full hover:bg-slate-100">
              <Search size={20} />
            </Link>
            <button onClick={() => setOpen(true)} title="Cart" aria-label="Cart" className="relative text-slate-600 p-2 rounded-full hover:bg-slate-100">
              <ShoppingCart size={20} />
              {count > 0 && (
                <span className="absolute -top-0.5 -right-0.5 bg-brand-600 text-white text-[10px] font-bold rounded-full w-4 h-4 grid place-items-center">{count}</span>
              )}
            </button>
            <a href="tel:+15163679030"
              className="inline-flex items-center gap-1.5 text-sm font-semibold text-white bg-brand-600 hover:bg-brand-700 rounded-lg px-4 py-2">
              <Phone size={15} /> <span className="hidden sm:inline">Call Us</span>
            </a>
            <Link to="/admin-login" className="text-xs text-slate-400 hover:text-slate-700 ml-1">Staff</Link>
          </div>
        </div>
      </header>
      <CartDrawer />
    </>
  )
}
