import { useState } from 'react'
import type { FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Shield, ClipboardList, Truck, CreditCard, Package, Eye, EyeOff, LogIn, MapPin, Phone, Mail } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'

const FEATURES = [
  { icon: ClipboardList, title: 'Customer Management', desc: 'Full intake with payment method on file' },
  { icon: Truck, title: 'Delivery Scheduling', desc: 'Driver assignment & proof of delivery' },
  { icon: CreditCard, title: 'Recurring Billing', desc: 'Automated monthly charges & refunds' },
  { icon: Package, title: 'Inventory Tracking', desc: 'Equipment stock & serial numbers' },
]

const DEMO_ROLES = [
  { title: 'Administrator', desc: 'Dashboards, rentals, inventory, customers', badge: 'Full Access', badgeClass: 'text-emerald-600', email: 'admin@cottagesurgical.com' },
  { title: 'Staff Member', desc: 'New rentals, customers, scheduling', badge: 'Rentals', badgeClass: 'text-amber-600', email: 'staff@cottagesurgical.com' },
  { title: 'Driver', desc: 'Delivery queue, proof of delivery', badge: 'Deliveries', badgeClass: 'text-blue-600', email: 'driver@cottagesurgical.com' },
]
const DEMO_PASSWORD = 'cottage-demo'

// Demo quick-login is OFF unless VITE_DEMO_MODE=true (never set in production).
const SHOW_DEMO = import.meta.env.VITE_DEMO_MODE === 'true'

export default function Login() {
  const { signIn } = useAuth()
  const navigate = useNavigate()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [show, setShow] = useState(false)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const doSignIn = async (email: string, pw: string) => {
    setBusy(true)
    setError('')
    const { error } = await signIn(email, pw)
    setBusy(false)
    if (error) setError(error)
    else navigate('/')
  }
  const submit = (e: FormEvent) => {
    e.preventDefault()
    doSignIn(username, password)
  }

  return (
    <div className="min-h-screen grid lg:grid-cols-2">
      {/* Left brand panel */}
      <div className="hidden lg:flex flex-col justify-between p-12 text-white bg-gradient-to-br from-[#0a1f44] via-[#102a5c] to-[#1d4ed8]">
        <div>
          <div className="flex items-center gap-3 mb-14">
            <div className="w-10 h-10 rounded-xl bg-white/10 grid place-items-center">
              <Shield size={22} />
            </div>
            <span className="text-lg font-semibold">Cottage Surgical</span>
          </div>
          <h1 className="text-4xl font-bold leading-tight mb-4">
            DME Rental
            <br />
            Management System
          </h1>
          <p className="text-blue-100/80 mb-10 max-w-md">
            Complete workflow for equipment rentals — from customer intake through delivery, billing, and closeout.
          </p>
          <div className="space-y-5 max-w-md">
            {FEATURES.map((f) => {
              const Icon = f.icon
              return (
                <div key={f.title} className="flex items-start gap-3">
                  <div className="w-9 h-9 rounded-lg bg-white/10 grid place-items-center shrink-0">
                    <Icon size={18} />
                  </div>
                  <div>
                    <div className="font-medium">{f.title}</div>
                    <div className="text-sm text-blue-100/70">{f.desc}</div>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
        <div className="space-y-1.5 text-sm text-blue-100/70">
          <div className="flex items-center gap-2"><MapPin size={14} /> 8285 Jericho Tpke, Woodbury, NY 11797</div>
          <div className="flex items-center gap-2"><Phone size={14} /> 516-367-9030 ext 4</div>
          <div className="flex items-center gap-2"><Mail size={14} /> info@cottagepharmacy.com</div>
        </div>
      </div>

      {/* Right sign-in panel */}
      <div className="flex items-center justify-center p-6 bg-slate-50">
        <div className="w-full max-w-md">
          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-8">
            <h2 className="text-xl font-bold">Sign In</h2>
            <p className="text-sm text-slate-500 mb-6">Enter your credentials to continue</p>
            <form onSubmit={submit}>
              <label className="block text-xs font-medium tracking-wide text-slate-500 mb-1">USERNAME</label>
              <input
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder="Enter username"
                required
                className="w-full border border-slate-300 rounded-lg px-3 py-2.5 mb-4 focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
              <label className="block text-xs font-medium tracking-wide text-slate-500 mb-1">PASSWORD</label>
              <div className="relative mb-5">
                <input
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  type={show ? 'text' : 'password'}
                  placeholder="Enter password"
                  required
                  className="w-full border border-slate-300 rounded-lg px-3 py-2.5 pr-10 focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <button
                  type="button"
                  onClick={() => setShow((s) => !s)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600"
                >
                  {show ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>
              {error && <div className="text-sm text-red-600 mb-3">{error}</div>}
              <button
                disabled={busy}
                className="w-full bg-blue-600 hover:bg-blue-700 text-white rounded-lg py-2.5 text-sm font-medium flex items-center justify-center gap-2 disabled:opacity-50"
              >
                <LogIn size={16} /> {busy ? 'Signing in…' : 'Sign In'}
              </button>
            </form>

            {SHOW_DEMO && (
              <>
                <div className="flex items-center gap-3 my-6">
                  <div className="h-px bg-slate-200 flex-1" />
                  <span className="text-[11px] tracking-wide text-slate-400">DEMO — CLICK TO SIGN IN INSTANTLY</span>
                  <div className="h-px bg-slate-200 flex-1" />
                </div>
                <div className="space-y-2">
                  {DEMO_ROLES.map((r) => (
                    <button
                      key={r.title}
                      type="button"
                      onClick={() => doSignIn(r.email, DEMO_PASSWORD)}
                      className="w-full text-left border border-slate-200 rounded-xl px-4 py-3 hover:bg-slate-50 flex items-center justify-between"
                    >
                      <div>
                        <div className="text-sm font-semibold">{r.title}</div>
                        <div className="text-xs text-slate-500">{r.desc}</div>
                      </div>
                      <span className={`text-xs font-semibold ${r.badgeClass}`}>{r.badge}</span>
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
          <p className="text-center text-xs text-slate-400 mt-4">© 2026 Cottage Surgical · Demo system</p>
        </div>
      </div>
    </div>
  )
}
