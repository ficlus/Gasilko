import type {Template,Definition} from '../../lib/operational/templates';
import type {EventPlan} from '../../lib/operational/scenarioEvents';
import type {HazardPlan} from '../../lib/operational/hazards';
export type DraftSnapshot={base:Template;definition:Definition;event_plan:EventPlan;hazard_plan:HazardPlan;at:string};
const prefix='gasilko.sim.draft.';
const key=(account:string,org:string,id:string)=>prefix+account+'.'+org+'.'+id;
export function preserveDraft(account:string,org:string,value:DraftSnapshot){
 const name=key(account,org,value.base.id),raw=JSON.stringify(value);if(raw.length>200000)throw new Error('storage');
 let count=0,size=raw.length;
 for(let i=0;i<sessionStorage.length;i++){const k=sessionStorage.key(i)!;if(k.startsWith(prefix)&&k!==name){count++;size+=(sessionStorage.getItem(k)??'').length;}}
 if(count>=8||size>1000000)throw new Error('storage');
 sessionStorage.setItem(name,raw);if(sessionStorage.getItem(name)!==raw)throw new Error('storage');
}
export function readDraft(account:string,org:string,id:string):DraftSnapshot|null{
 const raw=sessionStorage.getItem(key(account,org,id));if(!raw||raw.length>200000)return null;
 const value=JSON.parse(raw) as DraftSnapshot;
 return value.base?.id===id&&value.definition?.schema_version===1&&value.event_plan?.schema_version===1&&value.hazard_plan?.schema_version===1?value:null;
}
export function removeDraft(account:string,org:string,id:string){sessionStorage.removeItem(key(account,org,id));}

function canonical(value:unknown):string{
 if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
 if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical((value as Record<string,unknown>)[k])).join(',')+'}';
 return JSON.stringify(value)??'null';
}
export function draftPayload(value:Pick<DraftSnapshot,'definition'|'event_plan'|'hazard_plan'>,version:string){
 return {version_id:version,definition:{...value.definition,metadata:{...value.definition.metadata,objectives:value.definition.metadata.objectives.filter(x=>x.trim())}},event_plan:value.event_plan,hazard_plan:value.hazard_plan};
}
export function samePayload(a:unknown,b:unknown){return canonical(a)===canonical(b);}
/** Delete only the exact draft that this receipt acknowledged, never a newer edit. */
export function removeAcknowledgedDraft(account:string,org:string,id:string,expected:string,payload:unknown){
 const saved=readDraft(account,org,id);
 if(saved&&saved.base.revision===expected&&samePayload(draftPayload(saved,saved.base.version_id),payload))removeDraft(account,org,id);
}
