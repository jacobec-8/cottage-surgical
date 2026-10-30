import { redirect } from 'next/navigation'

// New requests now sit at the top of Orders; keep old links and bookmarks working.
export default function RequestsPage() {
  redirect('/orders?filter=requests')
}
