import { existsSync } from 'node:fs'
import { pool } from '../lib/db'
import { hashPassword } from '../lib/password'

if (existsSync('.env.local')) process.loadEnvFile('.env.local')

async function main() {
  const username = process.env.SHELFSENSE_INITIAL_USERNAME?.trim()
  const displayName = process.env.SHELFSENSE_INITIAL_NAME?.trim()
  const password = process.env.SHELFSENSE_INITIAL_PASSWORD
  if (!username || !/^[a-z0-9._-]{3,40}$/.test(username) || !displayName || !password || password.length < 12 || password.length > 128) {
    throw new Error('Set valid SHELFSENSE_INITIAL_USERNAME, SHELFSENSE_INITIAL_NAME, and SHELFSENSE_INITIAL_PASSWORD (12–128 characters)')
  }
  await pool().query('INSERT INTO staff_user (username, display_name, password_hash, role) VALUES ($1,$2,$3,$4)', [username, displayName, await hashPassword(password), 'admin'])
  console.log(`Created administrator account ${username}`)
}

main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(async () => { if (process.env.DATABASE_URL) await pool().end() })
