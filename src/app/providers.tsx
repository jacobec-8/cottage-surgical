'use client'

import { useEffect, useState, type ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

export default function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 30_000,
            refetchOnWindowFocus: true,
            retry: 1,
          },
        },
      }),
  )

  // Scrolling the page must never change a focused number field (ODD-001:
  // a $450 sale price became $449.99). Blur it so the wheel scrolls instead.
  useEffect(() => {
    const onWheel = (e: WheelEvent) => {
      const el = document.activeElement
      if (el instanceof HTMLInputElement && el.type === 'number' && e.target === el) el.blur()
    }
    document.addEventListener('wheel', onWheel, { passive: true })
    return () => document.removeEventListener('wheel', onWheel)
  }, [])

  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
}
