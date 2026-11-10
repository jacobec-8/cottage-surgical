import Home from '../../../../screens/Home'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

export default async function DashboardPage() {
  await requireStaffModule('dashboard')
  return <Home />
}
