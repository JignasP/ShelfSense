import type { PoolClient } from 'pg'
import { z } from 'zod'
import { pool, rows, withActor } from './db'
import { hashPassword } from './password'
import { AppError } from './http'
import type { StaffUser } from './auth'

const id = z.string().regex(/^[1-9][0-9]*$/, 'Choose a valid record')
const label = z.string().trim().min(1).max(200)
const date = z.iso.date()
const email = z.union([z.email(), z.literal('')]).default('')

function adminOnly(user: StaffUser): void {
  if (user.role !== 'admin') throw new AppError(403, 'Administrator access is required')
}

async function setAuthors(client: PoolClient, bookId: string, source: string): Promise<void> {
  const names = [...new Map(source.split(';').map((name) => name.trim()).filter(Boolean).map((name) => [name.toLowerCase(), name])).values()]
  if (names.length > 12 || names.some((name) => name.length > 120)) throw new AppError(400, 'Provide at most 12 author names of 120 characters each')
  await client.query('DELETE FROM book_author WHERE book_id = $1', [bookId])
  for (let index = 0; index < names.length; index++) {
    const existing = await client.query<{ author_id: string }>(
      'SELECT author_id FROM author WHERE lower(display_name) = lower($1) ORDER BY author_id LIMIT 1', [names[index]],
    )
    const authorId = existing.rows[0]?.author_id ?? (await client.query<{ author_id: string }>(
      'INSERT INTO author (display_name) VALUES ($1) RETURNING author_id', [names[index]],
    )).rows[0].author_id
    await client.query('INSERT INTO book_author (book_id, author_id, author_order) VALUES ($1, $2, $3)', [bookId, authorId, index + 1])
  }
}

