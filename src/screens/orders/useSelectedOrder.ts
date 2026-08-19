'use client'

import { useCallback } from 'react'
import { useSearchParams } from 'next/navigation'
import { withSelectedParam } from './selectedParam'

export const SELECTED_ORDER_PARAM = 'order'

/**
 * Selected order id lives in `?order=<id>` so a detail view is linkable and
 * refresh-safe. Written with native replaceState (null state, so Next's patched
 * history syncs useSearchParams) — no server round-trip, no history entry.
 */
export function useSelectedOrder(): [string | null, (id: string | null) => void] {
  const params = useSearchParams()
  const selected = params.get(SELECTED_ORDER_PARAM)
  const setSelected = useCallback((id: string | null) => {
    window.history.replaceState(null, '', withSelectedParam(window.location.href, SELECTED_ORDER_PARAM, id))
  }, [])
  return [selected, setSelected]
}
