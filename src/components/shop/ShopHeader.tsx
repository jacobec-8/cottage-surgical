import { Link } from 'react-router-dom'

// Public storefront header. No staff-login link — staff go to /admin-login directly.
export default function ShopHeader() {
  return (
    <header className="bg-white border-b border-slate-200 sticky top-0 z-10">
      <div className="max-w-6xl mx-auto px-4 h-16 flex items-center justify-between">
        <Link to="/" className="flex items-center gap-2 font-semibold">
          <span className="w-8 h-8 rounded-lg bg-blue-600 text-white grid place-items-center text-sm">CS</span>
          Cottage Surgical
        </Link>
        <nav className="flex items-center gap-6 text-sm">
          <Link to="/" className="text-slate-600 hover:text-slate-900">Equipment</Link>
        </nav>
      </div>
    </header>
  )
}
