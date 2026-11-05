// Storefront questions and answers: the FAQ page shows them all, product pages a few.
export type Faq = { readonly q: string; readonly a: string }

export const FAQS: readonly Faq[] = [
  { q: 'How does renting work?', a: 'Choose your equipment, place a request, and we deliver it set up and ready to use. Rentals are month-to-month with a refundable security deposit — keep it as long as you need and we pick it up when you’re done.' },
  { q: 'What payment methods do you accept?', a: 'All major credit/debit cards and ACH bank transfers. We’re private-pay and can provide itemized receipts you can submit to insurance or an HSA/FSA.' },
  { q: 'How quickly can equipment be delivered?', a: 'Most in-stock items ordered before 2 PM are delivered the same day across Nassau and Suffolk County. Otherwise, next-day is standard.' },
  { q: 'What is the minimum rental period?', a: 'One month. After that, rentals continue month-to-month with no long-term commitment — cancel any time with a pickup.' },
  { q: 'Can I purchase instead of rent?', a: 'We’re rental-only right now. If you’d like to buy a piece of equipment outright, give us a call and we’ll help you directly.' },
  { q: 'What happens if equipment breaks down?', a: 'Call us and we’ll repair or swap the item at no charge for normal wear. Service is included for the life of the rental.' },
  { q: 'Is setup included in the rental?', a: 'Always. A licensed technician delivers, assembles, and demonstrates every item — nothing arrives in a box for you to build.' },
  { q: 'Do you service my area?', a: 'We deliver throughout Nassau and Suffolk County, NY. Not sure about your town? Call us and we’ll confirm.' },
  { q: 'Can I extend my rental?', a: 'Absolutely — rentals renew automatically each month. Keep it as long as you need; there’s no paperwork to extend.' },
]
