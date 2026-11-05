import LocationDetail from '../../../../../screens/LocationDetail'
import { requireTeamManager } from '../../../../../lib/staffAccessServer'

export default async function LocationDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requireTeamManager()
  const { id } = await params
  return <LocationDetail locationId={id} />
}
