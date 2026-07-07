import type { Product } from './types'

// Offline preview data. Used ONLY when Supabase isn't configured (no anon key),
// so the pages + rent/buy flow can be reviewed with nothing wired up. Once
// NEXT_PUBLIC_SUPABASE_ANON_KEY is set (always true in production), the real
// catalog is used and none of this is reachable.
export const DEMO_PRODUCTS: Product[] = [
  {
    id: 'demo-standard-wheelchair', name: 'Standard Wheelchair', category: 'mobility',
    description: 'Durable folding wheelchair with padded armrests and swing-away footrests. Supports up to 300 lbs.',
    monthly_rental_price: 45, sale_price: 180, is_rentable: true, is_purchasable: true,
    image_url: null, shopify_handle: 'standard-wheelchair',
  },
  {
    id: 'demo-transport-chair', name: 'Lightweight Transport Chair', category: 'mobility',
    description: 'Compact companion-pushed chair, under 20 lbs, folds flat for the car.',
    monthly_rental_price: 40, sale_price: 160, is_rentable: true, is_purchasable: true,
    image_url: null, shopify_handle: 'lightweight-transport-chair',
  },
  {
    id: 'demo-knee-scooter', name: 'Steerable Knee Scooter', category: 'mobility',
    description: 'Hands-free alternative to crutches for foot and ankle recovery. Adjustable steering and knee pad.',
    monthly_rental_price: 55, sale_price: 240, is_rentable: true, is_purchasable: true,
    image_url: null, shopify_handle: 'knee-scooter',
  },
  {
    id: 'demo-rollator', name: 'Rollator Walker with Seat', category: 'mobility',
    description: 'Four-wheel walker with hand brakes, padded seat, and storage pouch.',
    monthly_rental_price: null, sale_price: 95, is_rentable: false, is_purchasable: true,
    image_url: null, shopify_handle: 'rollator-walker',
  },
  {
    id: 'demo-hospital-bed', name: 'Semi-Electric Hospital Bed', category: 'beds',
    description: 'Adjustable head and foot with electric controls; manual height. Includes rails and mattress.',
    monthly_rental_price: 175, sale_price: null, is_rentable: true, is_purchasable: false,
    image_url: null, shopify_handle: 'semi-electric-hospital-bed',
  },
  {
    id: 'demo-oxygen-concentrator', name: '5L Stationary Oxygen Concentrator', category: 'respiratory',
    description: 'Continuous-flow oxygen up to 5 liters/min for home use. Quiet operation.',
    monthly_rental_price: 200, sale_price: null, is_rentable: true, is_purchasable: false,
    image_url: null, shopify_handle: 'oxygen-concentrator-5l',
  },
  {
    id: 'demo-portable-oxygen', name: 'Portable Oxygen Concentrator', category: 'respiratory',
    description: 'Lightweight, battery-powered concentrator for travel and daily errands. FAA-approved.',
    monthly_rental_price: 250, sale_price: 1800, is_rentable: true, is_purchasable: true,
    image_url: null, shopify_handle: 'portable-oxygen-concentrator',
  },
  {
    id: 'demo-lift-chair', name: '3-Position Lift Chair', category: 'lift chairs',
    description: 'Power recline and lift-to-stand assist. Plush upholstery, side pocket.',
    monthly_rental_price: 150, sale_price: 720, is_rentable: true, is_purchasable: true,
    image_url: null, shopify_handle: 'lift-chair-3-position',
  },
  {
    id: 'demo-commode', name: 'Bedside Commode', category: 'bathroom safety',
    description: 'Height-adjustable commode with removable bucket and splash guard.',
    monthly_rental_price: null, sale_price: 65, is_rentable: false, is_purchasable: true,
    image_url: null, shopify_handle: 'bedside-commode',
  },
  {
    id: 'demo-transfer-bench', name: 'Tub Transfer Bench', category: 'bathroom safety',
    description: 'Slide-in bench for safe tub entry. Adjustable legs, reversible design.',
    monthly_rental_price: null, sale_price: 85, is_rentable: false, is_purchasable: true,
    image_url: null, shopify_handle: 'tub-transfer-bench',
  },
]

export function findDemoProduct(handle: string): Product | null {
  return DEMO_PRODUCTS.find((p) => p.shopify_handle === handle || p.id === handle) ?? null
}
