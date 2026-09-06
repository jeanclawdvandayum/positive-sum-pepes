// Creates a dedicated, unfunded permit key. Prints only the public address.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
const target = process.argv[2]
if (!target || !path.isAbsolute(target)) throw Error('Provide an absolute private path outside the repository.')
const root = fs.realpathSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'))
const parent = path.dirname(target)
fs.mkdirSync(parent, { recursive: true, mode: 0o700 })
const realParent = fs.realpathSync(parent)
if (realParent === root || realParent.startsWith(root + path.sep)) throw Error('Keep the signer outside the repository.')
const key = generatePrivateKey()
// Exclusive creation: never replace an operational signer accidentally.
fs.writeFileSync(target, key + '\n', { flag: 'wx', mode: 0o600 })
console.log(privateKeyToAccount(key).address)
