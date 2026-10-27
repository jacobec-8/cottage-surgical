import StaffDirectory from '../../../../screens/StaffDirectory'
import { requireTeamManager } from '../../../../lib/staffAccessServer'

export default async function StaffPage() {
  await requireTeamManager()
  return <StaffDirectory />
}
