import NewOrder from '../../../../screens/NewOrder'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

export default async function NewOrderPage() {
  await requireStaffModule('new_order')
  return <NewOrder />
}
