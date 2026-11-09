// Runs against disposable databases only; this script creates persistent fixtures.
import { randomBytes } from 'node:crypto'

const base = process.env.TEST_BASE_URL ?? 'http://localhost:3000'
const adminUsername = process.env.TEST_ADMIN_USERNAME
const adminPassword = process.env.TEST_ADMIN_PASSWORD
if (!adminUsername || !adminPassword) throw new Error('Set TEST_ADMIN_USERNAME and TEST_ADMIN_PASSWORD for a disposable environment')
const suffix = randomBytes(4).toString('hex')
let cookie = ''

async function request(path, method = 'GET', body, status = 200, origin = base) {
  const response = await fetch(base + path, {
    method,
    headers: { ...(method !== 'GET' ? { 'Content-Type': 'application/json', Origin: origin } : {}), ...(cookie ? { Cookie: cookie } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: 'manual',
  })
  const data = await response.json().catch(() => ({}))
  if (response.status !== status) throw new Error(`${method} ${path}: expected ${status}, got ${response.status}: ${JSON.stringify(data)}`)
  if (path === '/api/auth/login' && status === 200) cookie = response.headers.get('set-cookie')?.split(';')[0] ?? ''
  return data
}

await request('/api/overview', 'GET', undefined, 401)
await request('/api/auth/login', 'POST', { username: adminUsername, password: adminPassword })
await request('/api/actions', 'POST', { action: 'policy.save', loanLimit: 3, loanDays: 14, graceDays: 0, fineMinorPerDay: 100, maxFineMinor: 1000, currencyCode: 'INR', currencyMinorDigits: 2 })
const book = (await request('/api/actions', 'POST', { action: 'book.create', title: `HTTP fixture ${suffix}`, isbn13: '', publicationYear: 2024, authors: 'Test Author' })).result
const barcode = `HTTP-${suffix}`
const memberNumber = `HTTP-M-${suffix}`
await request('/api/actions', 'POST', { action: 'copy.create', bookId: book.book_id, barcode, acquiredOn: '' })
await request('/api/actions', 'POST', { action: 'member.create', memberNumber, fullName: 'HTTP Test Member', email: '' })
await request('/api/actions', 'POST', { action: 'loan.issue', memberNumber, barcode, issuedOn: '2026-10-01' })
await request('/api/actions', 'POST', { action: 'loan.issue', memberNumber, barcode, issuedOn: '2026-10-01' }, 409)
const beforeReturn = await request('/api/overview')
if (beforeReturn.loans.filter((loan) => loan.barcode === barcode && !loan.returned_on).length !== 1) throw new Error('Rejected issue changed the open loans')
await request('/api/actions', 'POST', { action: 'loan.return', barcode, returnedOn: '2026-11-09' })
const reports = await request('/api/reports?from=2026-10-01&to=2026-10-09')
if (reports.daily.length !== 9 || !reports.daily.some((day) => Number(day.loans_issued) > 0)) throw new Error('Daily report is incomplete')
const overview = await request('/api/overview')
if (!overview.events.some((event) => event.event_type === 'returned' && event.actor)) throw new Error('Return audit event is missing')
const completedLoan = overview.loans.find((loan) => loan.barcode === barcode && loan.returned_on === '2026-11-09')
if (!completedLoan || Number(completedLoan.fine_minor) !== 1000 || !completedLoan.is_final || !completedLoan.fine_display) throw new Error('Final fine display is incorrect')
const listId = (await request('/api/reading-lists', 'POST', { title: `HTTP list ${suffix}`, description: 'Fixture', entries: [{ bookId: book.book_id, note: 'Available' }] }, 201)).id
const lists = await request('/api/reading-lists')
if (!lists.lists.some((list) => list.id === listId && list.entries[0].title === `HTTP fixture ${suffix}`)) throw new Error('MongoDB list did not resolve its title')
await request('/api/reading-lists', 'PATCH', { id: listId, title: `Revised ${suffix}`, description: 'Fixture', entries: [] })
await request('/api/reading-lists', 'DELETE', { id: listId })
const temporaryBook = (await request('/api/actions', 'POST', { action: 'book.create', title: `Temporary ${suffix}`, isbn13: '', publicationYear: null, authors: '' })).result
const staleListId = (await request('/api/reading-lists', 'POST', { title: `Stale ${suffix}`, description: 'Fixture', entries: [{ bookId: temporaryBook.book_id, note: '' }] }, 201)).id
await request('/api/actions', 'POST', { action: 'book.delete', bookId: temporaryBook.book_id })
const staleLists = await request('/api/reading-lists')
if (!staleLists.lists.some((list) => list.id === staleListId && list.entries[0].title === 'Title unavailable')) throw new Error('Removed title was not handled safely')
await request('/api/reading-lists', 'DELETE', { id: staleListId })
const librarianUsername = `lib.${suffix}`
await request('/api/actions', 'POST', { action: 'staff.create', username: librarianUsername, displayName: 'HTTP Test Librarian', password: adminPassword, role: 'librarian' })
await request('/api/actions', 'POST', { action: 'policy.save', loanLimit: 3, loanDays: 14, graceDays: 0, fineMinorPerDay: 100, maxFineMinor: 1000, currencyCode: 'INR', currencyMinorDigits: 2 }, 403, 'http://invalid.example')
cookie = ''
await request('/api/auth/login', 'POST', { username: librarianUsername, password: adminPassword })
await request('/api/actions', 'POST', { action: 'policy.save', loanLimit: 3, loanDays: 14, graceDays: 0, fineMinorPerDay: 100, maxFineMinor: 1000, currencyCode: 'INR', currencyMinorDigits: 2 }, 403)
await request('/api/overview')
console.log('HTTP integration checks passed')
