import type { ReactNode } from 'react'
import { Inter, JetBrains_Mono } from 'next/font/google'
import { redirect } from 'next/navigation'
import { createClient } from '../../lib/supabase/server'
import type { Profile } from '../../contexts/AuthContext'
import StaffShell from './StaffShell'
import { STAFF_APP_ROLES } from '../../lib/roles'

const staffSans = Inter({ subsets: ['latin'], variable: '--font-staff-sans', display: 'swap' })
const staffMono = JetBrains_Mono({ subsets: ['latin'], variable: '--font-staff-mono', display: 'swap' })

export const dynamic = 'force-dynamic'

export default async function StaffLayout({ children }: { children: ReactNode }) {
  const supabase = await createClient()
  let userId: string | undefined
  try {
    const claimsResult = await supabase.auth.getClaims()
    if (!claimsResult.error) userId = claimsResult.data?.claims?.sub
  } catch {
    // A missing/unreachable auth backend must fail closed, not turn an
    // anonymous protected-route request into a server error.
  }

  if (!userId) redirect('/admin-login')

  const { data: profileData } = await supabase
    .from('profiles')
    .select('id,email,full_name,role,is_active,location_id,business_id')
    .eq('id', userId)
    .maybeSingle()

  const profile = (profileData as Profile | null) ?? null
  const authorized = Boolean(profile?.is_active && STAFF_APP_ROLES.includes(profile.role))

  return (
    <div className={`staff-theme ${staffSans.variable} ${staffMono.variable}`}>
      <StaffShell initialUserId={userId} initialProfile={profile} authorized={authorized}>
        {authorized ? children : null}
      </StaffShell>
    </div>
  )
}
