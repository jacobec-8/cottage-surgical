'use client'

import type { ReactNode } from 'react'
import Layout from '../../components/Layout'
import ProtectedRoute from '../../components/ProtectedRoute'
import RealtimeSync from '../../components/RealtimeSync'
import { SaveNoticeProvider } from '../../components/SaveNotice'
import { AuthProvider, type Profile } from '../../contexts/AuthContext'
import { LocationProvider } from '../../contexts/LocationContext'
import Providers from '../providers'

export default function StaffShell({
  children,
  initialUserId,
  initialProfile,
  authorized,
}: {
  children: ReactNode
  initialUserId: string
  initialProfile: Profile | null
  authorized: boolean
}) {
  return (
    <Providers>
      <AuthProvider initialUserId={initialUserId} initialProfile={initialProfile}>
        <LocationProvider>
          <ProtectedRoute>
            {authorized ? (
              <SaveNoticeProvider>
                <RealtimeSync />
                <Layout>{children}</Layout>
              </SaveNoticeProvider>
            ) : null}
          </ProtectedRoute>
        </LocationProvider>
      </AuthProvider>
    </Providers>
  )
}
