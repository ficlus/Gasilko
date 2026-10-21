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
