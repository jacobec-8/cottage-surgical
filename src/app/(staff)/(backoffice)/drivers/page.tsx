import Drivers from '../../../../screens/Drivers'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

export default async function DriversPage() {
  await requireStaffModule('drivers')
  return <Drivers />
}
