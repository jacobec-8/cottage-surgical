import Customers from '../../../../screens/Customers'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

export default async function CustomersPage() {
  await requireStaffModule('customers')
  return <Customers />
}
