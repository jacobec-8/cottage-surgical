import { supabase } from '../../lib/supabase'
import { parseAssetTags } from '../../lib/storeProducts'

/** A new product's first stock at a pharmacy: attach it there, then count or units (Inventory and the setup wizard). */
export async function addStartingStock(itemId: string, locationId: string, serialized: boolean, pickup: boolean, stock: string) {
  // Store products are attached by the database (100); the owner's products are attached here.
  const { error: attachError } = await supabase.from('equipment_location_inventory')
    .upsert({ equipment_item_id: itemId, location_id: locationId, quantity_on_hand: 0, pickup_enabled: pickup }, { onConflict: 'equipment_item_id,location_id', ignoreDuplicates: true })
  if (attachError) throw new Error('The product was created, but couldn’t be added to this store. Add it from the catalog.')
  if (serialized) {
    const tags = parseAssetTags(stock)
    if (!tags.length) return
    const { error } = await supabase.from('equipment_units').insert(tags.map((tag) => ({ item_id: itemId, location_id: locationId, asset_tag: tag, status: 'available' })))
    if (error) throw new Error(error.code === '23505' ? 'The product was created, but an asset tag is already used at this store. Add units from the product.' : 'The product was created, but its units couldn’t be added.')
    return
  }
  if (!stock.trim()) return
  const { error } = await supabase.from('equipment_location_inventory').update({ quantity_on_hand: Number(stock) })
    .eq('equipment_item_id', itemId).eq('location_id', locationId)
  if (error) throw new Error('The product was created, but its stock couldn’t be saved. Set it from the product.')
}
