import StaffDetail from '../../../../../screens/StaffDetail'
import { requireAdmin } from '../../../../../lib/staffAccessServer'

export default async function StaffDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requireAdmin()
  const { id } = await params
  return <StaffDetail profileId={id} />
}
