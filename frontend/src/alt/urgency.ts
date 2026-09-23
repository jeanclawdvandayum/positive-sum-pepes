// Countdown urgency band shared by every alt clock: red while less than
// 10% of the window remains, yellow below 30%, green at or above. The
// bands are strict lower bounds: exactly 30% is safe, exactly 10% is
// warm, zero remaining is critical. An unknown or spent window
// (total <= 0) is idle.
export type Urgency = 'safe'|'warm'|'critical'|'idle'
export function urgencyFor(remaining:number,total:number):Urgency {
 if(!Number.isFinite(total)||total<=0) return 'idle'
 const fraction=Math.max(0,remaining)/total
 return fraction<0.10?'critical':fraction<0.30?'warm':'safe'
}
