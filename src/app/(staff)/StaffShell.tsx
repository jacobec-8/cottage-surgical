'use client'

import type { ReactNode } from 'react'
import Layout from '../../components/Layout'
import ProtectedRoute from '../../components/ProtectedRoute'
import RealtimeSync from '../../components/RealtimeSync'
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
              <>
                <RealtimeSync />
                <Layout>{children}</Layout>
              </>
            ) : null}
          </ProtectedRoute>
        </LocationProvider>
      </AuthProvider>
    </Providers>
  )
}
