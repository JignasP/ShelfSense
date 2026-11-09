import { readingLists } from '../lib/mongo'

async function main() {
  const collection = await readingLists()
  console.log(`MongoDB collection ready: ${collection.dbName}.${collection.collectionName}`)
}

main().catch((error) => { console.error(error); process.exitCode = 1 })
