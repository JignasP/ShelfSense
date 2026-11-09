export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, { cache: 'no-store', ...init })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error ?? `Request failed (${response.status})`)
  return data as T
}

export function jsonRequest(method: string, value: unknown): RequestInit {
  return { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) }
}
