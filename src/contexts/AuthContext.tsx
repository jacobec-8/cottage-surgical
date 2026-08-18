'use client'

import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { hasSupabaseConfig, supabase } from '../lib/supabase'

export type Profile = {
  id: string
  email: string
  full_name: string | null
  role: string
  is_active: boolean
}

const STAFF_ROLES = ['admin', 'staff', 'driver']

function profileAccessKey(profile: Profile | null | undefined) {
  return profile ? `${profile.role}:${profile.is_active}` : null
}

type AuthCtx = {
  userId: string | null
  profile: Profile | null
  loading: boolean
  profileLoaded: boolean
  signIn: (email: string, password: string) => Promise<{ error?: string }>
  signOut: () => Promise<void>
}

type AuthProviderProps = {
  children: ReactNode
  initialUserId?: string | null
  initialProfile?: Profile | null
}

const Ctx = createContext<AuthCtx | null>(null)

export function useAuth() {
  const value = useContext(Ctx)
  if (!value) throw new Error('useAuth must be used within AuthProvider')
  return value
}

export function AuthProvider({ children, initialUserId, initialProfile }: AuthProviderProps) {
  const queryClient = useQueryClient()
  const hasSeed = initialUserId !== undefined
  const hasProfileSeed = initialProfile !== undefined
  const [userId, setUserId] = useState<string | null>(initialUserId ?? null)
  const [profile, setProfile] = useState<Profile | null>(initialProfile ?? null)
  const [loading, setLoading] = useState(!hasSeed)
  const [profileLoaded, setProfileLoaded] = useState(hasProfileSeed)
  const seededUserId = useRef(initialUserId ?? null)
  const prevAuthUserId = useRef<string | null | undefined>(
    hasSeed ? initialUserId ?? null : undefined,
  )
  const prevProfileAccess = useRef<string | null | undefined>(
    hasProfileSeed ? profileAccessKey(initialProfile) : undefined,
  )

  useEffect(() => {
    if (!hasSupabaseConfig) {
      setLoading(false)
      setProfileLoaded(true)
      return
    }

    let active = true
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return
      setUserId(data.session?.user.id ?? null)
      setLoading(false)
    })
    const { data: authListener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setUserId(nextSession?.user.id ?? null)
      setLoading(false)
    })

    return () => {
      active = false
      authListener.subscription.unsubscribe()
    }
  }, [])

  useEffect(() => {
    const id = userId
    if (prevAuthUserId.current !== undefined && prevAuthUserId.current !== id) {
      void queryClient.cancelQueries()
      queryClient.clear()
    }
    prevAuthUserId.current = id
  }, [queryClient, userId])

  useEffect(() => {
    if (!userId) {
      setProfile(null)
      setProfileLoaded(true)
      seededUserId.current = null
      return
    }

    const useSeededProfile = hasProfileSeed && seededUserId.current === userId
    if (useSeededProfile) {
      seededUserId.current = null
    }

    let active = true
    const loadProfile = async (showLoading = false) => {
      if (showLoading) setProfileLoaded(false)
      const { data, error } = await supabase
        .from('profiles')
        .select('id,email,full_name,role,is_active')
        .eq('id', userId)
        .single()
      if (!active) return
      if (error) console.error('profile load failed:', error.message)
      setProfile((data as Profile) ?? null)
      setProfileLoaded(true)
    }

    if (!useSeededProfile) void loadProfile(true)
    const refreshOnFocus = () => void loadProfile()
    window.addEventListener('focus', refreshOnFocus)
    const profileRefresh = window.setInterval(() => void loadProfile(), 60_000)

    return () => {
      active = false
      window.removeEventListener('focus', refreshOnFocus)
      window.clearInterval(profileRefresh)
    }
  }, [hasProfileSeed, userId])

  useEffect(() => {
    const accessKey = profileAccessKey(profile)
    const accessChanged =
      prevProfileAccess.current !== undefined && prevProfileAccess.current !== accessKey
    const accessRevoked =
      Boolean(userId && profileLoaded) &&
      !(profile?.is_active && STAFF_ROLES.includes(profile.role))

    if (accessChanged || accessRevoked) {
      void queryClient.cancelQueries()
      queryClient.clear()
    }
    prevProfileAccess.current = accessKey
  }, [profile, profileLoaded, queryClient, userId])

  const signIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    return error ? { error: error.message } : {}
  }

  const signOut = async () => {
    await supabase.auth.signOut()
    setUserId(null)
    setProfile(null)
    setProfileLoaded(true)
    void queryClient.cancelQueries()
    queryClient.clear()
  }

  return (
    <Ctx.Provider value={{ userId, profile, loading, profileLoaded, signIn, signOut }}>
      {children}
    </Ctx.Provider>
  )
}
