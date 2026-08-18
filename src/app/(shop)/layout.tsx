import type { ReactNode } from 'react'
import { CartProvider } from '../../components/shop/CartContext'
import Providers from '../providers'

export default function ShopLayout({ children }: { children: ReactNode }) {
  return (
    <Providers>
      <CartProvider>{children}</CartProvider>
    </Providers>
  )
}
