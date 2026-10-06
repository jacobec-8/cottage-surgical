import LocationOnboarding from '../../../../../screens/LocationOnboarding'
import { requireAdmin } from '../../../../../lib/staffAccessServer'

export default async function LocationOnboardingPage() {
  await requireAdmin()
  return <LocationOnboarding />
}
