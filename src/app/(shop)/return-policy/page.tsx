import type { Metadata } from 'next'
import ReturnPolicy from '../../../screens/shop/ReturnPolicy'

export const metadata: Metadata = {
  title: 'Return & Refund Policy | Cottage Surgical',
  description:
    'Review Cottage Surgical rental returns, refundable deposits, equipment damage, and hygiene-item policies.',
}

export default function ReturnPolicyPage() {
  return <ReturnPolicy />
}
