import StaffDirectory from '../../../../screens/StaffDirectory'
import { requireAdmin } from '../../../../lib/staffAccessServer'

export default async function StaffPage() {
  await requireAdmin()
  return <StaffDirectory />
}
