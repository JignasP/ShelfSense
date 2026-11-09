'use client'

import { useState, type FormEvent } from 'react'
import type { Report } from '@/lib/client-types'
import { api } from '@/lib/client-api'

export function ReportsPanel({ today }: { today: string }) {
  const initialFrom = new Date(Date.parse(`${today}T00:00:00Z`) - 29 * 86400000).toISOString().slice(0, 10)
  const [report, setReport] = useState<Report | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function load(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setBusy(true); setError('')
    try { setReport(await api<Report>(`/api/reports?from=${form.get('from')}&to=${form.get('to')}`)) }
    catch (cause) { setError(cause instanceof Error ? cause.message : 'Reports are unavailable') }
    finally { setBusy(false) }
  }
  const maxDaily = Math.max(1, ...(report?.daily.map((row) => Number(row.loans_issued)) ?? []))
  return <div className="stack"><div className="panel"><div className="panel-heading"><div><p className="eyebrow">Operating evidence</p><h2>Circulation reports</h2></div></div><form className="inline-form" onSubmit={load}><label>From<input name="from" type="date" defaultValue={initialFrom} required /></label><label>To<input name="to" type="date" defaultValue={today} required /></label><button className="button primary" disabled={busy}>{busy ? 'Loading…' : 'Run reports'}</button></form><p className="hint">Choose up to 366 days. Counts use issue dates; the overdue worklist shows loans still open now that were due before the selected end date.</p>{error && <p className="notice error" role="alert">{error}</p>}</div>
    {report && <><div className="panel"><div className="panel-heading"><div><p className="eyebrow">Daily activity</p><h2>Loans issued</h2></div><span className="muted">Includes days with no issues</span></div><div className="bar-chart" role="img" aria-label={`Daily issue counts from ${report.from} to ${report.to}`}>{report.daily.map((row) => <div className="bar-column" key={row.report_date} title={`${row.report_date}: ${row.loans_issued} loans`}><div className="bar" style={{ height: `${Math.max(2, Number(row.loans_issued) / maxDaily * 100)}%` }} /><small>{row.report_date.slice(5)}</small></div>)}</div></div>
      <div className="two-col"><div className="panel"><div className="panel-heading"><div><p className="eyebrow">By month</p><h2>Circulation totals</h2></div></div><div className="table-wrap"><table><thead><tr><th>Period</th><th>Issued</th><th>Returned</th><th>Members</th></tr></thead><tbody>{report.byMonth.map((row, index) => <tr key={index}><td><strong>{row.is_period_total ? 'Period total' : row.period_month}</strong></td><td>{row.loans_issued}</td><td>{row.loans_returned}</td><td>{row.distinct_members}</td></tr>)}</tbody></table>{!report.byMonth.length && <p className="table-empty">No loans in this period.</p>}</div></div>
        <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Overdue</p><h2>Open loan worklist</h2></div></div><div className="table-wrap"><table><thead><tr><th>Title</th><th>Member</th><th>Due</th><th>Fine</th></tr></thead><tbody>{report.overdue.map((row) => <tr key={row.loan_id}><td><strong>{row.title}</strong><small className="mono">{row.barcode}</small></td><td>{row.member_number}</td><td>{row.due_on}</td><td>{row.fine_display}</td></tr>)}</tbody></table>{!report.overdue.length && <p className="table-empty">No open loans are overdue.</p>}</div></div></div>
      <div className="panel"><div className="panel-heading"><div><p className="eyebrow">By title</p><h2>Most circulated titles</h2></div></div><div className="table-wrap"><table><thead><tr><th>Title</th><th>Authors</th><th>Issues</th><th>Members</th><th>Share</th></tr></thead><tbody>{report.byTitle.map((row) => <tr key={row.book_id}><td><strong>{row.title}</strong></td><td>{row.authors ?? '—'}</td><td>{row.loans_issued}</td><td>{row.distinct_members}</td><td>{row.share_of_loans_percent}%</td></tr>)}</tbody></table>{!report.byTitle.length && <p className="table-empty">No titles circulated in this period.</p>}</div></div>
    </>}
  </div>
}
