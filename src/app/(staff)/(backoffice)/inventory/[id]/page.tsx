import InventoryItemDetail from '../../../../../screens/InventoryItemDetail'
import { requireStaffModule } from '../../../../../lib/staffAccessServer'

export default async function InventoryItemPage({ params }: { params: Promise<{ id: string }> }) {
  await requireStaffModule('inventory')
  const { id } = await params
  return <InventoryItemDetail itemId={id} />
}
