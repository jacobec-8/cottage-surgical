import StaffAccess from '../../../../screens/StaffAccess'
import { requireTeamManager } from '../../../../lib/staffAccessServer'

export default async function StaffAccessPage() {
  // Module switches are per store (100); owners set them for their own stores.
  await requireTeamManager()
  return <StaffAccess />
}
