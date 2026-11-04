'use client'

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { CheckCircle2, X } from 'lucide-react'

const SHOW_MS = 5000

type Notify = (message: string) => void
const NoticeContext = createContext<Notify | null>(null)

/** The "Saved" confirmation for the staff app. It survives the form closing. */
export function SaveNoticeProvider({ children }: { children: ReactNode }) {
  const [notice, setNotice] = useState<{ message: string; id: number } | null>(null)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const notify = useCallback<Notify>((message) => {
    if (timer.current) clearTimeout(timer.current)
    setNotice({ message, id: Date.now() })
    timer.current = setTimeout(() => setNotice(null), SHOW_MS)
  }, [])
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current) }, [])

  return (
    <NoticeContext.Provider value={notify}>
      {children}
      {/* Always mounted, so screen readers announce each new message. */}
      <div role="status" aria-live="polite" className="pointer-events-none fixed inset-x-4 bottom-4 z-[60] flex justify-center sm:inset-x-auto sm:right-6 sm:justify-end">
        {notice && (
          <div key={notice.id} data-testid="save-notice" className="pointer-events-auto flex max-w-md items-start gap-2 rounded-xl bg-emerald-700 px-4 py-3 text-sm font-medium text-white shadow-lg">
            <CheckCircle2 size={18} className="mt-px shrink-0" aria-hidden="true" />
            <span className="min-w-0 flex-1">{notice.message}</span>
            <button type="button" aria-label="Dismiss" onClick={() => setNotice(null)} className="-mr-1 grid h-6 w-6 shrink-0 place-items-center rounded text-emerald-100 hover:bg-emerald-800 hover:text-white">
              <X size={14} />
            </button>
          </div>
        )}
      </div>
    </NoticeContext.Provider>
  )
}

/** Null outside the staff shell; SaveForm then confirms inline instead. */
export function useSaveNotice(): Notify | null {
  return useContext(NoticeContext)
}
