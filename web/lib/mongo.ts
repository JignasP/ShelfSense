import { MongoClient, type Collection, type Document } from 'mongodb'

export type ReadingEntry = { bookId: string; note: string }
export type ReadingList = Document & {
  ownerStaffId: string
  title: string
  description: string
  entries: ReadingEntry[]
  createdAt: Date
  updatedAt: Date
}

const globalMongo = globalThis as typeof globalThis & { shelfSenseMongo?: Promise<MongoClient>; shelfSenseListsReady?: Promise<void> }

async function database() {
  if (!process.env.MONGODB_URL || !process.env.MONGODB_DATABASE) throw new Error('MongoDB is not configured')
  if (!globalMongo.shelfSenseMongo) globalMongo.shelfSenseMongo = new MongoClient(process.env.MONGODB_URL).connect()
  return (await globalMongo.shelfSenseMongo).db(process.env.MONGODB_DATABASE)
}

export async function readingLists(): Promise<Collection<ReadingList>> {
  const db = await database()
  if (!globalMongo.shelfSenseListsReady) {
    globalMongo.shelfSenseListsReady = (async () => {
      if (!(await db.listCollections({ name: 'reading_lists' }).hasNext())) {
        try {
          await db.createCollection('reading_lists', {
            validator: { $jsonSchema: {
              bsonType: 'object',
              required: ['ownerStaffId', 'title', 'description', 'entries', 'createdAt', 'updatedAt'],
              properties: {
                ownerStaffId: { bsonType: 'string' },
                title: { bsonType: 'string', minLength: 1, maxLength: 120 },
                description: { bsonType: 'string', maxLength: 500 },
                entries: { bsonType: 'array', items: { bsonType: 'object', required: ['bookId', 'note'], properties: {
                  bookId: { bsonType: 'string' }, note: { bsonType: 'string', maxLength: 300 },
                } } },
                createdAt: { bsonType: 'date' }, updatedAt: { bsonType: 'date' },
              },
            } },
          })
        } catch (error) {
          if ((error as { code?: number }).code !== 48) throw error
        }
      }
      await db.collection('reading_lists').createIndex({ updatedAt: -1 })
    })().catch((error) => { globalMongo.shelfSenseListsReady = undefined; throw error })
  }
  await globalMongo.shelfSenseListsReady
  return db.collection<ReadingList>('reading_lists')
}
