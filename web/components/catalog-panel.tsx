'use client'

import { useState, type FormEvent } from 'react'
import type { Book, Copy, Overview } from '@/lib/client-types'
import type { ActionRunner } from '@/app/workspace'

const value = (form: FormData, key: string) => String(form.get(key) ?? '').trim()

export function CatalogPanel({ overview, search, onSearch, onAction, busy, today }: { overview: Overview; search: string; onSearch: (value: string) => void; onAction: ActionRunner; busy: boolean; today: string }) {
  const [draftSearch, setDraftSearch] = useState(search)
  const [editingBook, setEditingBook] = useState<Book | null>(null)
  const [editingCopy, setEditingCopy] = useState<Copy | null>(null)

  async function saveBook(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const payload = { action: editingBook ? 'book.update' : 'book.create', ...(editingBook ? { bookId: editingBook.book_id } : {}), title: value(form, 'title'), authors: value(form, 'authors'), isbn13: value(form, 'isbn13'), publicationYear: value(form, 'publicationYear') ? Number(value(form, 'publicationYear')) : null }
    if (await onAction(payload, editingBook ? 'Title updated' : 'Title added')) setEditingBook(null)
  }

  async function saveCopy(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const payload = editingCopy
      ? { action: 'copy.update', copyId: editingCopy.copy_id, barcode: value(form, 'barcode'), withdrawnOn: value(form, 'withdrawnOn') }
      : { action: 'copy.create', bookId: value(form, 'bookId'), barcode: value(form, 'barcode'), acquiredOn: value(form, 'acquiredOn') }
    if (await onAction(payload, editingCopy ? 'Copy updated' : 'Copy added')) setEditingCopy(null)
  }

  return <div className="stack">
    <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Discovery</p><h2>Catalog titles</h2></div><form className="search-box" onSubmit={(event) => { event.preventDefault(); onSearch(draftSearch) }}><input aria-label="Search catalog" placeholder="Title, author, or ISBN" value={draftSearch} onChange={(event) => setDraftSearch(event.target.value)} /><button className="button secondary">Search</button></form></div>
      <div className="table-wrap"><table><thead><tr><th>Title</th><th>Author</th><th>ISBN</th><th>Copies</th><th>Available</th><th></th></tr></thead><tbody>{overview.books.map((book) => <tr key={book.book_id}><td><strong>{book.title}</strong>{book.publication_year && <small>{book.publication_year}</small>}</td><td>{book.authors ?? '—'}</td><td className="mono">{book.isbn13 ?? '—'}</td><td>{book.copies_total}</td><td><span className={`badge ${Number(book.copies_available) ? 'green' : 'gray'}`}>{book.copies_available}</span></td><td><button className="table-action" onClick={() => setEditingBook(book)}>Edit</button></td></tr>)}</tbody></table>{!overview.books.length && <p className="table-empty">No titles match this search.</p>}</div>
    </div>
    <div className="two-col">
      <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Catalog record</p><h2>{editingBook ? `Edit ${editingBook.title}` : 'Add a title'}</h2></div>{editingBook && <button className="text-button" onClick={() => setEditingBook(null)}>Cancel</button>}</div>
        <form key={editingBook?.book_id ?? 'new-book'} className="form-grid" onSubmit={saveBook}><label className="wide">Title<input name="title" defaultValue={editingBook?.title} required maxLength={200} /></label><label className="wide">Authors <span className="hint">Separate names with semicolons</span><input name="authors" defaultValue={editingBook?.authors ?? ''} maxLength={1500} /></label><label>ISBN-13<input name="isbn13" defaultValue={editingBook?.isbn13 ?? ''} pattern="[0-9]{13}" placeholder="Optional" /></label><label>Publication year<input name="publicationYear" type="number" min="1450" max="3000" defaultValue={editingBook?.publication_year ?? ''} /></label><div className="form-actions"><button className="button primary" disabled={busy}>{editingBook ? 'Save title' : 'Add title'}</button>{editingBook && overview.user.role === 'admin' && <button type="button" className="button ghost danger" disabled={busy} onClick={() => { if (window.confirm('Delete this title? It must have no copies.')) void onAction({ action: 'book.delete', bookId: editingBook.book_id }, 'Title deleted') }}>Delete empty title</button>}</div></form>
      </div>
      <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Physical inventory</p><h2>{editingCopy ? `Edit ${editingCopy.barcode}` : 'Add a copy'}</h2></div>{editingCopy && <button className="text-button" onClick={() => setEditingCopy(null)}>Cancel</button>}</div>
        <form key={editingCopy?.copy_id ?? 'new-copy'} className="form-grid" onSubmit={saveCopy}>{!editingCopy && <label className="wide">Title<select name="bookId" required defaultValue=""><option value="" disabled>Choose a title</option>{overview.books.map((book) => <option value={book.book_id} key={book.book_id}>{book.title}</option>)}</select></label>}<label className="wide">Barcode<input name="barcode" defaultValue={editingCopy?.barcode} required maxLength={200} /></label>{editingCopy ? <label className="wide">Withdrawn on <span className="hint">Clear to reinstate</span><input name="withdrawnOn" type="date" defaultValue={editingCopy.withdrawn_on ?? ''} /></label> : <label className="wide">Acquired on<input name="acquiredOn" type="date" defaultValue={today} /></label>}<div className="form-actions"><button className="button primary" disabled={busy}>{editingCopy ? 'Save copy' : 'Add copy'}</button></div></form>
      </div>
    </div>
    <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Inventory</p><h2>Physical copies</h2></div></div><div className="table-wrap"><table><thead><tr><th>Barcode</th><th>Title</th><th>Status</th><th>Due</th><th></th></tr></thead><tbody>{overview.copies.map((copy) => <tr key={copy.copy_id}><td className="mono">{copy.barcode}</td><td>{copy.title}</td><td><span className={`badge ${copy.availability_status === 'available' ? 'green' : copy.availability_status === 'on_loan' ? 'blue' : 'gray'}`}>{copy.availability_status.replace('_', ' ')}</span></td><td>{copy.due_on ?? '—'}</td><td><button className="table-action" onClick={() => setEditingCopy(copy)}>Edit</button></td></tr>)}</tbody></table>{!overview.copies.length && <p className="table-empty">No copies have been recorded.</p>}</div></div>
  </div>
}
