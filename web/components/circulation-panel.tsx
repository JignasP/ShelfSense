'use client'

import { type FormEvent } from 'react'
import type { Overview } from '@/lib/client-types'
import type { ActionRunner } from '@/app/workspace'

export function CirculationPanel({ overview, onAction, busy, today }: { overview: Overview; onAction: ActionRunner; busy: boolean; today: string }) {
  async function issue(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const element = event.currentTarget
    const form = new FormData(element)
    if (await onAction({ action: 'loan.issue', memberNumber: String(form.get('memberNumber')), barcode: String(form.get('barcode')), issuedOn: String(form.get('issuedOn')) }, 'Copy issued')) element.reset()
  }
  async function returnCopy(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const element = event.currentTarget
    const form = new FormData(element)
    if (await onAction({ action: 'loan.return', barcode: String(form.get('barcode')), returnedOn: String(form.get('returnedOn')) }, 'Copy returned')) element.reset()
  }
  return <div className="stack"><div className="two-col"><div className="panel"><div className="panel-heading"><div><p className="eyebrow">New transaction</p><h2>Issue a copy</h2></div></div><form className="form-grid" onSubmit={issue}><label className="wide">Member number<input name="memberNumber" required list="member-options" placeholder="e.g. M-001" /><datalist id="member-options">{overview.members.filter((member) => member.active).map((member) => <option key={member.member_id} value={member.member_number}>{member.full_name}</option>)}</datalist></label><label>Copy barcode<input name="barcode" required list="copy-options" /><datalist id="copy-options">{overview.copies.filter((copy) => copy.availability_status === 'available').map((copy) => <option key={copy.copy_id} value={copy.barcode}>{copy.title}</option>)}</datalist></label><label>Issue date<input name="issuedOn" type="date" defaultValue={today} required /></label><div className="form-actions"><button className="button primary" disabled={busy}>Issue copy</button></div></form></div>
      <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Complete transaction</p><h2>Return a copy</h2></div></div><form className="form-grid" onSubmit={returnCopy}><label className="wide">Copy barcode<input name="barcode" required list="loan-options" /><datalist id="loan-options">{overview.loans.filter((loan) => !loan.returned_on).map((loan) => <option key={loan.loan_id} value={loan.barcode}>{loan.title}</option>)}</datalist></label><label className="wide">Return date<input name="returnedOn" type="date" defaultValue={today} required /></label><div className="form-actions"><button className="button primary" disabled={busy}>Return copy</button></div></form></div></div>
    <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Loan history</p><h2>Recent loans and fines</h2></div></div><div className="table-wrap"><table><thead><tr><th>Copy</th><th>Member</th><th>Issued</th><th>Due</th><th>Returned</th><th>Fine</th></tr></thead><tbody>{overview.loans.map((loan) => <tr key={loan.loan_id}><td><strong>{loan.title}</strong><small className="mono">{loan.barcode}</small></td><td>{loan.full_name}<small className="mono">{loan.member_number}</small></td><td>{loan.issued_on}</td><td>{loan.due_on}</td><td>{loan.returned_on ?? <span className="badge blue">Open</span>}</td><td><strong>{loan.fine_display}</strong><small>{loan.is_final ? 'Final' : `As of ${loan.as_of_date}`}</small></td></tr>)}</tbody></table>{!overview.loans.length && <p className="table-empty">No loans yet.</p>}</div></div>
  </div>
}
