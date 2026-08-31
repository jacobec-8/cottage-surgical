import Link from 'next/link'
import { LockKeyhole } from 'lucide-react'

export default function AccessLimitedPage() {
  return (
    <div className="max-w-lg bg-white border border-slate-200 rounded-2xl p-8 text-center mx-auto mt-12">
      <LockKeyhole size={32} className="text-slate-400 mx-auto mb-3" />
      <h1 className="text-2xl font-semibold mb-2">Access limited</h1>
      <p className="text-sm text-slate-500 mb-5">
        An administrator has locked this module for store staff. Use an available navigation item or contact an administrator.
      </p>
      <Link href="/admin" className="text-sm text-blue-600 hover:underline">Return to dashboard</Link>
    </div>
  )
}
