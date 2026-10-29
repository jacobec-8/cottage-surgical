'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from './supabase/server'

// Product changes show on the public website straight away instead of after the
// shop pages' one-minute refresh. Only signed-in, active staff may trigger it.
const STAFF_ROLES = ['admin', 'owner', 'staff']

export async function refreshWebsite(): Promise<boolean> {
  const supabase = await createClient()
  const claims = await supabase.auth.getClaims().catch(() => null)
  const userId = claims?.data?.claims?.sub
  if (!userId) return false
  const { data: profile, error } = await supabase.from('profiles').select('role,is_active').eq('id', userId).maybeSingle()
  if (error) {
    console.error('Website refresh: profile lookup failed:', error.message)
    return false
  }
  if (!profile?.is_active || !STAFF_ROLES.includes(profile.role)) return false
  revalidatePath('/', 'layout')
  return true
}
