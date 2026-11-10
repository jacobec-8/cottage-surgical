import OwnerSetup from '../../../../screens/setup/OwnerSetup'
import { requireTeamManager } from '../../../../lib/staffAccessServer'

export default async function OwnerSetupPage() {
  await requireTeamManager()
  return <OwnerSetup />
}
