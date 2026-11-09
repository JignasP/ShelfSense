'use client'

import { type FormEvent } from 'react'
import type { Overview } from '@/lib/client-types'
import type { ActionRunner } from '@/app/workspace'

export function HoldsPanel({ overview, onAction, busy }: { overview: Overview; onAction: ActionRunner; busy: boolean }) {
  async function place(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const element = event.currentTarget
    const form = new FormData(element)
    if (await onAction({ action: 'hold.place', memberNumber: String(form.get('memberNumber')), bookId: String(form.get('bookId')) }, 'Hold placed')) element.reset()
  }
  return <div className="stack"><div className="panel narrow-panel"><div className="panel-heading"><div><p className="eyebrow">Request a title</p><h2>Place a hold</h2></div></div><form className="form-grid" onSubmit={place}><label>Member number<input name="memberNumber" required list="hold-members" /><datalist id="hold-members">{overview.members.filter((member) => member.active).map((member) => <option value={member.member_number} key={member.member_id}>{member.full_name}</option>)}</datalist></label><label>Title<select name="bookId" required defaultValue=""><option value="" disabled>Choose a title</option>{overview.books.map((book) => <option key={book.book_id} value={book.book_id}>{book.title}</option>)}</select></label><div className="form-actions"><button className="button primary" disabled={busy}>Place hold</button></div></form></div>
    <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Active queue</p><h2>Waiting members</h2></div></div><div className="table-wrap"><table><thead><tr><th>Position</th><th>Title</th><th>Member</th><th>Placed</th><th></th></tr></thead><tbody>{overview.holds.map((hold) => <tr key={hold.hold_id}><td><span className="queue-position">{hold.queue_position}</span></td><td><strong>{hold.title}</strong></td><td>{hold.full_name}<small className="mono">{hold.member_number}</small></td><td>{new Date(hold.placed_at).toLocaleString()}</td><td><button className="table-action danger" disabled={busy} onClick={() => { if (window.confirm('Cancel this hold?')) void onAction({ action: 'hold.cancel', holdId: hold.hold_id }, 'Hold canceled') }}>Cancel</button></td></tr>)}</tbody></table>{!overview.holds.length && <p className="table-empty">No one is waiting for a title.</p>}</div></div>
  </div>
}
