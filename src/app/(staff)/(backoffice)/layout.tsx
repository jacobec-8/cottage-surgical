import type { ReactNode } from 'react'
import { redirect } from 'next/navigation'
import { createClient } from '../../../lib/supabase/server'
import BackofficeGuard from './BackofficeGuard'

export default async function BackofficeLayout({ children }: { children: ReactNode }) {
  const supabase = await createClient()
  const claimsResult = await supabase.auth.getClaims().catch(() => null)
  const userId = claimsResult?.data?.claims?.sub

  if (!userId) redirect('/admin-login')

  const { data: profile } = await supabase
    .from('profiles')
    .select('role')
    .eq('id', userId)
    .maybeSingle()

  if (profile?.role === 'driver') redirect('/delivery')

  return <BackofficeGuard>{children}</BackofficeGuard>
}
