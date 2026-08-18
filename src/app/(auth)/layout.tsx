import type { ReactNode } from 'react'
import { AuthProvider } from '../../contexts/AuthContext'
import Providers from '../providers'

export default function AuthLayout({ children }: { children: ReactNode }) {
  return (
    <Providers>
      <AuthProvider>{children}</AuthProvider>
    </Providers>
  )
}
