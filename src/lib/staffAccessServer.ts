import 'server-only'

import { redirect } from 'next/navigation'
import { createClient } from './supabase/server'
import type { StaffModule } from './staffModules'

export async function requireStaffModule(module: StaffModule, allowDriver = false) {
  const supabase = await createClient()
  const claims = await supabase.auth.getClaims().catch(() => null)
  const userId = claims?.data?.claims?.sub
  if (!userId) redirect('/admin-login')

  const { data: profile } = await supabase
    .from('profiles')
    .select('role,is_active')
    .eq('id', userId)
    .maybeSingle()

  if (!profile?.is_active) redirect('/admin-login')
  if (profile.role === 'admin') return
  if (profile.role === 'driver') {
    if (allowDriver && module === 'delivery') return
    redirect('/delivery')
  }
  if (profile.role !== 'staff') redirect('/admin-login')

  const { data: setting, error } = await supabase
    .from('staff_module_access')
    .select('enabled')
    .eq('module_key', module)
    .maybeSingle()

  if (error || !setting?.enabled) redirect(`/access-limited?module=${module}`)
}

export async function requireAdmin() {
  const supabase = await createClient()
  const claims = await supabase.auth.getClaims().catch(() => null)
  const userId = claims?.data?.claims?.sub
  if (!userId) redirect('/admin-login')

  const { data: profile } = await supabase
    .from('profiles')
    .select('role,is_active')
    .eq('id', userId)
    .maybeSingle()

  if (!profile?.is_active) redirect('/admin-login')
  if (profile.role === 'driver') redirect('/delivery')
  if (profile.role !== 'admin') redirect('/access-limited?module=staff_access')
}
