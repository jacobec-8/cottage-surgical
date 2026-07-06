import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'

const STAFF_ROLES = ['admin', 'staff', 'driver']

export default function ProtectedRoute({ children }: { children: ReactNode }) {
  const { session, profile, loading, profileLoaded, signOut } = useAuth()

  if (loading) return <Centered>Loading…</Centered>
  if (!session) return <Navigate to="/admin-login" replace />
  if (!profileLoaded) return <Centered>Loading…</Centered>

  // Authenticated but the profile row is missing or failed to load.
  if (!profile) {
    return (
      <Notice title="Account problem">
        We couldn’t load your profile. Please sign in again or contact an administrator.
        <SignOutLink signOut={signOut} />
      </Notice>
    )
  }

  // The staff app is for admin/staff/driver only. Customers (storefront) and
  // deactivated accounts are denied here; RLS is still the real data boundary.
  if (!profile.is_active || !STAFF_ROLES.includes(profile.role)) {
    return (
      <Notice title="Access denied">
        This area is for Cottage Surgical staff. Your account doesn’t have access.
        <SignOutLink signOut={signOut} />
      </Notice>
    )
  }

  return <>{children}</>
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="min-h-screen grid place-items-center text-slate-500">{children}</div>
}

function Notice({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="min-h-screen grid place-items-center p-6 text-center">
      <div className="max-w-sm">
        <h1 className="text-lg font-semibold mb-2">{title}</h1>
        <p className="text-sm text-slate-600">{children}</p>
      </div>
    </div>
  )
}

function SignOutLink({ signOut }: { signOut: () => Promise<void> }) {
  return (
    <div className="mt-4">
      <button onClick={() => signOut()} className="text-sm text-blue-600 hover:underline">
        Sign out
      </button>
    </div>
  )
}
