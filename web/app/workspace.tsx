'use client'

import { useCallback, useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import type { StaffUser } from '@/lib/auth'
import type { Overview, ReadingList } from '@/lib/client-types'
import { api, jsonRequest } from '@/lib/client-api'
import { CatalogPanel } from '@/components/catalog-panel'
import { CirculationPanel } from '@/components/circulation-panel'
import { MembersPanel } from '@/components/members-panel'
import { HoldsPanel } from '@/components/holds-panel'
import { ReportsPanel } from '@/components/reports-panel'
import { ReadingListsPanel } from '@/components/reading-lists-panel'
import { AdminPanel } from '@/components/admin-panel'

export type ActionRunner = (payload: Record<string, unknown>, success: string) => Promise<boolean>
type Tab = 'overview' | 'catalog' | 'circulation' | 'members' | 'holds' | 'reports' | 'lists' | 'admin'

const navigation: Array<{ id: Tab; title: string; icon: string }> = [
  { id: 'overview', title: 'Overview', icon: '◫' },
  { id: 'catalog', title: 'Catalog', icon: '▤' },
  { id: 'circulation', title: 'Circulation', icon: '⇄' },
  { id: 'members', title: 'Members', icon: '♧' },
  { id: 'holds', title: 'Holds', icon: '⌑' },
  { id: 'reports', title: 'Reports', icon: '▥' },
  { id: 'lists', title: 'Reading lists', icon: '☷' },
  { id: 'admin', title: 'Administration', icon: '⚙' },
]

export default function Dashboard({ user, today }: { user: StaffUser; today: string }) {
  const router = useRouter()
  const [tab, setTab] = useState<Tab>('overview')
  const [overview, setOverview] = useState<Overview | null>(null)
  const [lists, setLists] = useState<ReadingList[]>([])
  const [search, setSearch] = useState('')
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const [listError, setListError] = useState('')
  const [busy, setBusy] = useState(false)

  const reload = useCallback(async () => {
    const [main, reading] = await Promise.allSettled([
      api<Overview>(`/api/overview?search=${encodeURIComponent(search)}`),
      api<{ lists: ReadingList[] }>('/api/reading-lists'),
    ])
    if (main.status === 'fulfilled') { setOverview(main.value); setError('') }
    else setError(main.reason instanceof Error ? main.reason.message : 'Could not load library data')
    if (reading.status === 'fulfilled') { setLists(reading.value.lists); setListError('') }
    else setListError(reading.reason instanceof Error ? reading.reason.message : 'Reading lists are unavailable')
  }, [search])

  useEffect(() => { void Promise.resolve().then(reload) }, [reload])

  const run: ActionRunner = async (payload, success) => {
    setBusy(true); setError(''); setNotice('')
    try {
      await api('/api/actions', jsonRequest('POST', payload))
      setNotice(success)
      await reload()
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The change could not be saved')
      return false
    } finally { setBusy(false) }
  }

  async function signOut() {
    await api('/api/auth/logout', jsonRequest('POST', {}))
    router.replace('/login')
    router.refresh()
  }

  const activeNav = navigation.find((item) => item.id === tab)!
  const openLoans = overview?.loans.filter((loan) => !loan.returned_on).length ?? 0
  const availableCopies = overview?.copies.filter((copy) => copy.availability_status === 'available').length ?? 0

  return <div className="workspace">
    <aside className="sidebar">
      <div className="brand"><span className="brand-mark">S</span><span>ShelfSense<small>Library workspace</small></span></div>
      <nav aria-label="Main navigation">
        {navigation.filter((item) => item.id !== 'admin' || user.role === 'admin').map((item) =>
          <button key={item.id} className={`nav-item ${tab === item.id ? 'active' : ''}`} onClick={() => setTab(item.id)}>
            <span aria-hidden="true">{item.icon}</span>{item.title}
          </button>)}
      </nav>
      <div className="sidebar-bottom">
        <div className="user-avatar">{user.display_name.slice(0, 1).toUpperCase()}</div>
        <div className="user-meta"><strong>{user.display_name}</strong><span>{user.role === 'admin' ? 'Administrator' : 'Librarian'}</span></div>
        <button className="text-button" onClick={() => void signOut()} title="Sign out">↗</button>
      </div>
    </aside>
    <main className="main">
      <header className="topbar"><div><p className="eyebrow">ShelfSense / {activeNav.title}</p><h1>{activeNav.title}</h1></div><div className="topbar-right"><span className="today">{today}</span><span className="role-pill">{user.role}</span></div></header>
      {error && <div className="notice error" role="alert">{error}</div>}
      {notice && <div className="notice success" role="status">{notice}</div>}
      {!overview ? <div className="empty-state">Loading library data…</div> : <>
        {tab === 'overview' && <section className="stack">
          <div className="hero"><div><p className="eyebrow">At a glance</p><h2>Good day, {user.display_name.split(' ')[0]}.</h2><p>Keep the catalog current and every loan accounted for.</p></div><button className="button light" onClick={() => setTab('circulation')}>Open circulation <span>→</span></button></div>
          <div className="metrics"><div className="metric"><span>Catalog titles</span><strong>{overview.books.length}</strong><small>In the current view</small></div><div className="metric"><span>Available copies</span><strong>{availableCopies}</strong><small>Among recent copies</small></div><div className="metric"><span>Open loans</span><strong>{openLoans}</strong><small>Among recent loans</small></div><div className="metric"><span>Active holds</span><strong>{overview.holds.length}</strong><small>Across titles</small></div></div>
          <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Recent activity</p><h2>Circulation events</h2></div></div><div className="table-wrap"><table><thead><tr><th>Event</th><th>Loan</th><th>Effective date</th><th>Recorded by</th></tr></thead><tbody>{overview.events.map((event) => <tr key={event.loan_event_id}><td><span className={`badge ${event.event_type === 'issued' ? 'blue' : 'green'}`}>{event.event_type}</span></td><td>#{event.loan_id}</td><td>{event.effective_on}</td><td>{event.actor ?? 'Direct database entry'}</td></tr>)}</tbody></table>{!overview.events.length && <p className="table-empty">No circulation events yet.</p>}</div></div>
        </section>}
        {tab === 'catalog' && <CatalogPanel overview={overview} search={search} onSearch={setSearch} onAction={run} busy={busy} today={today} />}
        {tab === 'circulation' && <CirculationPanel overview={overview} onAction={run} busy={busy} today={today} />}
        {tab === 'members' && <MembersPanel overview={overview} onAction={run} busy={busy} />}
        {tab === 'holds' && <HoldsPanel overview={overview} onAction={run} busy={busy} />}
        {tab === 'reports' && <ReportsPanel today={today} />}
        {tab === 'lists' && <ReadingListsPanel user={user} books={overview.books} lists={lists} listError={listError} onChanged={reload} />}
        {tab === 'admin' && user.role === 'admin' && <AdminPanel overview={overview} onAction={run} busy={busy} />}
      </>}
    </main>
  </div>
}
