import type { Metadata, Viewport } from 'next'
import { Montserrat, Source_Sans_3 } from 'next/font/google'
import './globals.css'

const sourceSans = Source_Sans_3({
  subsets: ['latin'],
  variable: '--font-source-sans',
  display: 'swap',
})

const montserrat = Montserrat({
  subsets: ['latin'],
  variable: '--font-montserrat',
  display: 'swap',
})

export const metadata: Metadata = {
  metadataBase: new URL(process.env.APP_PUBLIC_URL || 'https://cottagesurgical.com'),
  title: {
    default: 'Cottage Surgical — Medical Equipment, Delivered Same-Day',
    template: '%s',
  },
  description:
    'Rent home medical equipment with same-day delivery and professional setup across Nassau and Suffolk County, NY.',
  icons: { icon: '/cottage-logo.png' },
}

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  colorScheme: 'light',
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const hasSupabaseConfig = Boolean(
    process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  )

  return (
    <html lang="en" className={`${sourceSans.variable} ${montserrat.variable}`}>
      <body className="font-sans antialiased">
        {hasSupabaseConfig ? children : <ConfigWarning />}
      </body>
    </html>
  )
}

function ConfigWarning() {
  return (
    <main className="min-h-screen grid place-items-center p-8 text-center">
      <div className="max-w-md">
        <h1 className="text-xl font-semibold mb-2">Supabase not configured</h1>
        <p className="text-slate-600 text-sm">
          Set <code className="bg-slate-100 px-1 rounded">NEXT_PUBLIC_SUPABASE_URL</code> and{' '}
          <code className="bg-slate-100 px-1 rounded">NEXT_PUBLIC_SUPABASE_ANON_KEY</code>, then restart the app.
        </p>
      </div>
    </main>
  )
}
