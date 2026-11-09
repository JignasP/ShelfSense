import test from 'node:test'
import assert from 'node:assert/strict'
import { hashPassword, verifyPassword } from '../lib/password'

test('password hashes are salted and reject the wrong password', async () => {
  const first = await hashPassword('a sufficiently long passphrase')
  const second = await hashPassword('a sufficiently long passphrase')
  assert.notEqual(first, second)
  assert.equal(await verifyPassword('a sufficiently long passphrase', first), true)
  assert.equal(await verifyPassword('not the passphrase', first), false)
  assert.equal(await verifyPassword('a sufficiently long passphrase', 'malformed'), false)
})
