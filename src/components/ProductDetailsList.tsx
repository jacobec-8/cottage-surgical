import { fulfillmentLabel } from '../lib/fulfillment'

export type ProductDetailsItem = {
  pickup_enabled: boolean
  delivery_enabled: boolean
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  is_rentable: boolean
  is_purchasable: boolean
  same_day_pickup: boolean
  installation_required: boolean
  created_at: string
  updated_at: string
}

/** Prices, offering and fulfillment facts; shared by the product page and the expanded inventory row. */
export default function ProductDetailsList({ item }: { item: ProductDetailsItem }) {
  return (
    <dl className="grid sm:grid-cols-2 gap-x-8 gap-y-4 text-sm">
      <Detail label="Pickup rental" value={!item.pickup_enabled || item.pickup_rental_price == null ? 'Not offered' : `$${Number(item.pickup_rental_price).toFixed(2)}/mo`} />
      <Detail label="Delivery + return pickup" value={!item.delivery_enabled || item.delivery_rental_price == null ? 'Not offered' : `$${Number(item.delivery_rental_price).toFixed(2)}/mo`} />
      <Detail label="Sale price" value={item.sale_price == null ? 'Not set' : `$${Number(item.sale_price).toFixed(2)}`} />
      <Detail label="Rental enabled" value={item.is_rentable ? 'Yes' : 'No'} />
      <Detail label="Purchase enabled" value={item.is_purchasable ? 'Yes' : 'No'} />
      <Detail label="Fulfillment" value={fulfillmentLabel(item)} />
      <Detail label="Same-day pickup" value={item.pickup_enabled && item.same_day_pickup ? 'May be available' : 'No'} />
      <Detail label="Installation required" value={item.installation_required ? 'Yes' : 'No'} />
      <Detail label="Created" value={new Date(item.created_at).toLocaleDateString()} />
      <Detail label="Last updated" value={new Date(item.updated_at).toLocaleString()} />
    </dl>
  )
}

function Detail({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-xs text-slate-400 uppercase tracking-wide mb-1">{label}</dt><dd className="font-medium text-slate-800">{value}</dd></div>
}
