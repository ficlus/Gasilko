// Stable for a plan's selected team UUID set, independent of API/list ordering.
// Golden-angle spacing avoids reusing a short organization palette for larger plans.
export function teamColors(ids:string[]):Record<string,string>{
 return Object.fromEntries([...new Set(ids)].sort().map((id,index)=>[id,`hsl(${(index*137.508)%360}, 64%, 34%)`]));
}
