import Locations from '../../../../screens/Locations'
import { requireTeamManager } from '../../../../lib/staffAccessServer'

export default async function LocationsPage() {
  await requireTeamManager()
  return <Locations />
}
