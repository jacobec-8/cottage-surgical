export type ShopCategory = { label: string; tagline: string; cta: string; q: string; img: string }

// The "Shop by category" tiles, most used first. q= filters the live catalog, so
// each tile resolves to real items. No true walker/rollator is stocked yet, so the
// third tile is honestly "Knee Walkers"; the last two open one product by name.
export const SHOP_CATEGORIES: readonly ShopCategory[] = [
  { label: 'Wheelchairs', tagline: 'Transport, lightweight & reclining chairs', cta: 'Shop Wheelchairs', q: 'wheelchair', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/f9e676d2-a92a-42ec-a1ce-238fbc831e12._CR0_0_300_300_PT0_SX300__-Copy.jpg?v=1635358384' },
  { label: 'Hospital Beds', tagline: 'Adjustable beds, over-bed tables & trapeze bars', cta: 'Shop Hospital Beds', q: 'bed', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/bed.jpg?v=1550251687' },
  { label: 'Knee Walkers', tagline: 'Steerable knee scooters — a hands-free crutch alternative', cta: 'Shop Knee Walkers', q: 'knee', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/Knee_Scooter.jpg?v=1550251688' },
  { label: '3 Position Seat Lift Chair', tagline: 'Medical recliner with 3-position and infinite-position seating', cta: 'Shop Lift Chair', q: '3 Position Seat Lift Chair', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/71PAW-IkmML._SX522.jpg?v=1550251686' },
  { label: '5 Liter Compact Stationary Oxygen Concentrator', tagline: 'Compact 5 liter unit for supplemental oxygen at home', cta: 'Shop Oxygen Concentrator', q: '5 Liter Compact Stationary Oxygen Concentrator', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/devilbiss-oxygen-concentrator-5-liter-d54.png?v=1550251699' },
]
