// Catalog categories allowed by equipment_items_category_check (091).
// Stored lowercase; screens show them with CSS `capitalize`.
export const RENTAL_CATEGORIES = ['mobility', 'seating', 'bedroom', 'respiratory'] as const

export const RETAIL_CATEGORIES = [
  'braces & supports', 'compression', 'cushions & positioning', 'home health',
  'hot & cold therapy', 'incontinence & toileting', 'mobility accessories', 'mobility aids',
  'ostomy', 'personal care', 'wound care',
] as const

export const CATEGORIES: readonly string[] = [...RENTAL_CATEGORIES, ...RETAIL_CATEGORIES]
