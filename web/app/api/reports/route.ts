import { NextResponse, type NextRequest } from 'next/server'
import { z } from 'zod'
import { requireUser } from '@/lib/auth'
import { rows } from '@/lib/db'
import { AppError, errorResponse } from '@/lib/http'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export async function GET(request: NextRequest) {
  try {
    await requireUser(request)
    const input = z.object({ from: z.iso.date(), to: z.iso.date() }).parse(Object.fromEntries(request.nextUrl.searchParams))
    const span = (Date.parse(input.to) - Date.parse(input.from)) / 86400000
    if (span < 0 || span > 366) throw new AppError(400, 'Choose a period of at most 366 days')
    const [overdue, byTitle, byMonth, daily] = await Promise.all([
      rows('SELECT * FROM overdue_loans_as_of($1::date) LIMIT 200', [input.to]),
      rows('SELECT * FROM circulation_summary_by_title($1::date,$2::date) LIMIT 100', [input.from, input.to]),
      rows('SELECT * FROM circulation_summary_by_month($1::date,$2::date)', [input.from, input.to]),
      rows('SELECT * FROM daily_issues($1::date,$2::date)', [input.from, input.to]),
    ])
    return NextResponse.json({ overdue, byTitle, byMonth, daily, from: input.from, to: input.to })
  } catch (error) { return errorResponse(error) }
}
