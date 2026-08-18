'use client'

import { useEffect } from 'react'

export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error)
  }, [error])

  return (
    <main className="min-h-screen grid place-items-center p-6 text-center">
      <div className="max-w-md">
        <h1 className="text-xl font-semibold text-slate-900">Something went wrong</h1>
        <p className="mt-2 text-sm text-slate-600">Please try this page again.</p>
        <button onClick={reset} className="mt-5 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white">
          Try again
        </button>
      </div>
    </main>
  )
}
