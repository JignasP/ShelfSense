import { NextResponse, type NextRequest } from 'next/server'
import { requireUser } from '@/lib/auth'
import { rows } from '@/lib/db'
import { errorResponse } from '@/lib/http'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

export async function GET(request: NextRequest) {
  try {
    const user = await requireUser(request)
    const search = (request.nextUrl.searchParams.get('search') ?? '').trim().slice(0, 120)
    const [books, copies, members, loans, holds, policy, staff, events] = await Promise.all([
      search
        ? rows('SELECT * FROM search_titles($1, 100, 0)', [search])
        : rows('SELECT * FROM title_availability ORDER BY title, book_id LIMIT 100'),
      rows('SELECT ca.*, b.title FROM copy_availability ca JOIN book b USING (book_id) ORDER BY ca.copy_id DESC LIMIT 200'),
      rows('SELECT member_id, member_number, full_name, email, joined_on, active FROM member ORDER BY member_id DESC LIMIT 200'),
      rows('SELECT * FROM loan_fine_statement ORDER BY loan_id DESC LIMIT 200'),
      rows('SELECT * FROM hold_queue ORDER BY book_id, queue_position LIMIT 200'),
      rows('SELECT * FROM circulation_policy WHERE policy_id=1'),
      user.role === 'admin' ? rows('SELECT staff_user_id, username, display_name, role, active FROM staff_user ORDER BY staff_user_id') : Promise.resolve([]),
      rows('SELECT e.loan_event_id, e.loan_id, e.event_type, e.effective_on, e.recorded_at, u.display_name AS actor FROM loan_event e LEFT JOIN staff_user u USING (staff_user_id) ORDER BY e.loan_event_id DESC LIMIT 50'),
    ])
    return NextResponse.json({ user, books, copies, members, loans, holds, policy: policy[0] ?? null, staff, events })
  } catch (error) { return errorResponse(error) }
}
