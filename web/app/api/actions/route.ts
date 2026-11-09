import { NextResponse, type NextRequest } from 'next/server'
import { requireUser } from '@/lib/auth'
import { executeAction } from '@/lib/actions'
import { errorResponse, requireSameOrigin } from '@/lib/http'

export const runtime = 'nodejs'

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request)
    const user = await requireUser(request)
    const result = await executeAction(user, await request.json())
    return NextResponse.json({ result })
  } catch (error) { return errorResponse(error) }
}
