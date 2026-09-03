import Locations from '../../../../screens/Locations'
import { requireAdmin } from '../../../../lib/staffAccessServer'

export default async function LocationsPage() {
  await requireAdmin()
  return <Locations />
}
