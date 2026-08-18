'use client'

import { useEffect, type ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { useAuth } from '../contexts/AuthContext'

const STAFF_ROLES = ['admin', 'staff', 'driver']

export default function ProtectedRoute({ children }: { children: ReactNode }) {
  const router = useRouter()
  const { userId, profile, loading, profileLoaded, signOut } = useAuth()

  useEffect(() => {
    if (!loading && !userId) {
      router.replace('/admin-login')
      router.refresh()
    }
  }, [loading, router, userId])

  if (loading || (!userId && !loading)) return <Centered>{userId ? 'Loading…' : 'Redirecting…'}</Centered>
  if (!profileLoaded) return <Centered>Loading…</Centered>

  if (!profile) {
    return (
      <Notice title="Account problem">
        We couldn’t load your profile. Please sign in again or contact an administrator.
        <SignOutLink signOut={signOut} />
      </Notice>
    )
  }

  if (!profile.is_active || !STAFF_ROLES.includes(profile.role)) {
    return (
      <Notice title="Access denied">
        This area is for Cottage Surgical staff. Your account doesn’t have access.
        <SignOutLink signOut={signOut} />
      </Notice>
    )
  }

  return children
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="min-h-screen grid place-items-center text-slate-500">{children}</div>
}

function Notice({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="min-h-screen grid place-items-center p-6 text-center">
      <div className="max-w-sm">
        <h1 className="text-lg font-semibold mb-2">{title}</h1>
        <div className="text-sm text-slate-600">{children}</div>
      </div>
    </div>
  )
}

function SignOutLink({ signOut }: { signOut: () => Promise<void> }) {
  const router = useRouter()
  return (
    <div className="mt-4">
      <button
        onClick={async () => {
          await signOut()
          router.replace('/admin-login')
          router.refresh()
        }}
        className="text-sm text-blue-600 hover:underline"
      >
        Sign out
      </button>
    </div>
  )
}
