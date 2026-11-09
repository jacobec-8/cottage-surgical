'use client'

import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'

/** A stop's proof photo from the private delivery-photos bucket; opens full size in a new tab. */
export default function ProofPhoto({ path, size = 'w-24 h-24' }: { path: string; size?: string }) {
  const { data: url } = useQuery({
    queryKey: ['photo', path],
    queryFn: async () => {
      const { data } = await supabase.storage.from('delivery-photos').createSignedUrl(path, 3600)
      return data?.signedUrl ?? null
    },
    staleTime: 50 * 60 * 1000,
  })
  if (!url) return <div className={`${size} bg-slate-100 rounded-lg grid place-items-center text-slate-300 text-[11px] shrink-0`}>photo</div>
  return (
    <a href={url} target="_blank" rel="noreferrer" className="shrink-0" title="Open proof photo">
      <img src={url} alt="Proof of delivery" className={`${size} object-cover rounded-lg border border-slate-200`} />
    </a>
  )
}
