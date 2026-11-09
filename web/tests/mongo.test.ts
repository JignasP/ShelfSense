import test from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import { MongoMemoryServer } from 'mongodb-memory-server'
import { readingLists } from '../lib/mongo'

test('reading list collection is created and supports create, read, update, delete', async () => {
  process.env.MONGOMS_DOWNLOAD_DIR = path.join(process.cwd(), '.mongo-test-binaries')
  const server = await MongoMemoryServer.create()
  process.env.MONGODB_URL = server.getUri()
  process.env.MONGODB_DATABASE = 'shelfsense_test'
  try {
    const collection = await readingLists()
    const now = new Date()
    const inserted = await collection.insertOne({ ownerStaffId: '7', title: 'Database pathways', description: 'For new members', entries: [{ bookId: '42', note: 'Start here' }], createdAt: now, updatedAt: now })
    assert.equal((await collection.findOne({ _id: inserted.insertedId }))?.entries[0].bookId, '42')
    await collection.updateOne({ _id: inserted.insertedId }, { $set: { title: 'Updated pathways', updatedAt: new Date() } })
    assert.equal((await collection.findOne({ _id: inserted.insertedId }))?.title, 'Updated pathways')
    await collection.deleteOne({ _id: inserted.insertedId })
    assert.equal(await collection.countDocuments({}), 0)
    await assert.rejects(collection.insertOne({ ownerStaffId: '7', title: '', description: '', entries: [], createdAt: now, updatedAt: now }))
  } finally {
    const cached = (globalThis as typeof globalThis & { shelfSenseMongo?: Promise<{ close: () => Promise<void> }> }).shelfSenseMongo
    if (cached) await (await cached).close()
    await server.stop()
  }
})
