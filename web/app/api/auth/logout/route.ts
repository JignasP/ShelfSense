import { NextResponse, type NextRequest } from 'next/server'
import { endSession } from '@/lib/auth'
import { errorResponse, requireSameOrigin } from '@/lib/http'

export const runtime = 'nodejs'

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request)
    const response = NextResponse.json({ ok: true })
    await endSession(response, request)
    return response
  } catch (error) { return errorResponse(error) }
}
