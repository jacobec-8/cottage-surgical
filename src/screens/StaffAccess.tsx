'use client'

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { LockKeyhole, LockOpen, ShieldCheck } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from '../lib/supabase'
import { STAFF_MODULES, type StaffModule } from '../lib/staffModules'
import { useStaffModuleAccess } from '../lib/useStaffModuleAccess'

export default function StaffAccess() {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const access = useStaffModuleAccess()
  const update = useMutation({
    mutationFn: async ({ modules, enabled }: { modules: StaffModule[]; enabled: boolean }) => {
      const { error } = await supabase
        .from('staff_module_access')
        .update({ enabled, updated_at: new Date().toISOString(), updated_by: profile?.id ?? null })
        .in('module_key', modules)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['staff_module_access'] }),
  })

  const setOne = (module: StaffModule, enabled: boolean) => update.mutate({ modules: [module], enabled })
  const setAll = (enabled: boolean) => update.mutate({ modules: STAFF_MODULES.map(({ key }) => key), enabled })

  return (
    <div className="max-w-4xl">
      <div className="mb-6 flex flex-col items-start gap-4 sm:flex-row sm:justify-between">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <ShieldCheck className="text-blue-600" size={24} />
            <h1 className="text-2xl font-semibold">Staff Access</h1>
          </div>
          <p className="text-sm text-slate-500">
            Choose which operational modules store staff can use. Admin access and the driver app are unaffected.
          </p>
        </div>
        <div className="grid w-full shrink-0 grid-cols-2 gap-2 sm:flex sm:w-auto">
          <button onClick={() => setAll(false)} disabled={update.isPending}
            className="min-h-11 rounded-lg border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50 disabled:opacity-50">
            Lock all
          </button>
          <button onClick={() => setAll(true)} disabled={update.isPending}
            className="min-h-11 rounded-lg bg-blue-600 px-3 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50">
            Unlock all
          </button>
        </div>
      </div>

      {access.isLoading && <div className="text-sm text-slate-500">Loading access controls…</div>}
      {access.error && <div className="text-sm text-red-600">Couldn’t load staff access controls.</div>}
      {update.error && <div className="text-sm text-red-600 mb-3">{(update.error as Error).message}</div>}

      <div className="grid md:grid-cols-2 gap-3">
        {STAFF_MODULES.map((module) => {
          const enabled = access.settings[module.key]
          return (
            <div key={module.key} className="bg-white border border-slate-200 rounded-xl p-4 flex items-start justify-between gap-4">
              <div>
                <div className="font-medium text-slate-900">{module.label}</div>
                <div className="text-sm text-slate-500 mt-1">{module.description}</div>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={enabled}
                aria-label={`${enabled ? 'Lock' : 'Unlock'} ${module.label}`}
                disabled={access.isLoading || update.isPending}
                onClick={() => setOne(module.key, !enabled)}
                className={`shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm font-medium disabled:opacity-50 ${
                  enabled ? 'bg-emerald-100 text-emerald-700' : 'bg-slate-200 text-slate-600'
                }`}
              >
                {enabled ? <LockOpen size={14} /> : <LockKeyhole size={14} />}
                {enabled ? 'Unlocked' : 'Locked'}
              </button>
            </div>
          )
        })}
      </div>
    </div>
  )
}
