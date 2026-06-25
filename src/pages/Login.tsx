import { useState } from 'react'
import type { FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'

export default function Login() {
  const { signIn } = useAuth()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError('')
    const { error } = await signIn(email, password)
    setBusy(false)
    if (error) setError(error)
    else navigate('/')
  }

  return (
    <div className="min-h-screen grid place-items-center bg-slate-50 p-4">
      <form
        onSubmit={submit}
        className="bg-white p-8 rounded-2xl shadow-sm border border-slate-200 w-full max-w-sm"
      >
        <div className="mb-6">
          <h1 className="text-lg font-semibold">Cottage Surgical</h1>
          <p className="text-sm text-slate-500">DME Rental Management System</p>
        </div>
        <label className="block text-sm mb-1 text-slate-600">Email</label>
        <input
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          type="email"
          required
          className="w-full border border-slate-300 rounded-lg px-3 py-2 mb-3"
        />
        <label className="block text-sm mb-1 text-slate-600">Password</label>
        <input
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          type="password"
          required
          className="w-full border border-slate-300 rounded-lg px-3 py-2 mb-4"
        />
        {error && <div className="text-sm text-red-600 mb-3">{error}</div>}
        <button
          disabled={busy}
          className="w-full bg-slate-900 text-white rounded-lg py-2 text-sm disabled:opacity-50"
        >
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </div>
  )
}
