export type Product = {
  id: string
  name: string
  description: string | null
  category: string
  monthly_rental_price: number | null
  sale_price: number | null
  image_url: string | null
  shopify_handle: string | null
  quantity_on_hand: number
}

export const PRODUCT_FIELDS =
  'id,name,description,category,monthly_rental_price,sale_price,image_url,shopify_handle,quantity_on_hand'
