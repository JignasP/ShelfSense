import type { Metadata } from 'next'
import './styles.css'

export const metadata: Metadata = {
  title: 'ShelfSense',
  description: 'Library catalog and circulation workspace',
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>
}
