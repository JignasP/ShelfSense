import { NextResponse, type NextRequest } from 'next/server'
import { z } from 'zod'
import { createSession } from '@/lib/auth'
import { rows } from '@/lib/db'
import { errorResponse, requireSameOrigin } from '@/lib/http'
import { verifyPassword } from '@/lib/password'

export const runtime = 'nodejs'

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request)
    const input = z.object({ username: z.string().trim().min(1), password: z.string().min(1) }).parse(await request.json())
    const users = await rows<{ staff_user_id: string; username: string; display_name: string; role: string; password_hash: string }>(
      'SELECT staff_user_id, username, display_name, role, password_hash FROM staff_user WHERE username=$1 AND active',
      [input.username],
    )
    const user = users[0]
    if (!user || !(await verifyPassword(input.password, user.password_hash))) {
      return NextResponse.json({ error: 'Invalid username or password' }, { status: 401 })
    }
    const response = NextResponse.json({ user: { staff_user_id: user.staff_user_id, username: user.username, display_name: user.display_name, role: user.role } })
    await createSession(response, request, user.staff_user_id)
    return response
  } catch (error) { return errorResponse(error) }
}
