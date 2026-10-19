/** Development-only aggregate numbers, never IDs, coordinates or payloads. */
type Phase='task_accept'|'position_fetch'|'position_age'|'collection'|'geometry'|'source_update'|'frame';
const metrics=new Map<Phase,{count:number;totalMs:number;maxMs:number;items:number}>();
let reported=0;
export function mapMetric(phase:Phase,ms:number,items=0){
 if(process.env.NODE_ENV!=='development'||!Number.isFinite(ms))return;
 const old=metrics.get(phase)??{count:0,totalMs:0,maxMs:0,items:0};
 metrics.set(phase,{count:old.count+1,totalMs:old.totalMs+Math.max(0,ms),maxMs:Math.max(old.maxMs,ms),items:old.items+items});
 if(performance.now()-reported<10000)return;reported=performance.now();
 console.debug('[command-map aggregate]',Object.fromEntries(metrics));metrics.clear();
}
