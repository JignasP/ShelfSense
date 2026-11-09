'use client'

import { useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'

export default function LoginPage() {
  const router = useRouter()
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true)
    setError('')
    const form = new FormData(event.currentTarget)
    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: form.get('username'), password: form.get('password') }),
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error ?? 'Sign in failed')
      router.replace('/')
      router.refresh()
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Sign in failed') } finally { setBusy(false) }
  }

  return <main className="login-shell">
    <div className="login-brand"><span className="brand-mark">S</span><span>ShelfSense</span></div>
    <section className="login-card">
      <p className="eyebrow">Library workspace</p>
      <h1>Welcome back</h1>
      <p className="muted">Sign in with your staff account to manage the catalog and circulation.</p>
      <form onSubmit={signIn} className="form-stack">
        <label>Username<input name="username" autoComplete="username" required autoFocus /></label>
        <label>Password<input name="password" type="password" autoComplete="current-password" required /></label>
        {error && <p className="notice error" role="alert">{error}</p>}
        <button className="button primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
      </form>
    </section>
    <p className="login-foot">ShelfSense · Staff access</p>
  </main>
}
