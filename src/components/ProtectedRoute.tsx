import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'

export default function ProtectedRoute({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth()
  if (loading) return <div className="p-8 text-slate-500">Loading…</div>
  if (!session) return <Navigate to="/login" replace />
  return <>{children}</>
}
