import Reports from '../../../../screens/Reports'

// Back office only (drivers are redirected by the layout). What each role sees
// is decided by the report functions: money for owners and admins only.
export default function ReportsPage() {
  return <Reports />
}
