'use client'

import { useState, type FormEvent } from 'react'
import type { StaffUser } from '@/lib/auth'
import type { Book, ReadingList } from '@/lib/client-types'
import { api, jsonRequest } from '@/lib/client-api'

type Entry = { bookId: string; note: string }

export function ReadingListsPanel({ user, books, lists, listError, onChanged }: { user: StaffUser; books: Book[]; lists: ReadingList[]; listError: string; onChanged: () => Promise<void> }) {
  const [editing, setEditing] = useState<ReadingList | null>(null)
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [entries, setEntries] = useState<Entry[]>([])
  const [bookId, setBookId] = useState('')
  const [note, setNote] = useState('')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)

  function choose(list: ReadingList | null) {
    setEditing(list); setTitle(list?.title ?? ''); setDescription(list?.description ?? '')
    setEntries(list?.entries.map((entry) => ({ bookId: entry.bookId, note: entry.note })) ?? [])
    setError(''); setNotice('')
  }

  function addEntry() {
    if (!bookId) return setError('Choose a title to add')
    if (entries.some((entry) => entry.bookId === bookId)) return setError('That title is already in this list')
    setEntries([...entries, { bookId, note: note.trim() }]); setBookId(''); setNote(''); setError('')
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError(''); setNotice('')
    try {
      await api('/api/reading-lists', jsonRequest(editing ? 'PATCH' : 'POST', { ...(editing ? { id: editing.id } : {}), title, description, entries }))
      choose(null)
      setNotice(editing ? 'Reading list updated' : 'Reading list created')
      await onChanged()
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not save reading list') } finally { setBusy(false) }
  }

  async function remove(list: ReadingList) {
    if (!window.confirm(`Delete “${list.title}”?`)) return
    setBusy(true); setError(''); setNotice('')
    try { await api('/api/reading-lists', jsonRequest('DELETE', { id: list.id })); if (editing?.id === list.id) choose(null); setNotice('Reading list deleted'); await onChanged() }
    catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not delete reading list') } finally { setBusy(false) }
  }

  return <div className="stack">
    <div className="panel"><div className="panel-heading"><div><p className="eyebrow">Curated pathways</p><h2>Reading lists</h2></div></div><p className="muted">Collect titles with flexible notes. Availability comes from the live catalog.</p>{listError && <p className="notice error" role="alert">Reading lists are unavailable: {listError}</p>}{error && <p className="notice error" role="alert">{error}</p>}{notice && <p className="notice success" role="status">{notice}</p>}
      <div className="list-grid">{lists.map((list) => <article className="reading-card" key={list.id}><div className="reading-card-top"><span className="badge blue">{list.entries.length} titles</span><small>Updated {new Date(list.updatedAt).toLocaleDateString()}</small></div><h3>{list.title}</h3><p>{list.description || 'No description'}</p><ul>{list.entries.map((entry) => <li key={entry.bookId}><strong>{entry.title}</strong><span>{entry.copiesAvailable} available</span>{entry.note && <small>{entry.note}</small>}</li>)}</ul>{(list.ownerStaffId === user.staff_user_id || user.role === 'admin') && <div className="card-actions"><button className="table-action" onClick={() => choose(list)}>Edit</button><button className="table-action danger" onClick={() => void remove(list)} disabled={busy}>Delete</button></div>}</article>)}</div>{!lists.length && !listError && <p className="table-empty">No reading lists yet. Create one below.</p>}
    </div>
    <div className="panel narrow-panel"><div className="panel-heading"><div><p className="eyebrow">List editor</p><h2>{editing ? `Edit ${editing.title}` : 'Create a reading list'}</h2></div>{editing && <button className="text-button" onClick={() => choose(null)}>Cancel</button>}</div><form className="form-stack" onSubmit={save}><label>List title<input value={title} onChange={(event) => setTitle(event.target.value)} required maxLength={120} /></label><label>Description<textarea value={description} onChange={(event) => setDescription(event.target.value)} maxLength={500} rows={3} /></label><div className="entry-editor"><label>Title<select value={bookId} onChange={(event) => setBookId(event.target.value)}><option value="">Choose a title</option>{books.map((book) => <option key={book.book_id} value={book.book_id}>{book.title}</option>)}</select></label><label>Note<input value={note} onChange={(event) => setNote(event.target.value)} maxLength={300} placeholder="Why this title belongs here" /></label><button type="button" className="button secondary" onClick={addEntry}>Add title</button></div><ul className="selected-entries">{entries.map((entry) => <li key={entry.bookId}><span>{books.find((book) => book.book_id === entry.bookId)?.title ?? editing?.entries.find((item) => item.bookId === entry.bookId)?.title ?? `Title #${entry.bookId}`}{entry.note && <small>{entry.note}</small>}</span><button type="button" className="table-action danger" onClick={() => setEntries(entries.filter((item) => item.bookId !== entry.bookId))}>Remove</button></li>)}</ul><div className="form-actions"><button className="button primary" disabled={busy || !!listError}>{editing ? 'Save changes' : 'Create list'}</button></div></form></div>
  </div>
}
