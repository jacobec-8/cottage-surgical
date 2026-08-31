import Dashboard from '../../../../screens/Dashboard'
import { requireStaffModule } from '../../../../lib/staffAccessServer'

export default async function DashboardPage() {
  await requireStaffModule('dashboard')
  return <Dashboard />
}
