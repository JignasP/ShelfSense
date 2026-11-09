import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto'
import { promisify } from 'node:util'

const scrypt = promisify(scryptCallback)
const KEY_LENGTH = 64

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16).toString('hex')
  const key = (await scrypt(password, salt, KEY_LENGTH)) as Buffer
  return `scrypt$${salt}$${key.toString('hex')}`
}

export async function verifyPassword(password: string, encoded: string): Promise<boolean> {
  const [scheme, salt, hex] = encoded.split('$')
  if (scheme !== 'scrypt' || !salt || !hex || !/^[0-9a-f]{32}$/.test(salt) || !/^[0-9a-f]{128}$/.test(hex)) return false
  const expected = Buffer.from(hex, 'hex')
  const actual = (await scrypt(password, salt, KEY_LENGTH)) as Buffer
  return timingSafeEqual(actual, expected)
}
