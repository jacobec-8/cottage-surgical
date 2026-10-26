import BusinessOnboarding from '../../../../../screens/onboarding/BusinessOnboarding'
import { requireAdmin } from '../../../../../lib/staffAccessServer'

export default async function LocationOnboardingPage() {
  await requireAdmin()
  return <BusinessOnboarding />
}
