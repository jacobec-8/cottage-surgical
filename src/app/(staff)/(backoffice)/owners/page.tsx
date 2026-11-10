import Owners from '../../../../screens/admin/Owners'
import { requireAdmin } from '../../../../lib/staffAccessServer'

export default async function OwnersPage() {
  await requireAdmin()
  return <Owners />
}
