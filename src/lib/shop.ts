export type Product = {
  id: string
  name: string
  description: string | null
  category: string
  monthly_rental_price: number | null
  sale_price: number | null
  image_url: string | null
  shopify_handle: string | null
  is_rentable: boolean
  is_purchasable: boolean
}

// quantity_on_hand deliberately NOT exposed to the public shop.
export const PRODUCT_FIELDS =
  'id,name,description,category,monthly_rental_price,sale_price,image_url,shopify_handle,is_rentable,is_purchasable'
