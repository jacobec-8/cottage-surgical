import type { ReactNode } from 'react'
import { Routes, Route } from 'react-router-dom'
import { hasSupabaseConfig } from './lib/supabase'
import ProtectedRoute from './components/ProtectedRoute'
import Layout from './components/Layout'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'
import Inventory from './pages/Inventory'
import Customers from './pages/Customers'
import NewOrder from './pages/NewOrder'
import Billing from './pages/Billing'
import Delivery from './pages/Delivery'
import Requests from './pages/Requests'

function Protected({ children }: { children: ReactNode }) {
  return (
    <ProtectedRoute>
      <Layout>{children}</Layout>
    </ProtectedRoute>
  )
}

export default function App() {
  if (!hasSupabaseConfig) return <ConfigWarning />
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route path="/" element={<Protected><Dashboard /></Protected>} />
      <Route path="/inventory" element={<Protected><Inventory /></Protected>} />
      <Route path="/customers" element={<Protected><Customers /></Protected>} />
      <Route path="/requests" element={<Protected><Requests /></Protected>} />
      <Route path="/new-order" element={<Protected><NewOrder /></Protected>} />
      <Route path="/billing" element={<Protected><Billing /></Protected>} />
      <Route path="/delivery" element={<Protected><Delivery /></Protected>} />
    </Routes>
  )
}

function ConfigWarning() {
  return (
    <div className="min-h-screen grid place-items-center p-8 text-center">
      <div className="max-w-md">
        <h1 className="text-xl font-semibold mb-2">Supabase not configured</h1>
        <p className="text-slate-600 text-sm">
          Set <code className="bg-slate-100 px-1 rounded">VITE_SUPABASE_URL</code> and{' '}
          <code className="bg-slate-100 px-1 rounded">VITE_SUPABASE_ANON_KEY</code> in Vercel →
          Settings → Environment Variables, then redeploy.
        </p>
      </div>
    </div>
  )
}
