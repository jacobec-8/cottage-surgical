import Inventory from '../../../../screens/Inventory'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

export default async function InventoryPage() {
  await requireStaffModule('inventory')
  return <Inventory />
}
