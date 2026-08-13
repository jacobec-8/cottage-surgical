import { createContext, useContext, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase, hasSupabaseConfig } from '../lib/supabase'
import { queryClient } from '../lib/queryClient'

type Profile = { id: string; email: string; full_name: string | null; role: string; is_active: boolean }

type AuthCtx = {
  session: Session | null
  profile: Profile | null
  loading: boolean
  profileLoaded: boolean
  signIn: (email: string, password: string) => Promise<{ error?: string }>
  signOut: () => Promise<void>
}

const Ctx = createContext<AuthCtx>(null as unknown as AuthCtx)
export const useAuth = () => useContext(Ctx)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const [profileLoaded, setProfileLoaded] = useState(false)
  // Tracks last auth user so multi-tab SIGNED_OUT / remote revoke / account
  // switch all purge the shared query cache (not only the Logout button path).
  const prevAuthUserId = useRef<string | null | undefined>(undefined)

  useEffect(() => {
    if (!hasSupabaseConfig) {
      setLoading(false)
      return
    }
    // getSession reads from memory (no network race) — preferred over getUser.
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    const id = session?.user?.id ?? null
    // Skip the first observation (undefined → initial id) so we don't clear a
    // cold cache; clear on every subsequent identity change including → null.
    if (prevAuthUserId.current !== undefined && prevAuthUserId.current !== id) {
      void queryClient.cancelQueries()
      queryClient.clear()
    }
    prevAuthUserId.current = id
  }, [session?.user?.id])

  useEffect(() => {
    if (!session?.user) {
      setProfile(null)
      setProfileLoaded(true)
      return
    }
    setProfileLoaded(false)
    supabase
      .from('profiles')
      .select('id,email,full_name,role,is_active')
      .eq('id', session.user.id)
      .single()
      .then(({ data, error }) => {
        if (error) console.error('profile load failed:', error.message)
        setProfile((data as Profile) ?? null)
        setProfileLoaded(true)
      })
    // Key on the user id, NOT the session object — a token refresh (hourly) or a
    // tab-focus SIGNED_IN emits a new session for the SAME user and must not
    // blank the profile / remount the app.
  }, [session?.user?.id])

  const signIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    return error ? { error: error.message } : {}
  }

  const signOut = async () => {
    await supabase.auth.signOut()
    setProfile(null)
    // Belt-and-suspenders with the identity-change effect above.
    void queryClient.cancelQueries()
    queryClient.clear()
  }

  return (
    <Ctx.Provider value={{ session, profile, loading, profileLoaded, signIn, signOut }}>
      {children}
    </Ctx.Provider>
  )
}
