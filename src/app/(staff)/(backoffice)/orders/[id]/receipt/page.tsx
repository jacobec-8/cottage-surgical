import OrderReceipt from '../../../../../../screens/receipt/OrderReceipt'
import { requireStaffModule } from '../../../../../../lib/staffAccessServer'

export default async function OrderReceiptPage({ params }: { params: Promise<{ id: string }> }) {
  await requireStaffModule(['orders', 'requests'])
  const { id } = await params
  return <OrderReceipt orderId={id} />
}
