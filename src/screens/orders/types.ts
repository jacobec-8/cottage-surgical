/** Shapes returned by the Orders list + detail queries (Supabase joins). */

export type OrderCustomer = {
  id?: string
  full_name: string
  phone: string | null
  email: string | null
  coverage_type?: string | null
}

export type OrderUnit = { asset_tag: string | null; serial_number: string | null } | null

export type OrderLine = {
  id?: string
  quantity: number
  line_type?: string
  monthly_rate: number | null
  sale_price: number | null
  is_active: boolean
  equipment_unit_id: string | null
  equipment: { name: string } | null
  unit: OrderUnit
}

export type OrderDriver = { first_name: string; last_name: string } | null

export type OrderDelivery = {
  id: string
  leg_type: 'delivery' | 'pickup' | string
  status: string
  scheduled_date: string | null
  window_start: string | null
  window_end: string | null
  window_label: string | null
  driver: OrderDriver
  // detail-only
  address_line1?: string | null
  address_city?: string | null
  address_state?: string | null
  address_zip?: string | null
  notes?: string | null
  started_at?: string | null
  completed_at?: string | null
  delivery_photos?: { storage_path: string }[]
}

/** Row shape for the list cards. */
export type Order = {
  id: string
  order_no: number
  order_type: string
  status: string
  source: string | null
  payment_status: string | null
  payment_preference?: 'in_store' | 'online' | string | null
  stripe_session_id: string | null
  created_at: string
  updated_at: string
  start_date: string | null
  end_date: string | null
  monthly_rate: number | null
  deposit_amount: number | null
  special_notes: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
  fulfillment_method?: 'pickup' | 'delivery' | string | null
  pickup_location?: {
    name: string
    address_line1: string
    address_line2: string | null
    address_city: string
    address_state: string
    address_zip: string
  } | null
  customer: OrderCustomer | null
  rental_line_items: OrderLine[]
  deliveries: OrderDelivery[]
}

export type RecurringCharge = {
  id: string
  amount: number
  status: string
  billing_start: string | null
  billing_end: string | null
  next_due_date: string | null
  last_billed_on: string | null
}

export type Deposit = {
  id: string
  amount: number
  status: string
  held_at: string
}

/** Full shape for the detail panel. */
export type OrderDetail = Order & {
  square_order_id: string | null
  closed_reason: string | null
  closed_at: string | null
  closed_by_profile: { full_name: string | null; email: string | null } | null
  recurring_charges: RecurringCharge[]
  deposits: Deposit[]
}

const LINE_SELECT =
  'rental_line_items(id,quantity,line_type,monthly_rate,sale_price,is_active,equipment_unit_id,' +
  'equipment:equipment_items(name),unit:equipment_units(asset_tag,serial_number))'

const DELIVERY_LIST_SELECT =
  'deliveries(id,leg_type,status,scheduled_date,window_start,window_end,window_label,' +
  'driver:drivers!deliveries_driver_id_fkey(first_name,last_name))'

const DELIVERY_DETAIL_SELECT =
  'deliveries(id,leg_type,status,scheduled_date,window_start,window_end,window_label,' +
  'address_line1,address_city,address_state,address_zip,notes,started_at,completed_at,' +
  'driver:drivers!deliveries_driver_id_fkey(first_name,last_name),delivery_photos(storage_path))'

const ORDER_BASE =
  'id,order_no,order_type,status,source,payment_status,payment_preference,stripe_session_id,created_at,updated_at,' +
  'start_date,end_date,monthly_rate,deposit_amount,special_notes,' +
  'address_line1,address_city,address_state,address_zip,fulfillment_method,' +
  'pickup_location:pickup_locations(name,address_line1,address_line2,address_city,address_state,address_zip)'

export const ORDER_LIST_SELECT =
  `${ORDER_BASE},customer:customers(full_name,phone,email),${LINE_SELECT},${DELIVERY_LIST_SELECT}`

export const ORDER_DETAIL_SELECT =
  `${ORDER_BASE},square_order_id,closed_reason,closed_at,` +
  'closed_by_profile:profiles!rental_orders_closed_by_fkey(full_name,email),' +
  'customer:customers(id,full_name,phone,email,coverage_type),' +
  `${LINE_SELECT},${DELIVERY_DETAIL_SELECT},` +
  'recurring_charges(id,amount,status,billing_start,billing_end,next_due_date,last_billed_on),' +
  'deposits(id,amount,status,held_at)'

/** Order statuses that may have a pickup queued from the Orders screen. */
export const PICKUP_ELIGIBLE: ReadonlySet<string> = new Set(['active', 'overdue', 'delivered'])

/** Equipment not yet delivered → "Cancel order" (releases stock, cancels legs). */
export const CANCELLABLE: ReadonlySet<string> = new Set(['requested', 'open', 'pending', 'scheduled', 'pending_payment'])
/** Equipment is out (or came back untracked) → "Close out" (units available, order closed). */
export const CLOSEABLE: ReadonlySet<string> = new Set(['delivered', 'active', 'overdue', 'pickup_scheduled'])
