import { existsSync } from 'node:fs'
import { readingLists } from '../lib/mongo'

if (existsSync('.env.local')) process.loadEnvFile('.env.local')

async function main() {
  const collection = await readingLists()
  console.log(`MongoDB collection ready: ${collection.dbName}.${collection.collectionName}`)
}

main().catch((error) => { console.error(error); process.exitCode = 1 })
