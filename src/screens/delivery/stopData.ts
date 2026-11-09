'use client'

import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { DRIVER_LOCATION_FIELDS } from '../../lib/driverLocations'
import type { DriverOption } from './types'

/** One stop as the Delivery board and the request flow read it (shape: Deliv). */
export const STOP_SELECT =
  'id,leg_type,status,scheduled_date,window_start,window_end,started_at,completed_at,address_line1,address_city,address_state,address_zip,driver_id,requires_driver,location_id,location:pickup_locations!deliveries_location_id_fkey(name),' +
  'driver:drivers!deliveries_driver_id_fkey(first_name,last_name),' +
  'order:rental_orders(id,order_no,payment_status,payment_preference,customer:customers(full_name),rental_line_items(quantity,equipment:equipment_items(name,image_url))),' +
  'delivery_photos(storage_path,captured_at,notes),attempts:stop_attempts(reason,note,created_at)'

/** Every driver this scope can assign, home or shared; each stop lists only those set up for its location (3LOC-002). */
export function useActiveDrivers(enabled: boolean) {
  return useQuery({
    queryKey: ['drivers', 'active', 'locations'],
    enabled,
    queryFn: async () => {
      const { data } = await supabase
        .from('drivers')
        .select(`id,first_name,last_name,user_id,${DRIVER_LOCATION_FIELDS}`)
        .eq('status', 'active')
        .order('first_name')
      return (data ?? []) as DriverOption[]
    },
  })
}
