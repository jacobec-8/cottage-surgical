import Link from 'next/link'

export default function NotFound() {
  return (
    <main className="min-h-screen grid place-items-center p-6 text-center">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">Page not found</h1>
        <p className="mt-2 text-sm text-slate-600">The page you requested does not exist.</p>
        <Link href="/" className="mt-5 inline-block font-semibold text-brand-600 hover:underline">
          Back to equipment
        </Link>
      </div>
    </main>
  )
}
