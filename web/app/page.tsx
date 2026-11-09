import { redirect } from 'next/navigation'
import { currentPageUser } from '@/lib/auth'
import Dashboard from './workspace'

function libraryToday(): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: process.env.LIBRARY_TIME_ZONE ?? 'UTC', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date())
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

export default async function Home() {
  const user = await currentPageUser()
  if (!user) redirect('/login')
  return <Dashboard user={user} today={libraryToday()} />
}
