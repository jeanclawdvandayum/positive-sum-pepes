import test from 'node:test'
import assert from 'node:assert/strict'
import { startTransactionToast, transactionToasts } from '../src/lib/transactionToasts.ts'

test('manual dismissal suppresses later transaction updates', () => {
 const t=startTransactionToast('buy PSP',84532,'0xabc')
 const id=transactionToasts.snapshot().at(-1).id
 transactionToasts.dismiss(id)
 t.update('success','0x123')
 assert.equal(transactionToasts.snapshot().some(t=>t.id===id),false)
})
test('expired pending toast can return with final receipt, and refresh errors cannot undo success', () => {
 const t=startTransactionToast('buy PSP',84532,'0xabc')
 const id=transactionToasts.snapshot().at(-1).id
 t.update('pending','0x123')
 transactionToasts.dismiss(id,false)
 t.update('success','0x456')
 t.fail(Error('data refresh failed'))
 const entry=transactionToasts.snapshot().find(t=>t.id===id)
 assert.equal(entry.stage,'success')
 assert.equal(entry.hash,'0x456')
 transactionToasts.dismiss(id)
})
