'use client'

import { useEffect, type ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '../../../contexts/AuthContext'

export default function BackofficeGuard({ children }: { children: ReactNode }) {
  const router = useRouter()
  const queryClient = useQueryClient()
  const { profile, profileLoaded } = useAuth()
  const isDriver = profileLoaded && profile?.role === 'driver'

  useEffect(() => {
    if (!isDriver) return
    void queryClient.cancelQueries()
    queryClient.clear()
    router.replace('/delivery')
    router.refresh()
  }, [isDriver, queryClient, router])

  if (isDriver) {
    return <div className="min-h-screen grid place-items-center text-slate-500">Redirecting…</div>
  }

  return children
}
