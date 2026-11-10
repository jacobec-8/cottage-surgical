import Business from '../../../../screens/Business'
import { requireTeamManager } from '../../../../lib/staffAccessServer'

export default async function BusinessPage() {
  await requireTeamManager()
  return <Business />
}
