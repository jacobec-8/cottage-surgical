import StaffAccess from '../../../../screens/StaffAccess'
import { requireAdmin } from '../../../../lib/staffAccessServer'

export default async function StaffAccessPage() {
  await requireAdmin()
  return <StaffAccess />
}
