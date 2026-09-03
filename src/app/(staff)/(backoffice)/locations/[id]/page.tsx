import LocationDetail from '../../../../../screens/LocationDetail'
import { requireAdmin } from '../../../../../lib/staffAccessServer'

export default async function LocationDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requireAdmin()
  const { id } = await params
  return <LocationDetail locationId={id} />
}
