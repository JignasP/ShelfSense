import { pool } from '../lib/db'
import { hashPassword } from '../lib/password'

async function main() {
  const username = process.env.SHELFSENSE_INITIAL_USERNAME?.trim()
  const displayName = process.env.SHELFSENSE_INITIAL_NAME?.trim()
  const password = process.env.SHELFSENSE_INITIAL_PASSWORD
  const role = process.env.SHELFSENSE_INITIAL_ROLE ?? 'admin'
  if (!username || !/^[a-z0-9._-]{3,40}$/.test(username) || !displayName || !password || password.length < 12 || password.length > 128 || !['admin', 'librarian'].includes(role)) {
    throw new Error('Set valid SHELFSENSE_INITIAL_USERNAME, SHELFSENSE_INITIAL_NAME, SHELFSENSE_INITIAL_PASSWORD (12–128 characters), and optional SHELFSENSE_INITIAL_ROLE')
  }
  await pool().query('INSERT INTO staff_user (username, display_name, password_hash, role) VALUES ($1,$2,$3,$4)', [username, displayName, await hashPassword(password), role])
  console.log(`Created ${role} account ${username}`)
}

main().catch((error) => { console.error(error); process.exitCode = 1 }).finally(async () => { await pool().end() })
