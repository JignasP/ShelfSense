import { NextResponse, type NextRequest } from 'next/server'
import { ZodError } from 'zod'

export class AppError extends Error {
  constructor(public status: number, message: string) { super(message) }
}

const businessErrors: Record<string, [number, string]> = {
  SS001: [404, 'Member not found'], SS002: [409, 'Member is inactive'],
  SS003: [404, 'Copy not found'], SS004: [409, 'Copy is withdrawn'],
  SS005: [409, 'Copy is already on loan'], SS006: [409, 'Member has reached the loan limit'],
  SS007: [409, 'An earlier hold reserves this copy'], SS008: [409, 'Copy is not on loan'],
  SS009: [409, 'Copy was already returned'], SS010: [409, 'Circulation policy is not configured'],
  SS011: [400, 'Return date precedes issue date'], SS012: [404, 'Title not found'],
  SS013: [409, 'Member already has an active hold'], SS014: [404, 'Hold not found'],
  SS015: [409, 'Hold is no longer active'],
  SS016: [403, 'Active administrator required'],
}

export function errorResponse(error: unknown): NextResponse {
  if (error instanceof AppError) return NextResponse.json({ error: error.message }, { status: error.status })
  if (error instanceof ZodError) return NextResponse.json({ error: error.issues.map((issue) => issue.message).join('; ') }, { status: 400 })
  const code = (error as { code?: string } | null)?.code
  if (code && businessErrors[code]) {
    const [status, message] = businessErrors[code]
    return NextResponse.json({ error: message }, { status })
  }
  if (code === '23505' || code === '11000') return NextResponse.json({ error: 'That record already exists' }, { status: 409 })
  if (code === '23503') return NextResponse.json({ error: 'A referenced record is missing or still in use' }, { status: 409 })
  if (code === '23514' || code === '22P02') return NextResponse.json({ error: 'Invalid field value' }, { status: 400 })
  console.error('Request failed', error)
  return NextResponse.json({ error: 'The request could not be completed' }, { status: 500 })
}

export function requireSameOrigin(request: NextRequest): void {
  const origin = request.headers.get('origin')
  if (!origin || origin !== request.nextUrl.origin) throw new AppError(403, 'Request origin is not allowed')
}
