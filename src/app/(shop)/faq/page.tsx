import type { Metadata } from 'next'
import FAQ from '../../../screens/shop/FAQ'

export const metadata: Metadata = {
  title: 'Equipment Rental FAQ | Cottage Surgical',
  description:
    'Answers about Cottage Surgical rental periods, delivery, setup, service, payment, and coverage across Nassau and Suffolk County.',
}

export default function FAQPage() {
  return <FAQ />
}
