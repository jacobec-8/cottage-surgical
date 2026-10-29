import type { ReactNode } from 'react'
import { CartProvider } from '../../components/shop/CartContext'
import Providers from '../providers'
import CustomerAssistant from '../../components/shop/CustomerAssistant'

export default function ShopLayout({ children }: { children: ReactNode }) {
  return (
    <Providers>
      <CartProvider>{children}<CustomerAssistant /></CartProvider>
    </Providers>
  )
}
