import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { SummaryOrder } from './customerSummary'

export type CustomerRecord = {
  id: string
  full_name: string
  phone: string | null
  email: string | null
  date_of_birth: string | null
  coverage_type: string | null
  insurance_notes: string | null
  notes: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
  created_at: string
}

export type CustomerDetail = { customer: CustomerRecord; orders: SummaryOrder[] }

const CUSTOMER_SELECT =
  'id,full_name,phone,email,date_of_birth,coverage_type,insurance_notes,notes,' +
  'address_line1,address_city,address_state,address_zip,created_at'

const ORDER_SELECT =
  'id,order_no,order_type,status,created_at,monthly_rate,' +
  'rental_line_items(quantity,is_active,equipment:equipment_items(name)),' +
  'deliveries(id,leg_type,requires_driver,status,scheduled_date,window_start,window_end),' +
  'recurring_charges(amount,status,next_due_date),deposits(amount,status)'

/**
 * One customer with everything the side pane shows. Keyed under 'customers' so
 * order-workflow invalidations refresh it; RLS keeps it to the viewer's stores.
 */
export function useCustomerDetail(customerId: string | null) {
  return useQuery({
    queryKey: ['customers', 'detail', customerId],
    enabled: Boolean(customerId),
    staleTime: 0,
    refetchInterval: 15_000,
    queryFn: async (): Promise<CustomerDetail | null> => {
      const id = customerId as string
      const [customer, orders] = await Promise.all([
        supabase.from('customers').select(CUSTOMER_SELECT).eq('id', id).maybeSingle()
          .overrideTypes<CustomerRecord | null, { merge: false }>(),
        supabase.from('rental_orders').select(ORDER_SELECT).eq('customer_id', id).order('created_at', { ascending: false })
          .overrideTypes<SummaryOrder[], { merge: false }>(),
      ])
      const failed = customer.error ?? orders.error
      if (failed) throw failed
      if (!customer.data) return null
      return { customer: customer.data, orders: orders.data ?? [] }
    },
  })
}
