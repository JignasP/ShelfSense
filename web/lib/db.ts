import { Pool, type PoolClient, type QueryResultRow, types } from 'pg'

// A PostgreSQL DATE is a library-local calendar day, not a UTC instant.
types.setTypeParser(1082, (value) => value)

const globalPool = globalThis as typeof globalThis & { shelfSensePool?: Pool }

export function pool(): Pool {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is not configured')
  if (!globalPool.shelfSensePool) {
    globalPool.shelfSensePool = new Pool({ connectionString: process.env.DATABASE_URL, max: 10 })
  }
  return globalPool.shelfSensePool
}

export async function rows<T extends QueryResultRow = QueryResultRow>(sql: string, values: unknown[] = []): Promise<T[]> {
  return (await pool().query<T>(sql, values)).rows
}

export async function withActor<T>(staffUserId: string, operation: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool().connect()
  try {
    await client.query('BEGIN')
    // SET LOCAL makes the audit actor visible only in this transaction.
    await client.query("SELECT set_config('shelfsense.actor_user_id', $1, true)", [staffUserId])
    const value = await operation(client)
    await client.query('COMMIT')
    return value
  } catch (error) {
    await client.query('ROLLBACK')
    throw error
  } finally {
    client.release()
  }
}
