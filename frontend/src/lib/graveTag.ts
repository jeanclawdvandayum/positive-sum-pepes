export function graveTag(ranks:number[],hadStake:boolean){
 if(ranks.length===10)return 'ran the whole table'
 if(ranks.length>=5)return 'took most of the pot'
 if(ranks.length>=2)return 'took a few spots'
 if(ranks.length===1){const n=ranks[0];return `took the ${n}${n===1?'st':n===2?'nd':n===3?'rd':'th'} spot`}
 return hadStake?'survived the chart':'here for the art'
}
