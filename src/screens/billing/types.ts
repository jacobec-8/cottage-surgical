/** Billing screen row: a recurring charge joined to its order (items, legs, deposits). */

export type BillingLeg = {
  id: string
  leg_type: string
  status: string
  scheduled_date: string | null
  completed_at: string | null
}

export type BillingOrder = {
  id: string
  order_no: number
  status: string
  order_type: string
  start_date: string | null
  end_date: string | null
  deposit_amount: number | null
  rental_line_items: { quantity: number; equipment: { name: string } | null }[]
  deliveries: BillingLeg[]
  deposits: { amount: number; status: string }[]
}

export type Charge = {
  id: string
  amount: number
  status: string // current | overdue | paused | ended
  billing_start: string | null
  billing_end: string | null
  next_due_date: string | null
  last_billed_on: string | null
  customer: { full_name: string; phone: string | null } | null
  order: BillingOrder | null
}

export const CHARGE_SELECT =
  'id,amount,status,billing_start,billing_end,next_due_date,last_billed_on,' +
  'customer:customers(full_name,phone),' +
  'order:rental_orders(id,order_no,status,order_type,start_date,end_date,deposit_amount,' +
  'rental_line_items(quantity,equipment:equipment_items(name)),' +
  'deliveries(id,leg_type,status,scheduled_date,completed_at),' +
  'deposits(amount,status))'
