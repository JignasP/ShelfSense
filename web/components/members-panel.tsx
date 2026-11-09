'use client'

import { useState, type FormEvent } from 'react'
import type { Member, Overview } from '@/lib/client-types'
import type { ActionRunner } from '@/app/workspace'

export function MembersPanel({ overview, onAction, busy }: { overview: Overview; onAction: ActionRunner; busy: boolean }) {
  const [editing, setEditing] = useState<Member | null>(null)
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    const payload = editing
      ? { action: 'member.update', memberId: editing.member_id, fullName: String(data.get('fullName')), email: String(data.get('email')), active: data.get('active') === 'on' }
      : { action: 'member.create', memberNumber: String(data.get('memberNumber')), fullName: String(data.get('fullName')), email: String(data.get('email')) }
    if (await onAction(payload, editing ? 'Member updated' : 'Member registered')) setEditing(null)
  }
  return <div className="stack"><div className="panel"><div className="panel-heading"><div><p className="eyebrow">Membership</p><h2>Member records</h2></div><span className="muted">{overview.members.length} recent members</span></div><div className="table-wrap"><table><thead><tr><th>Number</th><th>Name</th><th>Email</th><th>Joined</th><th>Status</th><th></th></tr></thead><tbody>{overview.members.map((member) => <tr key={member.member_id}><td className="mono">{member.member_number}</td><td><strong>{member.full_name}</strong></td><td>{member.email ?? '—'}</td><td>{member.joined_on}</td><td><span className={`badge ${member.active ? 'green' : 'gray'}`}>{member.active ? 'Active' : 'Inactive'}</span></td><td><button className="table-action" onClick={() => setEditing(member)}>Edit</button></td></tr>)}</tbody></table>{!overview.members.length && <p className="table-empty">No members registered yet.</p>}</div></div>
    <div className="panel narrow-panel"><div className="panel-heading"><div><p className="eyebrow">Member details</p><h2>{editing ? `Edit ${editing.member_number}` : 'Register a member'}</h2></div>{editing && <button className="text-button" onClick={() => setEditing(null)}>Cancel</button>}</div><form key={editing?.member_id ?? 'new-member'} className="form-grid" onSubmit={submit}>{!editing && <label>Member number<input name="memberNumber" required maxLength={200} /></label>}<label>Full name<input name="fullName" defaultValue={editing?.full_name} required maxLength={200} /></label><label className="wide">Email<input name="email" type="email" defaultValue={editing?.email ?? ''} placeholder="Optional" /></label>{editing && <label className="checkbox-row wide"><input name="active" type="checkbox" defaultChecked={editing.active} /> Active member</label>}<div className="form-actions"><button className="button primary" disabled={busy}>{editing ? 'Save member' : 'Register member'}</button></div></form></div>
  </div>
}
