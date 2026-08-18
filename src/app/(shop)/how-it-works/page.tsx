import type { Metadata } from 'next'
import HowItWorks from '../../../screens/shop/HowItWorks'

export const metadata: Metadata = {
  title: 'How Equipment Rental Works | Cottage Surgical',
  description:
    'Learn how Cottage Surgical confirms, delivers, sets up, and services home medical equipment rentals across Long Island.',
}

export default function HowItWorksPage() {
  return <HowItWorks />
}
