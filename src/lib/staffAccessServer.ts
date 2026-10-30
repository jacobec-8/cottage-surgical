import 'server-only'

import { redirect } from 'next/navigation'
import { createClient } from './supabase/server'
import type { StaffModule } from './staffModules'

/** Staff need one of `module`'s switches on (a list means any of them). */
export async function requireStaffModule(module: StaffModule | readonly StaffModule[], allowDriver = false) {
  const modules = [module].flat()
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
  if (profile.role === 'admin' || profile.role === 'owner') return
  if (profile.role === 'driver') {
    if (allowDriver && modules.includes('delivery')) return
    redirect('/delivery')
  }
  if (profile.role !== 'staff') redirect('/admin-login')

  const { data: settings, error } = await supabase
    .from('staff_module_access')
    .select('enabled')
    .in('module_key', modules)

  if (error || !settings?.some((setting) => setting.enabled)) redirect(`/access-limited?module=${modules[0]}`)
}

/** Admins, plus business owners managing their own team's logins (migration 087). */
export async function requireTeamManager() {
  await requireRole(['admin', 'owner'])
}

export async function requireAdmin() {
  await requireRole(['admin'])
}

async function requireRole(roles: readonly string[]) {
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
  if (!roles.includes(profile.role)) redirect('/access-limited?reason=admin_only')
}
