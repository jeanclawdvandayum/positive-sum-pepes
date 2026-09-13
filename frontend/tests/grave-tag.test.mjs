import test from 'node:test'
import assert from 'node:assert/strict'
import { graveTag } from '../src/lib/graveTag.ts'
test('graveyard winner labels cover all ten ladder ranks and group sizes',()=>{
 const endings=['1st','2nd','3rd','4th','5th','6th','7th','8th','9th','10th'];
 endings.forEach((rank,i)=>assert.equal(graveTag([i+1],true),`took the ${rank} spot`));
 for(let n=2;n<=10;n++)assert.equal(graveTag(Array.from({length:n},(_,i)=>i+1),true),n===10?'ran the whole table':n>=5?'took most of the pot':'took a few spots');
 assert.equal(graveTag([],true),'survived the chart');assert.equal(graveTag([],false),'here for the art');
});
