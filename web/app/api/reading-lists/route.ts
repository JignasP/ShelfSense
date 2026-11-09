import { ObjectId } from 'mongodb'
import { NextResponse, type NextRequest } from 'next/server'
import { z } from 'zod'
import { requireUser, type StaffUser } from '@/lib/auth'
import { rows } from '@/lib/db'
import { AppError, errorResponse, requireSameOrigin } from '@/lib/http'
import { readingLists, type ReadingEntry, type ReadingList } from '@/lib/mongo'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const entrySchema = z.object({ bookId: z.string().regex(/^[1-9][0-9]*$/), note: z.string().trim().max(300) })
const listSchema = z.object({ title: z.string().trim().min(1).max(120), description: z.string().trim().max(500), entries: z.array(entrySchema).max(30) })

async function checkedEntries(entries: ReadingEntry[]): Promise<ReadingEntry[]> {
  const ids = entries.map((entry) => entry.bookId)
  if (new Set(ids).size !== ids.length) throw new AppError(400, 'A title can appear only once in a list')
  if (ids.length) {
    const found = await rows<{ book_id: string }>('SELECT book_id FROM book WHERE book_id = ANY($1::bigint[])', [ids])
    if (found.length !== ids.length) throw new AppError(400, 'One or more titles no longer exist')
  }
  return entries
}

function objectId(raw: unknown): ObjectId {
  const value = z.string().regex(/^[0-9a-fA-F]{24}$/).parse(raw)
  return new ObjectId(value)
}

function mayEdit(user: StaffUser, list: ReadingList): void {
  if (user.role !== 'admin' && list.ownerStaffId !== user.staff_user_id) throw new AppError(403, 'Only the list owner or an administrator may edit it')
}

export async function GET(request: NextRequest) {
  try {
    await requireUser(request)
    const collection = await readingLists()
    const lists = await collection.find({}).sort({ updatedAt: -1 }).limit(100).toArray()
    const ids = [...new Set(lists.flatMap((list) => list.entries.map((entry) => entry.bookId)))]
    const titles = ids.length ? await rows<{ book_id: string; title: string; copies_available: string }>(
      'SELECT book_id, title, copies_available FROM title_availability WHERE book_id = ANY($1::bigint[])', [ids],
    ) : []
    const byId = new Map(titles.map((title) => [title.book_id, title]))
    return NextResponse.json({ lists: lists.map((list) => ({
      id: list._id.toHexString(), ownerStaffId: list.ownerStaffId, title: list.title,
      description: list.description, createdAt: list.createdAt, updatedAt: list.updatedAt,
      entries: list.entries.map((entry) => ({ ...entry, title: byId.get(entry.bookId)?.title ?? 'Title unavailable', copiesAvailable: byId.get(entry.bookId)?.copies_available ?? '0' })),
    })) })
  } catch (error) { return errorResponse(error) }
}

export async function POST(request: NextRequest) {
  try {
    requireSameOrigin(request)
    const user = await requireUser(request)
    const input = listSchema.parse(await request.json())
    await checkedEntries(input.entries)
    const now = new Date()
    const result = await (await readingLists()).insertOne({ ownerStaffId: user.staff_user_id, ...input, createdAt: now, updatedAt: now })
    return NextResponse.json({ id: result.insertedId.toHexString() }, { status: 201 })
  } catch (error) { return errorResponse(error) }
}

export async function PATCH(request: NextRequest) {
  try {
    requireSameOrigin(request)
    const user = await requireUser(request)
    const raw = await request.json()
    const input = listSchema.extend({ id: z.string() }).parse(raw)
    const collection = await readingLists()
    const _id = objectId(input.id)
    const existing = await collection.findOne({ _id })
    if (!existing) throw new AppError(404, 'Reading list not found')
    mayEdit(user, existing)
    await checkedEntries(input.entries)
    await collection.updateOne({ _id }, { $set: { title: input.title, description: input.description, entries: input.entries, updatedAt: new Date() } })
    return NextResponse.json({ id: input.id })
  } catch (error) { return errorResponse(error) }
}

export async function DELETE(request: NextRequest) {
  try {
    requireSameOrigin(request)
    const user = await requireUser(request)
    const input = z.object({ id: z.string() }).parse(await request.json())
    const collection = await readingLists()
    const _id = objectId(input.id)
    const existing = await collection.findOne({ _id })
    if (!existing) throw new AppError(404, 'Reading list not found')
    mayEdit(user, existing)
    await collection.deleteOne({ _id })
    return NextResponse.json({ id: input.id })
  } catch (error) { return errorResponse(error) }
}
