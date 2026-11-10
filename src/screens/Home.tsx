'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Sparkles } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { useLocationScope } from '../contexts/LocationContext'
import AdminHome from './admin/AdminHome'
import Dashboard from './Dashboard'
import { SETUP_SKIPPED_KEY } from './setup/OwnerSetup'
import { useOwnerBusiness } from './setup/useOwnerBusiness'

/** The first page after sign-in: admin's own Home, or the dashboard (inside an owner's workspace too). */
export default function Home() {
  const { profile } = useAuth()
  const { viewingBusinessId } = useLocationScope()
  if (profile?.role === 'admin' && !viewingBusinessId) return <AdminHome />
  return <><SetupPrompt isOwner={profile?.role === 'owner'} /><Dashboard /></>
}

/**
 * An owner who hasn't finished setup is taken to it on first sign-in (147);
 * after "Skip for now" a bar here brings them back. Admin in a workspace sees
 * the bar but is never redirected.
 */
function SetupPrompt({ isOwner }: { isOwner: boolean }) {
  const router = useRouter()
  const { business } = useOwnerBusiness()
  const [skipped, setSkipped] = useState<boolean | null>(null)
  const unfinished = Boolean(business.data && !business.data.setup_finished_at)
  useEffect(() => {
    let value = false
    try { value = window.sessionStorage.getItem(SETUP_SKIPPED_KEY) === '1' } catch { /* storage unavailable */ }
    setSkipped(value)
  }, [])
  useEffect(() => {
    if (isOwner && unfinished && skipped === false) router.replace('/setup')
  }, [isOwner, unfinished, skipped, router])
  if (!unfinished || skipped === null || (isOwner && !skipped)) return null
  return (
    <div className="mb-6 flex flex-col gap-3 rounded-xl border border-blue-200 bg-blue-50 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
      <span className="flex items-center gap-2 text-sm text-blue-900"><Sparkles size={16} className="shrink-0" />
        <span><strong>{business.data?.name}</strong> isn’t fully set up yet. The setup guide takes you through your location, products and staff.</span>
      </span>
      <Link href="/setup" className="inline-flex min-h-10 shrink-0 items-center rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700">Continue setup</Link>
    </div>
  )
}
