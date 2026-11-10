'use client'

import { useAuth } from '../contexts/AuthContext'
import { useLocationScope } from '../contexts/LocationContext'
import AdminHome from './admin/AdminHome'
import Dashboard from './Dashboard'

/** The first page after sign-in: admin's own Home, or the dashboard (inside an owner's workspace too). */
export default function Home() {
  const { profile } = useAuth()
  const { viewingBusinessId } = useLocationScope()
  return profile?.role === 'admin' && !viewingBusinessId ? <AdminHome /> : <Dashboard />
}
