import { createHash, randomBytes } from 'node:crypto'
import { cookies } from 'next/headers'
import { type NextRequest, NextResponse } from 'next/server'
import { rows } from './db'
import { AppError } from './http'

export type StaffRole = 'admin' | 'librarian'
export type StaffUser = { staff_user_id: string; username: string; display_name: string; role: StaffRole }
export const SESSION_COOKIE = 'shelfsense_session'
const SESSION_SECONDS = 8 * 60 * 60

function digest(token: string): string { return createHash('sha256').update(token).digest('hex') }

export async function userFromToken(token?: string): Promise<StaffUser | null> {
  if (!token || !/^[0-9a-f]{64}$/.test(token)) return null
  const result = await rows<StaffUser>(
    `SELECT u.staff_user_id, u.username, u.display_name, u.role
     FROM staff_session s JOIN staff_user u ON u.staff_user_id = s.staff_user_id
     WHERE s.token_hash = $1 AND s.expires_at > now() AND u.active`, [digest(token)],
  )
  return result[0] ?? null
}

export async function currentPageUser(): Promise<StaffUser | null> {
  return userFromToken((await cookies()).get(SESSION_COOKIE)?.value)
}

export async function requireUser(request: NextRequest, roles?: StaffRole[]): Promise<StaffUser> {
  const user = await userFromToken(request.cookies.get(SESSION_COOKIE)?.value)
  if (!user) throw new AppError(401, 'Sign in to continue')
  if (roles && !roles.includes(user.role)) throw new AppError(403, 'Your role cannot perform this action')
  return user
}

export async function createSession(response: NextResponse, request: NextRequest, userId: string): Promise<void> {
  const token = randomBytes(32).toString('hex')
  await rows('INSERT INTO staff_session (token_hash, staff_user_id, expires_at) VALUES ($1, $2, now() + interval \'8 hours\')', [digest(token), userId])
  response.cookies.set(SESSION_COOKIE, token, {
    httpOnly: true, secure: request.nextUrl.protocol === 'https:', sameSite: 'lax', path: '/', maxAge: SESSION_SECONDS,
  })
}

export async function endSession(response: NextResponse, request: NextRequest): Promise<void> {
  const token = request.cookies.get(SESSION_COOKIE)?.value
  if (token && /^[0-9a-f]{64}$/.test(token)) {
    await rows('DELETE FROM staff_session WHERE token_hash = $1', [digest(token)])
  }
  response.cookies.delete(SESSION_COOKIE)
}
