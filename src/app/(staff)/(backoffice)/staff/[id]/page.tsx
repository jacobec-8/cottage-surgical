import StaffDetail from '../../../../../screens/StaffDetail'
import { requireTeamManager } from '../../../../../lib/staffAccessServer'

export default async function StaffDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requireTeamManager()
  const { id } = await params
  return <StaffDetail profileId={id} />
}