export async function executeAction(user: StaffUser, raw: unknown): Promise<unknown> {
  const action = z.object({ action: z.string() }).parse(raw).action
  switch (action) {
    case 'book.create': {
      const input = z.object({ title: label, isbn13: z.union([z.string().regex(/^[0-9]{13}$/), z.literal('')]).default(''), publicationYear: z.number().int().min(1450).max(3000).nullable(), authors: z.string().max(1500) }).parse(raw)
      const client = await pool().connect()
      try {
        await client.query('BEGIN')
        const book = (await client.query<{ book_id: string }>(
          'INSERT INTO book (title, isbn13, publication_year) VALUES ($1, $2, $3) RETURNING book_id',
          [input.title, input.isbn13 || null, input.publicationYear],
        )).rows[0]
        await setAuthors(client, book.book_id, input.authors)
        await client.query('COMMIT')
        return book
      } catch (error) { await client.query('ROLLBACK'); throw error } finally { client.release() }
    }
    case 'book.update': {
      const input = z.object({ bookId: id, title: label, isbn13: z.union([z.string().regex(/^[0-9]{13}$/), z.literal('')]).default(''), publicationYear: z.number().int().min(1450).max(3000).nullable(), authors: z.string().max(1500) }).parse(raw)
      const client = await pool().connect()
      try {
        await client.query('BEGIN')
        const result = await client.query('UPDATE book SET title=$2, isbn13=$3, publication_year=$4 WHERE book_id=$1 RETURNING book_id', [input.bookId, input.title, input.isbn13 || null, input.publicationYear])
        if (!result.rowCount) throw new AppError(404, 'Title not found')
        await setAuthors(client, input.bookId, input.authors)
        await client.query('COMMIT')
        return { bookId: input.bookId }
      } catch (error) { await client.query('ROLLBACK'); throw error } finally { client.release() }
    }
    case 'book.delete': {
      adminOnly(user)
      const input = z.object({ bookId: id }).parse(raw)
      const client = await pool().connect()
      try {
        await client.query('BEGIN')
        await client.query('DELETE FROM book_author WHERE book_id=$1', [input.bookId])
        const result = await client.query('DELETE FROM book WHERE book_id=$1 RETURNING book_id', [input.bookId])
        if (!result.rowCount) throw new AppError(404, 'Title not found')
        await client.query('COMMIT')
        return { bookId: input.bookId }
      } catch (error) { await client.query('ROLLBACK'); throw error } finally { client.release() }
    }
    case 'copy.create': {
      const input = z.object({ bookId: id, barcode: label, acquiredOn: z.union([date, z.literal('')]).default('') }).parse(raw)
      return (await rows('INSERT INTO copy (book_id, barcode, acquired_on) VALUES ($1,$2,$3) RETURNING *', [input.bookId, input.barcode, input.acquiredOn || null]))[0]
    }
    case 'copy.update': {
      const input = z.object({ copyId: id, barcode: label, withdrawnOn: z.union([date, z.literal('')]).default('') }).parse(raw)
      const result = await rows('UPDATE copy SET barcode=$2, withdrawn_on=$3 WHERE copy_id=$1 RETURNING *', [input.copyId, input.barcode, input.withdrawnOn || null])
      if (!result.length) throw new AppError(404, 'Copy not found')
      return result[0]
    }
    case 'member.create': {
      const input = z.object({ memberNumber: label, fullName: label, email }).parse(raw)
      return (await rows('INSERT INTO member (member_number, full_name, email) VALUES ($1,$2,$3) RETURNING *', [input.memberNumber, input.fullName, input.email || null]))[0]
    }
    case 'member.update': {
      const input = z.object({ memberId: id, fullName: label, email, active: z.boolean() }).parse(raw)
      const result = await rows('UPDATE member SET full_name=$2, email=$3, active=$4 WHERE member_id=$1 RETURNING *', [input.memberId, input.fullName, input.email || null, input.active])
      if (!result.length) throw new AppError(404, 'Member not found')
      return result[0]
    }
    case 'loan.issue': {
      const input = z.object({ memberNumber: label, barcode: label, issuedOn: date }).parse(raw)
      return withActor(user.staff_user_id, async (client) => (await client.query(
        'SELECT * FROM issue_copy($1,$2,$3::date)', [input.memberNumber, input.barcode, input.issuedOn],
      )).rows[0])
    }
    case 'loan.return': {
      const input = z.object({ barcode: label, returnedOn: date }).parse(raw)
      return withActor(user.staff_user_id, async (client) => (await client.query(
        'SELECT * FROM return_copy($1,$2::date)', [input.barcode, input.returnedOn],
      )).rows[0])
    }
    case 'hold.place': {
      const input = z.object({ memberNumber: label, bookId: id }).parse(raw)
      return (await rows('SELECT * FROM place_hold($1,$2)', [input.memberNumber, input.bookId]))[0]
    }
    case 'hold.cancel': {
      const input = z.object({ holdId: id }).parse(raw)
      return (await rows('SELECT * FROM cancel_hold($1)', [input.holdId]))[0]
    }
    case 'policy.save': {
      adminOnly(user)
      const input = z.object({ loanLimit: z.number().int().min(1).max(100), loanDays: z.number().int().min(1).max(365), graceDays: z.number().int().min(0).max(365), fineMinorPerDay: z.number().int().min(0).max(1000000), maxFineMinor: z.number().int().min(0).max(100000000), currencyCode: z.string().regex(/^[A-Z]{3}$/), currencyMinorDigits: z.number().int().min(0).max(4) }).parse(raw)
      return withActor(user.staff_user_id, async (client) => (await client.query(`INSERT INTO circulation_policy (policy_id, loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor, currency_code, currency_minor_digits)
        VALUES (1,$1,$2,$3,$4,$5,$6,$7)
        ON CONFLICT (policy_id) DO UPDATE SET loan_limit=$1, loan_days=$2, grace_days=$3, fine_minor_per_day=$4, max_fine_minor=$5, currency_code=$6, currency_minor_digits=$7 RETURNING *`,
      [input.loanLimit, input.loanDays, input.graceDays, input.fineMinorPerDay, input.maxFineMinor, input.currencyCode, input.currencyMinorDigits])).rows[0])
    }
    case 'staff.create': {
      adminOnly(user)
      const input = z.object({ username: z.string().regex(/^[a-z0-9._-]{3,40}$/), displayName: label, password: z.string().min(12).max(128), role: z.enum(['admin', 'librarian']) }).parse(raw)
      const passwordHash = await hashPassword(input.password)
      return withActor(user.staff_user_id, async (client) => (await client.query('INSERT INTO staff_user (username, display_name, password_hash, role) VALUES ($1,$2,$3,$4) RETURNING staff_user_id, username, display_name, role, active', [input.username, input.displayName, passwordHash, input.role])).rows[0])
    }
    case 'staff.setActive': {
      adminOnly(user)
      const input = z.object({ staffUserId: id, active: z.boolean() }).parse(raw)
      if (input.staffUserId === user.staff_user_id && !input.active) throw new AppError(400, 'You cannot deactivate your own account')
      const result = await withActor(user.staff_user_id, async (client) => (await client.query('UPDATE staff_user SET active=$2 WHERE staff_user_id=$1 RETURNING staff_user_id, username, display_name, role, active', [input.staffUserId, input.active])).rows)
      if (!result.length) throw new AppError(404, 'Staff account not found')
      return result[0]
    }
    default:
      throw new AppError(400, 'Unknown action')
  }
}
