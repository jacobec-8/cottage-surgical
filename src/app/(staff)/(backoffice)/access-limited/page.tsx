import Link from 'next/link'
import { LockKeyhole } from 'lucide-react'

type Props = { searchParams: Promise<{ [key: string]: string | string[] | undefined }> }

// Admin-only areas are a role restriction, not a module an admin switched off.
const COPY = {
  admin_only: 'This area is for administrators only. Your staff account can’t open it. Use an available navigation item or ask an administrator.',
  module_off: 'An administrator has turned this module off for store staff. Use an available navigation item or ask an administrator to turn it on.',
}

export default async function AccessLimitedPage({ searchParams }: Props) {
  const { reason } = await searchParams
  const message = reason === 'admin_only' ? COPY.admin_only : COPY.module_off
  return (
    <div className="max-w-lg bg-white border border-slate-200 rounded-2xl p-8 text-center mx-auto mt-12">
      <LockKeyhole size={32} className="text-slate-400 mx-auto mb-3" />
      <h1 className="text-2xl font-semibold mb-2">{reason === 'admin_only' ? 'Administrators only' : 'Module turned off'}</h1>
      <p className="text-sm text-slate-500 mb-5">{message}</p>
      <Link href="/admin" className="text-sm text-blue-600 hover:underline">Return to dashboard</Link>
    </div>
  )
}
