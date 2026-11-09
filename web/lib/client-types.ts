import type { StaffUser } from './auth'

export type Book = { book_id: string; title: string; isbn13: string | null; publication_year: number | null; authors: string | null; copies_total: string; copies_available: string; copies_on_loan: string; copies_withdrawn: string; next_due_on: string | null; matched_on?: string }
export type Copy = { copy_id: string; book_id: string; barcode: string; title: string; acquired_on: string | null; withdrawn_on: string | null; availability_status: string; open_loan_id: string | null; due_on: string | null }
export type Member = { member_id: string; member_number: string; full_name: string; email: string | null; joined_on: string; active: boolean }
export type Loan = { loan_id: string; barcode: string; title: string; member_number: string; full_name: string; issued_on: string; due_on: string; returned_on: string | null; fine_display: string; as_of_date: string; days_past_due: number; is_final: boolean }
export type Hold = { hold_id: string; book_id: string; title: string; member_number: string; full_name: string; queue_position: string; placed_at: string }
export type Policy = { loan_limit: number; loan_days: number; grace_days: number; fine_minor_per_day: number; max_fine_minor: number; currency_code: string; currency_minor_digits: number }
export type Staff = StaffUser & { active: boolean }
export type LoanEvent = { loan_event_id: string; loan_id: string; event_type: string; effective_on: string; recorded_at: string; actor: string | null }
export type Overview = { user: StaffUser; books: Book[]; copies: Copy[]; members: Member[]; loans: Loan[]; holds: Hold[]; policy: Policy | null; staff: Staff[]; events: LoanEvent[] }
export type Report = {
  from: string; to: string;
  overdue: Array<{ loan_id: string; barcode: string; title: string; member_number: string; due_on: string; days_past_due: number; fine_display: string }>;
  byTitle: Array<{ book_id: string; title: string; authors: string | null; loans_issued: string; distinct_members: string; fines_minor: string; share_of_loans_percent: string }>;
  byMonth: Array<{ period_month: string | null; is_period_total: boolean; loans_issued: string; loans_returned: string; distinct_members: string }>;
  daily: Array<{ report_date: string; loans_issued: string }>;
}
export type ReadingList = { id: string; ownerStaffId: string; title: string; description: string; entries: Array<{ bookId: string; note: string; title: string; copiesAvailable: string }>; updatedAt: string }
