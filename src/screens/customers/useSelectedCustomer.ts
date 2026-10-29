'use client'

import { useCallback } from 'react'
import { useSearchParams } from 'next/navigation'
import { withSelectedParam } from '../orders/selectedParam'

export const SELECTED_CUSTOMER_PARAM = 'customer'

/** Selected customer id lives in `?customer=<id>`, like `?order=` on Orders: linkable and refresh-safe. */
export function useSelectedCustomer(): [string | null, (id: string | null) => void] {
  const params = useSearchParams()
  const selected = params.get(SELECTED_CUSTOMER_PARAM)
  const setSelected = useCallback((id: string | null) => {
    window.history.replaceState(null, '', withSelectedParam(window.location.href, SELECTED_CUSTOMER_PARAM, id))
  }, [])
  return [selected, setSelected]
}
